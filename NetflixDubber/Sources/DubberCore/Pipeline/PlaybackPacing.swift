import Foundation

public struct PlaybackPacerConfiguration: Sendable, Equatable {
    /// A dub starting later than this after its original line ended is dropped.
    public var maximumLag: TimeInterval = 7
    /// Lag that is normal for a cloud pipeline; beyond it playback speeds up.
    public var comfortableLag: TimeInterval = 2.5
    public var maximumRate: Float = 1.35

    public init() {}
}

public struct PlaybackDecision: Sendable, Equatable {
    public var shouldPlay: Bool
    /// Playback speed for the dub track (1 = normal).
    public var rate: Float
    /// Expected delay between the Japanese line ending and the dub starting.
    public var expectedLag: TimeInterval
}

/// Keeps the dub close to the picture: speeds speech up as the backlog grows
/// and drops lines that would play too long after they were spoken.
public struct PlaybackPacer: Sendable {
    public var configuration: PlaybackPacerConfiguration

    public init(configuration: PlaybackPacerConfiguration = PlaybackPacerConfiguration()) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - sourceEnd: when the original line ended (capture clock).
    ///   - now: current capture-clock time.
    ///   - queuedAhead: seconds of dub audio already waiting to play before this clip.
    public func decide(sourceEnd: TimeInterval, now: TimeInterval, queuedAhead: TimeInterval) -> PlaybackDecision {
        let lag = max(0, now + queuedAhead - sourceEnd)
        guard lag <= configuration.maximumLag else {
            return PlaybackDecision(shouldPlay: false, rate: configuration.maximumRate, expectedLag: lag)
        }
        let span = max(configuration.maximumLag - configuration.comfortableLag, 0.1)
        let pressure = max(0, min(1, (lag - configuration.comfortableLag) / span))
        let rate = 1 + Float(pressure) * (configuration.maximumRate - 1)
        return PlaybackDecision(shouldPlay: true, rate: rate, expectedLag: lag)
    }
}

/// Decides how loud the original programme audio should be.
public struct DuckingPolicy: Sendable, Equatable {
    /// Gain applied to the original audio while dialogue is being dubbed (0…1).
    public var duckedGain: Float = 0.15
    /// Also lower the original the moment Japanese speech starts, before the dub
    /// is ready; hides the Japanese voice at the cost of briefly quieter effects.
    public var duckDuringOriginalSpeech = true
    /// Keep ducking this long after the original speech stops, avoiding "pumping".
    public var holdAfterSpeech: TimeInterval = 0.35

    public init(duckedGain: Float = 0.15, duckDuringOriginalSpeech: Bool = true) {
        self.duckedGain = duckedGain
        self.duckDuringOriginalSpeech = duckDuringOriginalSpeech
    }

    public func targetGain(originalSpeechActive: Bool, secondsSinceSpeechEnded: TimeInterval?, dubPlaying: Bool) -> Float {
        if dubPlaying { return duckedGain }
        guard duckDuringOriginalSpeech else { return 1 }
        if originalSpeechActive { return duckedGain }
        if let elapsed = secondsSinceSpeechEnded, elapsed < holdAfterSpeech { return duckedGain }
        return 1
    }
}
