import Foundation

/// Mono floating-point PCM audio.
public struct AudioClip: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Returns this clip at `rate`, resampling only when needed.
    public func resampled(to rate: Double) -> AudioClip {
        guard rate != sampleRate, !samples.isEmpty else {
            return AudioClip(samples: samples, sampleRate: rate)
        }
        return AudioClip(samples: StreamingResampler.resample(samples, from: sampleRate, to: rate), sampleRate: rate)
    }
}

/// Stable identity for a voice detected in the programme audio.
public struct SpeakerID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Used when speaker recognition is unavailable for a line.
    public static let unknown = SpeakerID(0)

    public var description: String {
        rawValue == 0 ? "Unknown speaker" : "Speaker \(rawValue)"
    }

    public static func < (lhs: SpeakerID, rhs: SpeakerID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One stretch of continuous speech cut from the programme audio.
public struct Utterance: Sendable, Identifiable, Equatable {
    /// Consecutive sequence number, starting at 0. Playback order follows it.
    public let id: Int
    /// 16 kHz mono audio of the utterance.
    public let audio: AudioClip
    /// Start/end on the capture clock (seconds since capture started).
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(id: Int, audio: AudioClip, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.audio = audio
        self.startTime = startTime
        self.endTime = endTime
    }

    public var duration: TimeInterval { endTime - startTime }
}

public enum LineStatus: Sendable, Equatable {
    case identifyingSpeaker
    case transcribing
    case translating
    case synthesizing
    case queued
    case playing
    case played
    case skipped(String)
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .played, .skipped, .failed: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .identifyingSpeaker: return "Identifying voice…"
        case .transcribing: return "Transcribing…"
        case .translating: return "Translating…"
        case .synthesizing: return "Voicing…"
        case .queued: return "Queued"
        case .playing: return "Playing"
        case .played: return "Dubbed"
        case .skipped(let reason): return "Skipped – \(reason)"
        case .failed(let reason): return "Failed – \(reason)"
        }
    }
}

/// A line of dialogue as it moves through the dubbing pipeline.
public struct DubLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public var speaker: SpeakerID?
    public var japanese: String?
    public var english: String?
    public var delivery: String?
    public var status: LineStatus
    public let sourceStart: TimeInterval
    public let sourceEnd: TimeInterval
    /// Capture-clock time at which the dubbed audio was ready to play.
    public var readyAt: TimeInterval?

    public init(
        id: Int,
        speaker: SpeakerID? = nil,
        japanese: String? = nil,
        english: String? = nil,
        delivery: String? = nil,
        status: LineStatus,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        readyAt: TimeInterval? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.japanese = japanese
        self.english = english
        self.delivery = delivery
        self.status = status
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.readyAt = readyAt
    }

    /// Seconds between the end of the Japanese line and the dub being ready.
    public var processingLatency: TimeInterval? {
        readyAt.map { max(0, $0 - sourceEnd) }
    }
}

/// Synthesised English audio ready for playback.
public struct DubClip: Sendable, Equatable {
    public let lineID: Int
    public let speaker: SpeakerID
    public let audio: AudioClip
    /// End of the original Japanese line on the capture clock.
    public let sourceEnd: TimeInterval
    public let text: String

    public init(lineID: Int, speaker: SpeakerID, audio: AudioClip, sourceEnd: TimeInterval, text: String) {
        self.lineID = lineID
        self.speaker = speaker
        self.audio = audio
        self.sourceEnd = sourceEnd
        self.text = text
    }
}
