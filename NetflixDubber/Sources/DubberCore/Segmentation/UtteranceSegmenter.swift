import Foundation

public struct SegmenterConfiguration: Sendable, Equatable {
    public var sampleRate: Double = 16_000
    public var vad = VADConfiguration()
    /// Consecutive speech frames needed to open an utterance (filters clicks).
    public var startFrames: Int = 3
    /// Silence that closes an utterance. Lower = snappier dubs, more fragmented lines.
    public var endSilence: TimeInterval = 0.45
    /// Utterances with less detected speech than this are dropped.
    public var minimumSpeech: TimeInterval = 0.35
    /// Long monologues are cut so the dub never falls too far behind.
    public var maximumUtterance: TimeInterval = 6.0
    /// Audio kept from before the detected onset so soft first syllables survive.
    public var preRoll: TimeInterval = 0.2
    /// Silence kept after the last speech frame.
    public var tailPadding: TimeInterval = 0.12
    /// A forced cut goes at the quietest frame within this final window.
    public var splitSearchWindow: TimeInterval = 1.5

    public init() {}
}

public enum SegmenterEvent: Sendable, Equatable {
    case speechStarted(TimeInterval)
    case speechEnded(TimeInterval)
    case utterance(Utterance)
}

/// Turns a continuous 16 kHz mono stream into utterances plus real-time
/// speech start/stop events (the latter drive ducking of the original audio).
public final class UtteranceSegmenter {
    public let configuration: SegmenterConfiguration
    private let vad: VoiceActivityDetector
    private let frameLength: Int

    private let preRollFrames: Int
    private let endSilenceFrames: Int
    private let minimumSpeechFrames: Int
    private let maximumFrames: Int
    private let tailFrames: Int
    private let splitSearchFrames: Int

    private var pending: [Float] = []
    private var framesProcessed = 0
    private var nextUtteranceID = 0

    // Idle state: recent frames for pre-roll.
    private var recentFrames: [[Float]] = []
    private var speechRun = 0

    // Active utterance.
    private var inSpeech = false
    private var currentFrames: [[Float]] = []
    private var currentEnergies: [Float] = []
    private var currentStartFrame = 0
    private var currentSpeechFrames = 0
    private var silenceRun = 0
    private var lastSpeechFrameEnd = 0

    public init(configuration: SegmenterConfiguration = SegmenterConfiguration()) {
        self.configuration = configuration
        let detector = VoiceActivityDetector(sampleRate: configuration.sampleRate, configuration: configuration.vad)
        vad = detector
        frameLength = detector.frameLength
        let frameDuration = Double(detector.frameLength) / configuration.sampleRate
        func frames(_ seconds: TimeInterval) -> Int { max(0, Int((seconds / frameDuration).rounded())) }
        preRollFrames = frames(configuration.preRoll)
        endSilenceFrames = max(1, frames(configuration.endSilence))
        minimumSpeechFrames = max(1, frames(configuration.minimumSpeech))
        maximumFrames = max(frames(configuration.maximumUtterance), 10)
        tailFrames = frames(configuration.tailPadding)
        splitSearchFrames = max(1, frames(configuration.splitSearchWindow))
    }

    public var frameDuration: TimeInterval { Double(frameLength) / configuration.sampleRate }

    /// Capture-clock time of everything received so far.
    public var currentTime: TimeInterval {
        Double(framesProcessed * frameLength + pending.count) / configuration.sampleRate
    }

    public var isSpeaking: Bool { inSpeech }

    public var noiseFloorDB: Float { vad.noiseFloorDB }

    public func append(_ samples: [Float]) -> [SegmenterEvent] {
        pending.append(contentsOf: samples)
        var events: [SegmenterEvent] = []
        var offset = 0
        while pending.count - offset >= frameLength {
            let frame = Array(pending[offset..<(offset + frameLength)])
            offset += frameLength
            events += process(frame: frame)
        }
        if offset > 0 { pending.removeFirst(offset) }
        return events
    }

    /// Closes any open utterance (e.g. when capture stops).
    public func flush() -> [SegmenterEvent] {
        guard inSpeech else { return [] }
        return finishUtterance()
    }

    // MARK: - Frame state machine

