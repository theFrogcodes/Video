import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors raised by the cloud services. Messages never include API keys.
public enum DubberServiceError: LocalizedError, Equatable {
    case missingAPIKey(service: String)
    case authentication(service: String, message: String)
    case rateLimited(service: String, retryAfter: TimeInterval?)
    case badRequest(service: String, message: String)
    case server(service: String, status: Int, message: String)
    case timedOut(service: String)
    case network(service: String, message: String)
    case refused(service: String)
    case invalidResponse(service: String, detail: String)

    /// Errors that won't go away by retrying the next line (bad key, bad config).
    public var isFatal: Bool {
        switch self {
        case .missingAPIKey, .authentication: return true
        case .badRequest: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let service):
            return "\(service) API key is missing. Add it in Settings."
        case .authentication(let service, let message):
            return "\(service) rejected the API key: \(message)"
        case .rateLimited(let service, let retryAfter):
            if let retryAfter { return "\(service) rate limit reached; retry in \(Int(retryAfter.rounded(.up)))s." }
            return "\(service) rate limit reached."
        case .badRequest(let service, let message):
            return "\(service) rejected the request: \(message)"
        case .server(let service, let status, let message):
            return "\(service) server error \(status): \(message)"
        case .timedOut(let service):
            return "\(service) took too long to respond."
        case .network(let service, let message):
            return "Couldn't reach \(service): \(message)"
        case .refused(let service):
            return "\(service) declined to process this line."
        case .invalidResponse(let service, let detail):
            return "Unexpected response from \(service): \(detail)"
        }
    }
}

/// Minimal HTTP abstraction so the API clients can be unit-tested offline.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: bridge the callback API.
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

enum HTTP {
    /// Sends a request, mapping transport and HTTP failures to `DubberServiceError`.
    /// Retries once, quickly, for transient failures: the pipeline is live, so a
    /// long back-off would only produce a dub for a line that's long gone.
    static func perform(
        _ request: URLRequest,
        service: String,
        transport: HTTPTransport,
        attempts: Int = 2
    ) async throws -> Data {
        var lastError: DubberServiceError = .network(service: service, message: "No attempt made")
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    return data
                }
                let error = mapStatus(response.statusCode, data: data, headers: response, service: service)
                guard isRetryable(error) else { throw error }
                lastError = error
                if case .rateLimited(_, let retryAfter) = error, let retryAfter, retryAfter > 2 {
                    throw error   // not worth waiting for in a live dub
                }
            } catch let error as DubberServiceError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let mapped: DubberServiceError = error.code == .timedOut
                    ? .timedOut(service: service)
                    : .network(service: service, message: error.localizedDescription)
                lastError = mapped
                guard error.code != .timedOut else { throw mapped }
            }
            if attempt + 1 < attempts {
                try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
        }
        throw lastError
    }

    static func isRetryable(_ error: DubberServiceError) -> Bool {
        switch error {
        case .rateLimited, .server, .network: return true
        default: return false
        }
    }

    static func mapStatus(_ status: Int, data: Data, headers: HTTPURLResponse, service: String) -> DubberServiceError {
        let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403:
            return .authentication(service: service, message: message)
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0) }
            return .rateLimited(service: service, retryAfter: retryAfter)
        case 400, 404, 413, 422:
            return .badRequest(service: service, message: message)
        case 408:
            return .timedOut(service: service)
        default:
            return .server(service: service, status: status, message: message)
        }
    }

    /// Extracts `error.message` from Anthropic/OpenAI style error bodies.
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(300))
        }
        if let message = object["message"] as? String {
            return String(message.prefix(300))
        }
        return nil
    }
}

/// Builds `multipart/form-data` bodies (used for audio uploads).
public struct MultipartFormData {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "DubberBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}

/// 16-bit PCM WAV encoding for speech-recognition uploads.
public enum WAVEncoder {
    public static func encode(_ clip: AudioClip) -> Data {
        let sampleRate = UInt32(clip.sampleRate.rounded())
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(clip.samples.count) * UInt32(blockAlign)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))          // PCM chunk size
        data.appendLittleEndian(UInt16(1))           // PCM format
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(Data("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in clip.samples {
            let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
            data.appendLittleEndian(Int16((clipped * 32767).rounded()))
        }
        return data
    }

    /// Decodes raw little-endian signed 16-bit mono PCM.
    public static func decodePCM16(_ data: Data, sampleRate: Double) -> AudioClip {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                samples[i] = Float(Int16(littleEndian: value)) / 32768
            }
        }
        return AudioClip(samples: samples, sampleRate: sampleRate)
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
