import AVFoundation
import Combine
import DubberCore
import Foundation

/// Owns a dubbing session: capture → pipeline → playback, plus the UI state.
@MainActor
final class DubbingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .running: return true
            case .idle, .failed: return false
            }
        }
    }

    enum SetupError: LocalizedError {
        case missingKey(String)
        case noVoices

        var errorDescription: String? {
            switch self {
            case .missingKey(let service):
                return "Add your \(service) API key in Settings (⌘,) before starting."
            case .noVoices:
                return "No English system voices are installed. Add one in System Settings › Accessibility › Spoken Content, or switch to OpenAI voices."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var speakers: [VoiceProfile] = []
    @Published private(set) var lines: [DubLine] = []
    /// Peak level of the captured programme audio, 0…1.
    @Published private(set) var inputLevel: Float = 0
    /// Expected delay of the latest dub behind the original line.
    @Published private(set) var currentLag: TimeInterval = 0
    @Published private(set) var speakerModelName = ""
    @Published private(set) var voiceCatalog: [VoiceOption] = []
    @Published var notice: String?

    /// Used to restore the original audio if the app quits mid-session.
    static weak var active: DubbingController?

    private let settings: AppSettings
    private let audio = DubAudioEngine()
    private let tap = SystemAudioTap()
    private let capture = MonoAccumulator()
    private var pipeline: DubPipeline?
    private var embedder: SpeakerEmbeddingExtractor?
    private var synthesizer: DubSpeechSynthesizer?
    private var ingestTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var duckingTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var settingsSubscription: AnyCancellable?
    private var startedAt = Date.distantPast

    private var pacer = PlaybackPacer()
    private var ducking = DuckingPolicy()
    private var queuedLineIDs: [Int] = []
    private var queuedSeconds: TimeInterval = 0
    private var originalSpeaking = false
    private var speechEndedAt: Date?
    private var captureClock: TimeInterval = 0
    private var silentSince: Date?

    init(settings: AppSettings) {
        self.settings = settings
        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored; apply on the next turn.
            Task { @MainActor [weak self] in self?.applyLiveSettings() }
        }
    }

    // MARK: - Session lifecycle

    func start() {
        guard !phase.isActive else { return }
        phase = .preparing("Checking settings…")
        notice = nil
        lines.removeAll()
        speakers.removeAll()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.launch()
            } catch {
                await self.shutdown()
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard phase != .idle else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.shutdown()
            self.phase = .idle
        }
    }

    /// Synchronous teardown used at app termination; destroying the tap un-mutes the Mac.
    func emergencyStop() {
        tap.stop()
        audio.stop()
    }

    private func launch() async throws {
        let anthropicKey = settings.anthropicKey
        guard !anthropicKey.isEmpty else { throw SetupError.missingKey("Anthropic (Claude)") }
        if settings.needsOpenAIKey && settings.openAIKey.isEmpty { throw SetupError.missingKey("OpenAI") }

        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: anthropicKey, model: settings.claudeModel))

        let transcriber: SpeechTranscriber
        switch settings.recognition {
        case .openAI:
            transcriber = OpenAITranscriber(configuration: OpenAIConfiguration(apiKey: settings.openAIKey))
        case .apple:
            phase = .preparing("Requesting speech-recognition permission…")
            guard await AppleSpeechTranscriber.requestAuthorization() else {
                throw AppleSpeechTranscriber.TranscriberError.notAuthorized
            }
            transcriber = try AppleSpeechTranscriber()
        }

        let synthesizer: DubSpeechSynthesizer
        let catalog: [VoiceOption]
        switch settings.voices {
        case .apple:
            catalog = AppleSpeechSynthesizer.englishVoices()
            guard !catalog.isEmpty else { throw SetupError.noVoices }
            synthesizer = AppleSpeechSynthesizer()
        case .openAI:
            catalog = OpenAIVoiceCatalog.voices
            synthesizer = OpenAISpeechSynthesizer(configuration: OpenAIConfiguration(apiKey: settings.openAIKey))
        }
        voiceCatalog = catalog
        self.synthesizer = synthesizer

        phase = .preparing("Loading the voice-recognition model (downloaded on first run)…")
        let embedder: SpeakerEmbeddingExtractor
        do {
            embedder = try await NeuralSpeakerEmbedder.load()
        } catch {
            embedder = SpectralSpeakerEmbedder()
            notice = "Neural voice recognition couldn't load (\(error.localizedDescription)). Using the built-in fallback, which is less precise with similar voices."
        }
        self.embedder = embedder
        speakerModelName = embedder.displayName

        var configuration = PipelineConfiguration()
        configuration.registry.newSpeakerDistance = settings.newSpeakerDistance(recommended: embedder.recommendedNewSpeakerDistance)
        let pipeline = DubPipeline(
            configuration: configuration,
            embedder: embedder,
            transcriber: transcriber,
            translator: translator,
            synthesizer: synthesizer,
            voiceCatalog: catalog
        )
        self.pipeline = pipeline

        phase = .preparing("Starting audio capture…")
        applyLiveSettings()
        // Output first: the global tap can only exclude this app once Core Audio knows it.
        try audio.startOutput()
        let format = try tap.start(
            target: settings.captureTarget,
            muteOriginal: true,
            handler: Self.makeCaptureHandler(ring: audio.passthroughBuffer, accumulator: capture)
        )
        try audio.attachPassthrough(sampleRate: format.sampleRate)

        startEventLoop(pipeline)
        startIngestLoop(pipeline, captureRate: format.sampleRate)
        startDuckingTimer()
        observeOutputChanges()
        startedAt = Date()
        Self.active = self
        phase = .running

        if settings.captureTarget == .allSystemAudio && !SystemAudioTap.isBrowserPlayingAudio() {
            notice = "Listening. Start the Japanese-audio episode in Netflix (in your browser) and the dub will follow."
        }
    }

    private func shutdown() async {
        ingestTask?.cancel()
        ingestTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        duckingTimer?.invalidate()
        duckingTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        tap.stop()        // restores the original soundtrack
        audio.stop()
        if let pipeline {
            await pipeline.finish()
        }
        pipeline = nil
        synthesizer = nil
        queuedLineIDs.removeAll()
        queuedSeconds = 0
        originalSpeaking = false
        speechEndedAt = nil
        silentSince = nil
        inputLevel = 0
        _ = capture.drain()
        for index in lines.indices where !lines[index].status.isFinished {
            lines[index].status = .skipped("stopped")
        }
        if Self.active === self { Self.active = nil }
    }

    // MARK: - Capture → pipeline

    /// Runs on the real-time capture queue: feed the pass-through and the analysis path.
    private nonisolated static func makeCaptureHandler(ring: StereoRingBuffer, accumulator: MonoAccumulator) -> SystemAudioTap.InputHandler {
        return { list in
            let channels = FloatChannels(list)
            ring.write(channels)
            accumulator.append(channels)
        }
    }

    private func startIngestLoop(_ pipeline: DubPipeline, captureRate: Double) {
        let accumulator = capture
        ingestTask = Task.detached(priority: .userInitiated) { [weak self] in
            let resampler = StreamingResampler(inputRate: captureRate, outputRate: 16_000)
            var ingestedSamples = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                let (raw, peak) = accumulator.drain()
                guard !raw.isEmpty else { continue }
                let samples = resampler.process(raw)
                ingestedSamples += samples.count
                await pipeline.ingest(samples)
                let clock = Double(ingestedSamples) / 16_000
                await self?.captureTick(peak: peak, clock: clock)
            }
        }
    }

    private func captureTick(peak: Float, clock: TimeInterval) {
        captureClock = clock
        inputLevel = max(peak, inputLevel * 0.85)
        if peak < 1e-5 {
            if silentSince == nil { silentSince = Date() }
            if let since = silentSince, Date().timeIntervalSince(since) > 10, notice == nil {
                notice = "No sound is being captured. Is the episode playing? If it is, allow Netflix Dubber under System Settings › Privacy & Security › Screen & System Audio Recording."
            }
        } else {
            silentSince = nil
        }
    }

    // MARK: - Pipeline events

    private func startEventLoop(_ pipeline: DubPipeline) {
        eventsTask = Task { [weak self] in
            for await event in pipeline.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .speechActivity(let isSpeaking, _):
            originalSpeaking = isSpeaking
            if !isSpeaking { speechEndedAt = Date() }
            updateDucking()

        case .speakerCreated(let profile), .speakerUpdated(let profile):
            if let index = speakers.firstIndex(where: { $0.speaker == profile.speaker }) {
                speakers[index] = profile
            } else {
                speakers.append(profile)
                speakers.sort { $0.speaker < $1.speaker }
            }

        case .line(let line):
            upsert(line)

        case .clip(let clip):
            play(clip)

        case .problem(let problem):
            if problem.isFatal {
                Task { [weak self] in
                    guard let self else { return }
                    await self.shutdown()
                    self.phase = .failed("\(problem.stage): \(problem.message)")
                }
            } else {
                notice = "\(problem.stage): \(problem.message)"
            }
        }
    }

    private func upsert(_ line: DubLine) {
        if let index = lines.lastIndex(where: { $0.id == line.id }) {
            // Playback statuses are owned by the controller; don't regress them.
            switch lines[index].status {
            case .playing, .played:
                var merged = line
                merged.status = lines[index].status
                lines[index] = merged
            default:
                lines[index] = line
            }
        } else {
            lines.append(line)
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
    }

    private func setStatus(_ status: LineStatus, forLine id: Int) {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
        lines[index].status = status
    }

    // MARK: - Playback

    private func play(_ clip: DubClip) {
        let decision = pacer.decide(sourceEnd: clip.sourceEnd, now: captureClock, queuedAhead: queuedSeconds)
        currentLag = decision.expectedLag
        guard decision.shouldPlay else {
            setStatus(.skipped("too late to dub"), forLine: clip.lineID)
            return
        }
        audio.setDubRate(decision.rate)
        let duration = clip.audio.duration / Double(decision.rate)
        queuedSeconds += duration
        queuedLineIDs.append(clip.lineID)
        if queuedLineIDs.count == 1 { setStatus(.playing, forLine: clip.lineID) }
        updateDucking()

        let lineID = clip.lineID
        audio.schedule(clip.audio, gain: 1) { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishedPlaying(lineID, duration: duration)
            }
        }
    }

    private func finishedPlaying(_ lineID: Int, duration: TimeInterval) {
        guard let position = queuedLineIDs.firstIndex(of: lineID) else { return }
        queuedLineIDs.remove(at: position)
        queuedSeconds = max(0, queuedSeconds - duration)
        setStatus(.played, forLine: lineID)
        if let next = queuedLineIDs.first { setStatus(.playing, forLine: next) }
        if queuedLineIDs.isEmpty { audio.setDubRate(1) }
        updateDucking()
    }

    private func startDuckingTimer() {
        duckingTimer?.invalidate()
        duckingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDucking() }
        }
    }

    private func updateDucking() {
        let sinceSpeech = speechEndedAt.map { Date().timeIntervalSince($0) }
        let gain = ducking.targetGain(
            originalSpeechActive: originalSpeaking,
            secondsSinceSpeechEnded: sinceSpeech,
            dubPlaying: !queuedLineIDs.isEmpty
        )
        audio.setOriginalGain(gain)
    }

    private func applyLiveSettings() {
        ducking.duckedGain = Float(settings.originalLevelWhileDubbing)
        ducking.duckDuringOriginalSpeech = settings.duckDuringOriginalSpeech
        audio.dubVolume = Float(settings.dubVolume)
        pacer.configuration.maximumLag = settings.maximumLag
        pacer.configuration.comfortableLag = min(2.5, settings.maximumLag * 0.4)
        if let pipeline, let embedder {
            let distance = settings.newSpeakerDistance(recommended: embedder.recommendedNewSpeakerDistance)
            Task { await pipeline.setNewSpeakerDistance(distance) }
        }
        updateDucking()
    }

    /// Output device changes (headphones, AirPlay) invalidate the capture device.
    private func observeOutputChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .running, Date().timeIntervalSince(self.startedAt) > 2 else { return }
                await self.shutdown()
                self.phase = .idle
                self.notice = "The audio output changed (e.g. headphones connected). Press Start to resume dubbing."
            }
        }
    }

    // MARK: - Speaker controls

    func setVoice(_ voice: VoiceOption, for speaker: SpeakerID) {
        guard let pipeline else { return }
        Task { await pipeline.setVoice(voice, for: speaker) }
    }

    func setMuted(_ muted: Bool, for speaker: SpeakerID) {
        guard let pipeline else { return }
        Task { await pipeline.setMuted(muted, for: speaker) }
    }

    func preview(_ profile: VoiceProfile) {
        guard phase == .running, let synthesizer else { return }
        Task { [weak self] in
            do {
                let clip = try await synthesizer.synthesize(
                    "Hi! This is the voice I'll use for this character.",
                    voice: profile,
                    delivery: .neutral
                )
                self?.audio.schedule(clip, gain: 1) {}
            } catch {
                self?.notice = "Voice preview failed: \(error.localizedDescription)"
            }
        }
    }
}
