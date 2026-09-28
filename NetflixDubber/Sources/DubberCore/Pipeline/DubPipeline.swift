import Foundation

public struct PipelineConfiguration: Sendable {
    public var segmenter = SegmenterConfiguration()
    public var registry = SpeakerRegistryConfiguration()
    /// Lines processed concurrently; beyond this new lines are dropped (the dub
    /// is hopelessly behind and would only get further out of sync).
    public var maximumLinesInFlight = 4
    /// Previous lines given to the translator for context.
    public var historyLength = 8
    /// A finished line waits at most this long for an earlier, slower line.
    public var headOfLineTimeout: TimeInterval = 6

    public init() {}
}

public struct PipelineProblem: Sendable, Equatable {
    public var stage: String
    public var message: String
    /// True when dubbing can't continue without user action (e.g. invalid API key).
    public var isFatal: Bool

    public init(stage: String, message: String, isFatal: Bool) {
        self.stage = stage
        self.message = message
        self.isFatal = isFatal
    }
}

public enum PipelineEvent: Sendable {
    /// Original (Japanese) speech started/stopped — drives ducking in real time.
    case speechActivity(isSpeaking: Bool, at: TimeInterval)
    /// A new voice was detected and given its own English voice.
    case speakerCreated(VoiceProfile)
    case speakerUpdated(VoiceProfile)
    case line(DubLine)
    /// Dub audio, released strictly in the order the lines were spoken.
    case clip(DubClip)
    case problem(PipelineProblem)
}

