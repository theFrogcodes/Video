import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ClaudeConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    /// `output_config.effort`; low keeps latency down for short dialogue lines.
    public var effort: String
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(
        apiKey: String,
        model: String = ClaudeModelCatalog.defaultModel,
        effort: String = "low",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        timeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
        self.timeout = timeout
    }
}

public struct ClaudeModelOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
}

public enum ClaudeModelCatalog {
    public static let defaultModel = "claude-opus-5"

    public static let options: [ClaudeModelOption] = [
        ClaudeModelOption(id: "claude-opus-5", label: "Claude Opus 5 – best translations"),
        ClaudeModelOption(id: "claude-sonnet-5", label: "Claude Sonnet 5 – balanced"),
        ClaudeModelOption(id: "claude-haiku-4-5", label: "Claude Haiku 4.5 – lowest latency"),
    ]

    /// `output_config.effort` is rejected by Haiku 4.5.
    public static func supportsEffort(_ model: String) -> Bool {
        !model.hasPrefix("claude-haiku")
    }

    /// Models where server-side `fallbacks: "default"` recovers a safety-classifier decline.
    public static func supportsDefaultFallbacks(_ model: String) -> Bool {
        ["claude-opus-5", "claude-opus-5-5", "claude-fable-5-1"].contains(model)
    }
}

/// Translates Japanese dialogue into natural English dub lines with Claude.
public final class ClaudeTranslator: DialogueTranslator {
    public static let serviceName = "Claude"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let configuration: ClaudeConfiguration
    private let transport: HTTPTransport

    public init(configuration: ClaudeConfiguration, transport: HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func translate(_ request: TranslationRequest) async throws -> Translation {
        let urlRequest = try makeURLRequest(for: request)
        let data = try await HTTP.perform(urlRequest, service: Self.serviceName, transport: transport)
        return try Self.parseResponse(data)
    }

    static let systemPrompt = """
    You are the live dubbing translator for a Japanese TV series or film that is being dubbed into English in real time. \
    Each request contains one line of Japanese dialogue produced by speech recognition, the automatically detected speaker \
    (e.g. "Speaker 2"), how long the line lasted, and the recent dialogue for context.

    Write the English line a professional dub actor would say:
    - Natural, idiomatic spoken English that fits the scene and the characters' relationship, not a literal gloss.
    - About the same speaking time as the original; the request gives a target word count. Shorter beats longer.
    - Keep names. Drop honorifics (-san, -kun, -chan, -sama, senpai) unless they matter in the scene.
    - Speech recognition can mishear words; use the context to infer what was meant.
    - Output only the spoken words: no speaker labels, quotation marks, notes or stage directions.
    - If the input is not spoken dialogue (song lyrics, sound effects, on-screen captions, credits, or recognition \
    noise such as "ご視聴ありがとうございました"), return an empty string for english.

    Also return delivery: two to five words on how the line should be performed, e.g. "calm", "angry, shouting", \
    "whispering, nervous", "cheerful, teasing".
    """

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "english": ["type": "string"],
            "delivery": ["type": "string"],
        ],
        "required": ["english", "delivery"],
        "additionalProperties": false,
    ]

    static func userPrompt(for request: TranslationRequest) -> String {
        var lines: [String] = []
        if !request.history.isEmpty {
            lines.append("Recent dialogue (oldest first):")
            for turn in request.history {
                if let english = turn.english, !english.isEmpty {
                    lines.append("\(turn.speakerName): \(turn.japanese) → \(english)")
                } else {
                    lines.append("\(turn.speakerName): \(turn.japanese)")
                }
            }
            lines.append("")
        }
        let seconds = String(format: "%.1f", request.sourceDuration)
        lines.append("Line to dub:")
        lines.append("Speaker: \(request.speakerName)")
        lines.append("Duration: \(seconds) seconds (aim for about \(request.targetWordCount) English words)")
        lines.append("Japanese: \(request.japanese)")
        return lines.joined(separator: "\n")
    }

    func makeURLRequest(for request: TranslationRequest) throws -> URLRequest {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DubberServiceError.missingAPIKey(service: Self.serviceName) }

        let model = configuration.model
        var outputConfig: [String: Any] = [
            "format": ["type": "json_schema", "schema": Self.outputSchema],
        ]
        if ClaudeModelCatalog.supportsEffort(model) {
            outputConfig["effort"] = configuration.effort
        }

        var body: [String: Any] = [
            "model": model,
            // Caps thinking + answer together; the answer itself is one short line.
            "max_tokens": 2048,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": Self.userPrompt(for: request)],
            ],
            "output_config": outputConfig,
        ]

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if ClaudeModelCatalog.supportsDefaultFallbacks(model) {
            // If a safety classifier declines a line, re-run it on Anthropic's
            // recommended fallback model instead of losing the dub.
            body["fallbacks"] = "default"
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parseResponse(_ data: Data) throws -> Translation {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DubberServiceError.invalidResponse(service: serviceName, detail: "not a JSON object")
        }
        let stopReason = object["stop_reason"] as? String
        // Check the stop reason before reading content: a refusal has no usable answer.
        if stopReason == "refusal" {
            throw DubberServiceError.refused(service: serviceName)
        }
        if stopReason == "max_tokens" {
            throw DubberServiceError.invalidResponse(service: serviceName, detail: "response was truncated")
        }

        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let json = text.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let english = result["english"] as? String
        else {
            throw DubberServiceError.invalidResponse(service: serviceName, detail: "missing structured translation")
        }
        let delivery = result["delivery"] as? String ?? ""
        return Translation(
            english: english.trimmingCharacters(in: .whitespacesAndNewlines),
            delivery: delivery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
