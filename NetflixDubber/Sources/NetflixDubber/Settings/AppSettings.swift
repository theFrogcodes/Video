import DubberCore
import Foundation

enum RecognitionProvider: String, CaseIterable, Identifiable {
    case openAI, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI gpt-4o-transcribe (most accurate)"
        case .apple: return "Apple on-device (free, private)"
        }
    }
}

enum VoiceProvider: String, CaseIterable, Identifiable {
    case apple, openAI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple system voices (free, instant)"
        case .openAI: return "OpenAI expressive voices (acted delivery)"
        }
    }
}

/// User preferences. Non-secret values persist in UserDefaults; API keys in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var recognition: RecognitionProvider { didSet { defaults.set(recognition.rawValue, forKey: "recognition") } }
    @Published var voices: VoiceProvider { didSet { defaults.set(voices.rawValue, forKey: "voices") } }
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    @Published var captureTarget: CaptureTarget { didSet { defaults.set(captureTarget.rawValue, forKey: "captureTarget") } }
    /// Level of the original soundtrack while a line is being dubbed (0…1).
    @Published var originalLevelWhileDubbing: Double { didSet { defaults.set(originalLevelWhileDubbing, forKey: "originalLevel") } }
    @Published var duckDuringOriginalSpeech: Bool { didSet { defaults.set(duckDuringOriginalSpeech, forKey: "duckOriginal") } }
    @Published var dubVolume: Double { didSet { defaults.set(dubVolume, forKey: "dubVolume") } }
    /// 0 = merge similar voices, 1 = split voices eagerly.
    @Published var speakerSensitivity: Double { didSet { defaults.set(speakerSensitivity, forKey: "speakerSensitivity") } }
    /// Dubs that would start later than this after the original line are dropped.
    @Published var maximumLag: Double { didSet { defaults.set(maximumLag, forKey: "maximumLag") } }

    @Published private(set) var anthropicKey: String
    @Published private(set) var openAIKey: String
    @Published var keychainError: String?

    init() {
        let defaults = UserDefaults.standard
        recognition =RecognitionProvider(rawValue: defaults.string(forKey: "recognition") ?? "") ?? .openAI
        voices = VoiceProvider(rawValue: defaults.string(forKey: "voices") ?? "") ?? .apple
        claudeModel = defaults.string(forKey: "claudeModel") ?? ClaudeModelCatalog.defaultModel
        captureTarget = CaptureTarget(rawValue: defaults.string(forKey: "captureTarget") ?? "") ?? .allSystemAudio
        originalLevelWhileDubbing = defaults.object(forKey: "originalLevel") as? Double ?? 0.15
        duckDuringOriginalSpeech = defaults.object(forKey: "duckOriginal") as? Bool ?? true
        dubVolume = defaults.object(forKey: "dubVolume") as? Double ?? 1.0
        speakerSensitivity = defaults.object(forKey: "speakerSensitivity") as? Double ?? 0.5
        maximumLag = defaults.object(forKey: "maximumLag") as? Double ?? 7

        // Environment variables are a convenience for development runs.
        let environment = ProcessInfo.processInfo.environment
        anthropicKey = KeychainStore.read(.anthropic) ?? environment["ANTHROPIC_API_KEY"] ?? ""
        openAIKey = KeychainStore.read(.openAI) ?? environment["OPENAI_API_KEY"] ?? ""
    }

    var needsOpenAIKey: Bool { recognition == .openAI || voices == .openAI }

    func saveAnthropicKey(_ key: String) {
        store(key, account: .anthropic) { self.anthropicKey = $0 }
    }

    func saveOpenAIKey(_ key: String) {
        store(key, account: .openAI) { self.openAIKey = $0 }
    }

    private func store(_ key: String, account: KeychainStore.Account, apply: (String) -> Void) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(trimmed, for: account)
            apply(trimmed)
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// Maps the 0…1 sensitivity slider around the embedder's recommended threshold.
    func newSpeakerDistance(recommended: Float) -> Float {
        let factor = 1.3 - 0.6 * Float(speakerSensitivity)   // 1.3× (merge) … 0.7× (split)
        return max(0.1, min(1.5, recommended * factor))
    }
}