    private func process(frame: [Float]) -> [SegmenterEvent] {
        let frameIndex = framesProcessed
        framesProcessed += 1
        let decision = vad.classify(frame[...], currentlySpeaking: inSpeech)

        if !inSpeech {
            recentFrames.append(frame)
            let keep = preRollFrames + configuration.startFrames
            if recentFrames.count > keep { recentFrames.removeFirst(recentFrames.count - keep) }

            speechRun = decision.isSpeech ? speechRun + 1 : 0
            guard speechRun >= configuration.startFrames else { return [] }

            // Open an utterance, including the pre-roll before the onset.
            inSpeech = true
            let take = min(recentFrames.count, preRollFrames + speechRun)
            currentFrames = Array(recentFrames.suffix(take))
            currentEnergies = [Float](repeating: decision.energyDB, count: take)
            currentStartFrame = frameIndex + 1 - take
            currentSpeechFrames = speechRun
            silenceRun = 0
            lastSpeechFrameEnd = frameIndex + 1
            recentFrames.removeAll()
            speechRun = 0
            return [.speechStarted(time(ofFrame: frameIndex + 1 - min(take, configuration.startFrames)))]
        }

        currentFrames.append(frame)
        currentEnergies.append(decision.energyDB)
        if decision.isSpeech {
            silenceRun = 0
            currentSpeechFrames += 1
            lastSpeechFrameEnd = frameIndex + 1
        } else {
            silenceRun += 1
        }

        if silenceRun >= endSilenceFrames {
            // Trim trailing silence (keeping a little padding) and close.
            let drop = max(0, silenceRun - tailFrames)
            let dropped = Array(currentFrames.suffix(drop))
            currentFrames.removeLast(drop)
            currentEnergies.removeLast(drop)
            let events = finishUtterance()
            // The trimmed silence becomes pre-roll for the next line.
            recentFrames = Array(dropped.suffix(preRollFrames))
            return events
        }

        if currentFrames.count >= maximumFrames {
            return splitLongUtterance()
        }
        return []
    }

    private func finishUtterance() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = [.speechEnded(time(ofFrame: lastSpeechFrameEnd))]
        if currentSpeechFrames >= minimumSpeechFrames, let utterance = makeUtterance(frames: currentFrames, startFrame: currentStartFrame) {
            events.append(.utterance(utterance))
        }
        inSpeech = false
        currentFrames.removeAll()
        currentEnergies.removeAll()
        currentSpeechFrames = 0
        silenceRun = 0
        speechRun = 0
        return events
    }

    /// Emits the first part of an over-long utterance, cut at the quietest
    /// point near its end, and keeps the remainder open.
    private func splitLongUtterance() -> [SegmenterEvent] {
        let total = currentFrames.count
        let lowerBound = max(minimumSpeechFrames, total - splitSearchFrames)
        let upperBound = total - 1
        var cut = upperBound
        if lowerBound < upperBound {
            var quietest = Float.greatestFiniteMagnitude
            for index in lowerBound..<upperBound where currentEnergies[index] < quietest {
                quietest = currentEnergies[index]
                cut = index
            }
        }
        cut = max(1, cut)

        let head = Array(currentFrames[0..<cut])
        var events: [SegmenterEvent] = []
        if let utterance = makeUtterance(frames: head, startFrame: currentStartFrame) {
            events.append(.utterance(utterance))
        }
        currentFrames.removeFirst(cut)
        currentEnergies.removeFirst(cut)
        currentStartFrame += cut
        // Assume the remainder is mostly speech; it is still inside an active run.
        currentSpeechFrames = currentFrames.count
        return events
    }

    private func makeUtterance(frames: [[Float]], startFrame: Int) -> Utterance? {
        guard !frames.isEmpty else { return nil }
        let samples = frames.flatMap { $0 }
        let id = nextUtteranceID
        nextUtteranceID += 1
        return Utterance(
            id: id,
            audio: AudioClip(samples: samples, sampleRate: configuration.sampleRate),
            startTime: time(ofFrame: startFrame),
            endTime: time(ofFrame: startFrame + frames.count)
        )
    }

    private func time(ofFrame index: Int) -> TimeInterval {
        Double(index * frameLength) / configuration.sampleRate
    }
}
