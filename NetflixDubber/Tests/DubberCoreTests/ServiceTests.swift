import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DubberCore

final class ClaudeTranslatorTests: XCTestCase {
    private let request = TranslationRequest(
        japanese: "お前、何をしているんだ？",
        speakerName: "Speaker 2",
        sourceDuration: 2.0,
        history: [DialogueTurn(speakerName: "Speaker 1", japanese: "遅いぞ", english: "You're late.")]
    )

    private func successBody(english: String, delivery: String = "angry") -> Data {
        let answer = String(data: jsonData(["english": english, "delivery": delivery]), encoding: .utf8)!
        return jsonData([
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "model": "claude-opus-5",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "sig"],
                ["type": "text", "text": answer],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 5],
        ])
    }

    func testRequestShapeForOpus() throws {
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "sk-test"))
        let urlRequest = try translator.makeURLRequest(for: request)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = bodyJSON(urlRequest)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"], "thinking stays at the model default (adaptive)")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let prompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(prompt.contains("Speaker 1: 遅いぞ → You're late."))
        XCTAssertTrue(prompt.contains("Japanese: お前、何をしているんだ？"))
        XCTAssertTrue(prompt.contains("about 5 English words"))
    }

    func testHaikuOmitsEffortAndFallbacks() throws {
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "k", model: "claude-haiku-4-5"))
        let urlRequest = try translator.makeURLRequest(for: request)
        let body = bodyJSON(urlRequest)
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertNil(outputConfig["effort"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testMissingKeyIsFatal() {
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "  "))
        XCTAssertThrowsError(try translator.makeURLRequest(for: request)) { error in
            XCTAssertEqual(error as? DubberServiceError, .missingAPIKey(service: "Claude"))
            XCTAssertTrue((error as? DubberServiceError)?.isFatal ?? false)
        }
    }

    func testTranslateParsesStructuredOutput() async throws {
        let transport = MockTransport([.init(status: 200, body: successBody(english: " What are you doing? "))])
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "k"), transport: transport)
        let translation = try await translator.translate(request)
        XCTAssertEqual(translation, Translation(english: "What are you doing?", delivery: "angry"))
    }

    func testRefusalAndTruncationAreErrors() {
        let refusal = jsonData(["content": [], "stop_reason": "refusal", "stop_details": ["type": "refusal", "category": NSNull()]])
        XCTAssertThrowsError(try ClaudeTranslator.parseResponse(refusal)) { error in
            XCTAssertEqual(error as? DubberServiceError, .refused(service: "Claude"))
        }
        let truncated = jsonData(["content": [["type": "text", "text": "{\"engl"]], "stop_reason": "max_tokens"])
        XCTAssertThrowsError(try ClaudeTranslator.parseResponse(truncated))
    }

    func testAuthenticationErrorIsNotRetried() async {
        let body = jsonData(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])
        let transport = MockTransport([.init(status: 401, body: body), .init(status: 200, body: successBody(english: "Hi"))])
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "bad"), transport: transport)
        do {
            _ = try await translator.translate(request)
            XCTFail("expected an error")
        } catch let error as DubberServiceError {
            XCTAssertEqual(error, .authentication(service: "Claude", message: "invalid x-api-key"))
            XCTAssertTrue(error.isFatal)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testServerErrorIsRetriedOnce() async throws {
        let overloaded = jsonData(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
        let transport = MockTransport([.init(status: 529, body: overloaded), .init(status: 200, body: successBody(english: "Hi"))])
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "k"), transport: transport)
        let translation = try await translator.translate(request)
        XCTAssertEqual(translation.english, "Hi")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testLongRateLimitIsNotWaitedFor() async {
        let transport = MockTransport([.init(status: 429, body: Data(), headers: ["retry-after": "30"])])
        let translator = ClaudeTranslator(configuration: ClaudeConfiguration(apiKey: "k"), transport: transport)
        do {
            _ = try await translator.translate(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DubberServiceError, .rateLimited(service: "Claude", retryAfter: 30))
        }
        XCTAssertEqual(transport.requestCount, 1)
    }
}

final class OpenAIServiceTests: XCTestCase {
    func testTranscriptionRequestIsMultipartWav() async throws {
        let transport = MockTransport([.init(status: 200, body: jsonData(["text": "行くぞ"]))])
        let transcriber = OpenAITranscriber(configuration: OpenAIConfiguration(apiKey: "sk-o"), transport: transport)
        let clip = AudioClip(samples: Synth.voiced(f0: 150, duration: 0.5, sampleRate: 48_000), sampleRate: 48_000)
        let text = try await transcriber.transcribe(clip, context: TranscriptionContext(previousLines: ["遅いぞ"]))
        XCTAssertEqual(text, "行くぞ")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-o")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = try XCTUnwrap(request.httpBody)
        let text8 = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text8.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe"))
        XCTAssertTrue(text8.contains("name=\"language\"\r\n\r\nja"))
        XCTAssertTrue(text8.contains("name=\"prompt\"\r\n\r\n遅いぞ"))
        XCTAssertTrue(text8.contains("filename=\"line.wav\""))
        // 0.5 s at 16 kHz, 16-bit, plus the 44-byte header.
        XCTAssertGreaterThan(body.count, 16_000)
    }

    func testSpeechRequestAndPCMDecoding() async throws {
        var pcm = Data()
        for value: Int16 in [0, 16_384, -16_384, 32_767] { pcm.appendLittleEndian(value) }
        let transport = MockTransport([.init(status: 200, body: pcm)])
        let synthesizer = OpenAISpeechSynthesizer(configuration: OpenAIConfiguration(apiKey: "sk-o"), transport: transport)
        let profile = VoiceProfile(
            speaker: SpeakerID(1), displayName: "Speaker 1",
            voice: VoiceOption(id: "onyx", name: "Onyx", gender: .masculine),
            pitchMultiplier: 1, register: .low, persona: "A deep voice."
        )
        let clip = try await synthesizer.synthesize("Let's go.", voice: profile, delivery: DeliveryStyle.parse("excited"))
        XCTAssertEqual(clip.sampleRate, 24_000)
        XCTAssertEqual(clip.samples.count, 4)
        XCTAssertEqual(clip.samples[1], 0.5, accuracy: 1e-4)
        XCTAssertEqual(clip.samples[2], -0.5, accuracy: 1e-4)

        let body = bodyJSON(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(body["voice"] as? String, "onyx")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("A deep voice."))
        XCTAssertTrue(instructions.contains("excited"))
    }

    func testWAVHeader() {
        let data = WAVEncoder.encode(AudioClip(samples: [0, 1, -1, 2], sampleRate: 16_000))
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let sampleRate = data[24..<28].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        XCTAssertEqual(sampleRate, 16_000)
        // Clipped: 2 -> +32767
        let last = Int16(bitPattern: UInt16(data[50]) | UInt16(data[51]) << 8)
        XCTAssertEqual(last, 32_767)
    }
}
