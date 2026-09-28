import Foundation

public struct TranscriptionContext: Sendable, Equatable {
    /// The most recent Japanese lines, oldest first; helps keep names consistent.
    public var previousLines: [String]

    public init(previousLines: [String] = []) {
        self.previousLines = previousLines
    }
}

/// Japanese speech -> Japanese text.
public protocol SpeechTranscriber: AnyObject {
    func transcribe(_ audio: AudioClip, context: TranscriptionContext) async throws -> String
}

public struct DialogueTurn: Sendable, Equatable {
    public var speakerName: String
    public var japanese: String
    public var english: String?

    public init(speakerName: String, japanese: String, english: String?) {
        self.speakerName = speakerName
        self.japanese = japanese
        self.english = english
    }
}

public struct TranslationRequest: Sendable, Equatable {
    public var japanese: String
    public var speakerName: String
    /// Length of the original line; the translation aims to fit a similar time.
    public var sourceDuration: TimeInterval
    /// Recent dialogue, oldest first.
    public var history: [DialogueTurn]

    public init(japanese: String, speakerName: String, sourceDuration: TimeInterval, history: [DialogueTurn]) {
        self.japanese = japanese
        self.speakerName = speakerName
        self.sourceDuration = sourceDuration
        self.history = history
    }

    /// Natural English dialogue runs at roughly 2.5 words per second.
    public var targetWordCount: Int {
        max(2, Int((sourceDuration * 2.5).rounded()))
    }
}

public struct Translation: Sendable, Equatable {
    /// Empty when the source wasn't dialogue (lyrics, noise…); the line is skipped.
    public var english: String
    public var delivery: String

    public init(english: String, delivery: String) {
        self.english = english
        self.delivery = delivery
    }
}

/// Japanese text -> English dub line.
public protocol DialogueTranslator: AnyObject {
    func translate(_ request: TranslationRequest) async throws -> Translation
}

/// English text -> speech in a speaker's assigned voice.
public protocol DubSpeechSynthesizer: AnyObject {
    func synthesize(_ text: String, voice: VoiceProfile, delivery: DeliveryStyle) async throws -> AudioClip
}
