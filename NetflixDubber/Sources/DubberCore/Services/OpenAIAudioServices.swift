import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var baseURL: URL
    public var transcriptionModel: String
    public var speechModel: String
    public var timeout: TimeInterval

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        transcriptionModel: String = "gpt-4o-transcribe",
        speechModel: String = "gpt-4o-mini-tts",
        timeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transcriptionModel = transcriptionModel
        self.speechModel = speechModel
        self.timeout = timeout
    }

    fileprivate func authorizedRequest(path: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DubberServiceError.missingAPIKey(service: "OpenAI") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Japanese speech recognition via OpenAI's transcription endpoint.
public final class OpenAITranscriber: SpeechTranscriber {
    public static let serviceName = "OpenAI transcription"

    public let configuration: OpenAIConfiguration
    private let transport: HTTPTransport

    public init(configuration: OpenAIConfiguration, transport: HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func transcribe(_ audio: AudioClip, context: TranscriptionContext) async throws -> String {
        let request = try makeURLRequest(audio: audio, context: context)
        let data = try await HTTP.perform(request, service: Self.serviceName, transport: transport)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String
        else {
            throw DubberServiceError.invalidResponse(service: Self.serviceName, detail: "missing text")
        }
        return text
    }

    func makeURLRequest(audio: AudioClip, context: TranscriptionContext) throws -> URLRequest {
        var request = try configuration.authorizedRequest(path: "v1/audio/transcriptions")
        var form = MultipartFormData()
        form.addField(name: "model", value: configuration.transcriptionModel)
        form.addField(name: "language", value: "ja")
        form.addField(name: "response_format", value: "json")
        // Previous lines as a prompt keep character names and terms consistent.
        let prompt = context.previousLines.suffix(2).joined(separator: "\n")
        if !prompt.isEmpty {
            form.addField(name: "prompt", value: String(prompt.suffix(400)))
        }
        form.addFile(
            name: "file",
            filename: "line.wav",
            mimeType: "audio/wav",
            data: WAVEncoder.encode(audio.resampled(to: 16_000))
        )
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }
}

/// Expressive English speech via OpenAI's text-to-speech endpoint. Each
/// speaker's persona and each line's delivery note become voice instructions.
public final class OpenAISpeechSynthesizer: DubSpeechSynthesizer {
    public static let serviceName = "OpenAI speech"
    /// `response_format: pcm` is raw 24 kHz signed 16-bit little-endian mono.
    public static let pcmSampleRate: Double = 24_000

    public let configuration: OpenAIConfiguration
    private let transport: HTTPTransport

    public init(configuration: OpenAIConfiguration, transport: HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func synthesize(_ text: String, voice: VoiceProfile, delivery: DeliveryStyle) async throws -> AudioClip {
        let request = try makeURLRequest(text: text, voice: voice, delivery: delivery)
        let data = try await HTTP.perform(request, service: Self.serviceName, transport: transport)
        guard data.count >= 2 else {
            throw DubberServiceError.invalidResponse(service: Self.serviceName, detail: "empty audio")
        }
        return WAVEncoder.decodePCM16(data, sampleRate: Self.pcmSampleRate)
    }

    static func instructions(voice: VoiceProfile, delivery: DeliveryStyle) -> String {
        var parts = [
            "Voice: \(voice.persona)",
            "Context: an English dub of a Japanese drama, performed live over the original scene.",
        ]
        if !delivery.note.isEmpty {
            parts.append("Delivery: \(delivery.note).")
        }
        parts.append("Perform in character with natural, brisk pacing; never read it flatly.")
        return parts.joined(separator: "\n")
    }

    func makeURLRequest(text: String, voice: VoiceProfile, delivery: DeliveryStyle) throws -> URLRequest {
        var request = try configuration.authorizedRequest(path: "v1/audio/speech")
        let body: [String: Any] = [
            "model": configuration.speechModel,
            "voice": voice.voice.id,
            "input": text,
            "instructions": Self.instructions(voice: voice, delivery: delivery),
            "response_format": "pcm",
        ]
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
