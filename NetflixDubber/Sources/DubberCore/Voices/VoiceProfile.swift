import Foundation

public enum VoiceGender: String, Codable, Sendable, CaseIterable {
    case feminine, masculine, neutral
}

/// Pitch range of a detected voice, estimated from its median F0.
public enum VocalRegister: String, Codable, Sendable, CaseIterable {
    case low, mid, high, veryHigh

    public init(pitchHz: Double?) {
        guard let hz = pitchHz else {
            self = .mid
            return
        }
        switch hz {
        case ..<145: self = .low
        case ..<200: self = .mid
        case ..<290: self = .high
        default: self = .veryHigh
        }
    }

    public var label: String {
        switch self {
        case .low: return "Low"
        case .mid: return "Mid"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }
}

/// A voice offered by a text-to-speech provider.
public struct VoiceOption: Sendable, Hashable, Codable, Identifiable {
    /// Provider-specific identifier (AVSpeechSynthesisVoice identifier, OpenAI voice name…).
    public let id: String
    public let name: String
    public let gender: VoiceGender
    /// Higher is better (e.g. premium > enhanced > compact Apple voices).
    public let quality: Int

    public init(id: String, name: String, gender: VoiceGender, quality: Int = 0) {
        self.id = id
        self.name = name
        self.gender = gender
        self.quality = quality
    }
}

/// The English dub voice automatically created for one detected speaker.
public struct VoiceProfile: Sendable, Hashable, Codable, Identifiable {
    public var id: SpeakerID { speaker }
    public let speaker: SpeakerID
    public var displayName: String
    public var voice: VoiceOption
    /// Applied by synthesizers that support it (Apple: 0.5–2.0).
    public var pitchMultiplier: Float
    public var register: VocalRegister
    /// Character description for expressive TTS (OpenAI `instructions`).
    public var persona: String
    public var isMuted: Bool

    public init(
        speaker: SpeakerID,
        displayName: String,
        voice: VoiceOption,
        pitchMultiplier: Float,
        register: VocalRegister,
        persona: String,
        isMuted: Bool = false
    ) {
        self.speaker = speaker
        self.displayName = displayName
        self.voice = voice
        self.pitchMultiplier = pitchMultiplier
        self.register = register
        self.persona = persona
        self.isMuted = isMuted
    }
}

/// OpenAI text-to-speech voices (gpt-4o-mini-tts). Gender tags are perceptual
/// defaults used only to match a voice to the original speaker's pitch.
public enum OpenAIVoiceCatalog {
    public static let voices: [VoiceOption] = [
        VoiceOption(id: "onyx", name: "Onyx", gender: .masculine, quality: 2),
        VoiceOption(id: "ash", name: "Ash", gender: .masculine, quality: 2),
        VoiceOption(id: "echo", name: "Echo", gender: .masculine, quality: 1),
        VoiceOption(id: "ballad", name: "Ballad", gender: .masculine, quality: 1),
        VoiceOption(id: "verse", name: "Verse", gender: .masculine, quality: 1),
        VoiceOption(id: "coral", name: "Coral", gender: .feminine, quality: 2),
        VoiceOption(id: "nova", name: "Nova", gender: .feminine, quality: 2),
        VoiceOption(id: "shimmer", name: "Shimmer", gender: .feminine, quality: 1),
        VoiceOption(id: "sage", name: "Sage", gender: .feminine, quality: 1),
        VoiceOption(id: "alloy", name: "Alloy", gender: .neutral, quality: 1),
        VoiceOption(id: "fable", name: "Fable", gender: .neutral, quality: 1),
    ]
}