/// Live dubbing pipeline:
///
///     16 kHz audio ─► segmenter ─► utterance ─┬─► voiceprint ─► speaker registry ─► voice designer
///                                             └─► Japanese ASR ─► Claude translation ─► TTS ─► ordered release
///
/// Each utterance is processed concurrently with its neighbours; voiceprint
/// extraction and speech recognition run in parallel to keep latency down.
public actor DubPipeline {
    public nonisolated let events: AsyncStream<PipelineEvent>
    private let continuation: AsyncStream<PipelineEvent>.Continuation

    private let configuration: PipelineConfiguration
    private let segmenter: UtteranceSegmenter
    private let registry: SpeakerRegistry
    private let designer: VoiceDesigner
    private let embedder: SpeakerEmbeddingExtractor?
    private let transcriber: SpeechTranscriber
    private let translator: DialogueTranslator
    private let synthesizer: DubSpeechSynthesizer

    private var profiles: [SpeakerID: VoiceProfile] = [:]
    private var lines: [Int: DubLine] = [:]
    private var history: [DialogueTurn] = []
    private var recentJapanese: [String] = []
    private var inFlight = 0
    private var releaseQueue = OrderedReleaseQueue<DubClip>()
    private var waitingSince: [Int: TimeInterval] = [:]
    private var lastSpeaker: SpeakerID?
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var isFinished = false

    public init(
        configuration: PipelineConfiguration = PipelineConfiguration(),
        embedder: SpeakerEmbeddingExtractor?,
        transcriber: SpeechTranscriber,
        translator: DialogueTranslator,
        synthesizer: DubSpeechSynthesizer,
        voiceCatalog: [VoiceOption]
    ) {
        self.configuration = configuration
        segmenter = UtteranceSegmenter(configuration: configuration.segmenter)
        registry = SpeakerRegistry(configuration: configuration.registry)
        designer = VoiceDesigner(catalog: voiceCatalog)
        self.embedder = embedder
        self.transcriber = transcriber
        self.translator = translator
        self.synthesizer = synthesizer
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self, bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    // MARK: - Public API

    /// Feeds captured programme audio (16 kHz mono).
    public func ingest(_ samples: [Float]) {
        guard !isFinished else { return }
        for event in segmenter.append(samples) {
            handle(event)
        }
        releaseStuckLines()
    }

    /// Capture-clock time of all audio ingested so far.
    public var streamTime: TimeInterval { segmenter.currentTime }

    public var speakerProfiles: [VoiceProfile] {
        profiles.values.sorted { $0.speaker < $1.speaker }
    }

    public func setNewSpeakerDistance(_ distance: Float) {
        registry.configuration.newSpeakerDistance = distance
    }

    public func setVoice(_ voice: VoiceOption, for speaker: SpeakerID) {
        guard let profile = profiles[speaker] else { return }
        let updated = designer.reassign(profile, to: voice)
        profiles[speaker] = updated
        continuation.yield(.speakerUpdated(updated))
    }

    public func setMuted(_ muted: Bool, for speaker: SpeakerID) {
        guard var profile = profiles[speaker] else { return }
        profile.isMuted = muted
        profiles[speaker] = profile
        continuation.yield(.speakerUpdated(profile))
    }

    /// Stops processing; in-flight lines are cancelled and the event stream ends.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        if segmenter.isSpeaking {
            continuation.yield(.speechActivity(isSpeaking: false, at: segmenter.currentTime))
        }
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        continuation.finish()
    }

    // MARK: - Segmentation

    private func handle(_ event: SegmenterEvent) {
        switch event {
        case .speechStarted(let time):
            continuation.yield(.speechActivity(isSpeaking: true, at: time))
        case .speechEnded(let time):
            continuation.yield(.speechActivity(isSpeaking: false, at: time))
        case .utterance(let utterance):
            begin(utterance)
        }
    }

    private func begin(_ utterance: Utterance) {
        var line = DubLine(
            id: utterance.id,
            status: .identifyingSpeaker,
            sourceStart: utterance.startTime,
            sourceEnd: utterance.endTime
        )
        guard inFlight < configuration.maximumLinesInFlight else {
            line.status = .skipped("falling behind")
            publish(line)
            release(utterance.id, nil)
            return
        }
        inFlight += 1
        publish(line)
        tasks[utterance.id] = Task { [weak self] in
            await self?.process(utterance)
        }
    }

    // MARK: - Per-line processing

    private func process(_ utterance: Utterance) async {
        defer {
            inFlight -= 1
            tasks[utterance.id] = nil
        }
        let id = utterance.id
        let audio = utterance.audio
        let embedder = self.embedder
        let transcriber = self.transcriber
        let context = TranscriptionContext(previousLines: Array(recentJapanese.suffix(2)))

        // Voiceprint, pitch and speech recognition run concurrently.
        async let voiceprint = Self.voiceprint(of: audio, using: embedder)
        async let pitch = Self.pitch(of: audio)
        async let transcript = Self.capture { try await transcriber.transcribe(audio, context: context) }

        // 1. Who is speaking?
        let pitchSummary = await pitch
        let speaker = identifySpeaker(voiceprint: await voiceprint, duration: utterance.duration, pitchHz: pitchSummary.medianHz)
        guard !isFinished else { return }
        guard let profile = profiles[speaker] else { return }
        update(id) {
            $0.speaker = speaker
            $0.status = .transcribing
        }
        if profile.isMuted {
            skip(id, reason: "\(profile.displayName) is muted")
            return
        }

        // 2. What did they say?
        let japanese: String
        switch await transcript {
        case .success(let raw):
            guard let cleaned = TranscriptFilter.clean(raw) else {
                skip(id, reason: "no dialogue")
                return
            }
            japanese = cleaned
        case .failure(let error):
            fail(id, stage: "Speech recognition", error: error)
            return
        }
        guard !isFinished else { return }
        recentJapanese.append(japanese)
        if recentJapanese.count > 6 { recentJapanese.removeFirst(recentJapanese.count - 6) }
        update(id) {
            $0.japanese = japanese
            $0.status = .translating
        }

        // 3. Translate with dialogue context.
        let request = TranslationRequest(
            japanese: japanese,
            speakerName: profile.displayName,
            sourceDuration: utterance.duration,
            history: Array(history.suffix(configuration.historyLength))
        )
        let translator = self.translator
        let translation: Translation
        do {
            translation = try await translator.translate(request)
        } catch {
            fail(id, stage: "Translation", error: error)
            return
        }
        guard !isFinished else { return }
        guard !translation.english.isEmpty else {
            skip(id, reason: "not dialogue")
            return
        }
        history.append(DialogueTurn(speakerName: profile.displayName, japanese: japanese, english: translation.english))
        if history.count > 40 { history.removeFirst(history.count - 40) }
        update(id) {
            $0.english = translation.english
            $0.delivery = translation.delivery
            $0.status = .synthesizing
        }

        // 4. Voice it with this speaker's own voice (re-read: it may have been changed meanwhile).
        let voice = profiles[speaker] ?? profile
        let synthesizer = self.synthesizer
        let delivery = DeliveryStyle.parse(translation.delivery)
        do {
            let speech = try await synthesizer.synthesize(translation.english, voice: voice, delivery: delivery)
            guard !isFinished else { return }
            guard !speech.isEmpty else {
                fail(id, stage: "Speech synthesis", error: DubberServiceError.invalidResponse(service: "TTS", detail: "no audio"))
                return
            }
            let readyAt = segmenter.currentTime
            update(id) {
                $0.status = .queued
                $0.readyAt = readyAt
            }
            release(id, DubClip(lineID: id, speaker: speaker, audio: speech, sourceEnd: utterance.endTime, text: translation.english))
        } catch {
            fail(id, stage: "Speech synthesis", error: error)
        }
    }

    private func identifySpeaker(voiceprint: Result<[Float], Error>?, duration: TimeInterval, pitchHz: Double?) -> SpeakerID {
        var speaker = lastSpeaker ?? .unknown
        var founded = false
        switch voiceprint {
        case .success(let vector)?:
            if let match = registry.identify(embedding: vector, duration: duration, pitchHz: pitchHz) {
                speaker = match.speaker
                founded = match.isNew
            }
        case .failure(let error)?:
            if !(error is CancellationError) {
                report(stage: "Speaker recognition", error: error, fatalOverride: false)
            }
        case nil:
            break
        }
        if profiles[speaker] == nil {
            let profile = designer.design(for: speaker, pitchHz: founded ? pitchHz : (registry.medianPitch(of: speaker) ?? pitchHz))
            profiles[speaker] = profile
            continuation.yield(.speakerCreated(profile))
        }
        lastSpeaker = speaker
        return speaker
    }

    private static func voiceprint(of audio: AudioClip, using embedder: SpeakerEmbeddingExtractor?) async -> Result<[Float], Error>? {
        guard let embedder else { return nil }
        return await capture { try await embedder.embedding(for: audio) }
    }

    private static func pitch(of audio: AudioClip) async -> PitchSummary {
        let clip = audio.resampled(to: 16_000)
        return PitchEstimator().summarize(clip.samples)
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Line bookkeeping

    private func publish(_ line: DubLine) {
        lines[line.id] = line
        if lines.count > 200, let oldest = lines.keys.min() {
            lines.removeValue(forKey: oldest)
        }
        continuation.yield(.line(line))
    }

    private func update(_ id: Int, _ change: (inout DubLine) -> Void) {
        guard var line = lines[id] else { return }
        change(&line)
        publish(line)
    }

    private func skip(_ id: Int, reason: String) {
        update(id) { $0.status = .skipped(reason) }
        release(id, nil)
    }

    private func fail(_ id: Int, stage: String, error: Error) {
        if error is CancellationError {
            update(id) { line in
                if !line.status.isFinished { line.status = .skipped("cancelled") }
            }
        } else {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(id) { $0.status = .failed(message) }
            report(stage: stage, error: error, fatalOverride: nil)
        }
        release(id, nil)
    }

    private func report(stage: String, error: Error, fatalOverride: Bool?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let fatal = fatalOverride ?? ((error as? DubberServiceError)?.isFatal ?? false)
        continuation.yield(.problem(PipelineProblem(stage: stage, message: message, isFatal: fatal)))
    }

    // MARK: - Ordered release

    private func release(_ id: Int, _ clip: DubClip?) {
        let ready = releaseQueue.complete(id, with: clip)
        if id >= releaseQueue.nextSequence {
            waitingSince[id] = ProcessInfo.processInfo.systemUptime
        }
        for key in waitingSince.keys where key < releaseQueue.nextSequence {
            waitingSince.removeValue(forKey: key)
        }
        for clip in ready {
            continuation.yield(.clip(clip))
        }
    }

    /// If finished lines have been blocked too long behind a slow earlier line,
    /// give up on the slow one so the dub doesn't stall.
    private func releaseStuckLines() {
        guard let earliest = releaseQueue.earliestWaiting,
              let since = waitingSince[earliest],
              ProcessInfo.processInfo.systemUptime - since > configuration.headOfLineTimeout
        else { return }

        for id in releaseQueue.nextSequence..<earliest {
            tasks[id]?.cancel()
            update(id) { line in
                if !line.status.isFinished { line.status = .skipped("took too long") }
            }
        }
        let ready = releaseQueue.skip(upTo: earliest)
        for key in waitingSince.keys where key < releaseQueue.nextSequence {
            waitingSince.removeValue(forKey: key)
        }
        for clip in ready {
            continuation.yield(.clip(clip))
        }
    }
}
