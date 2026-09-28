import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DubberCore

/// Deterministic synthetic audio for tests.
enum Synth {
    /// Speech-like harmonic signal: fundamental `f0` with 1/k harmonics up to
    /// ~3.5 kHz, amplitude-modulated into syllables (with short dips) at `syllableRate`.
    static func voiced(
        f0: Double,
        duration: TimeInterval,
        sampleRate: Double = 16_000,
        amplitude: Float = 0.3,
        syllableRate: Double = 4
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        let harmonics = max(1, Int(3_500 / f0))
        var samples = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / sampleRate
            var value = 0.0
            for k in 1...harmonics {
                value += sin(2 * Double.pi * f0 * Double(k) * t) / Double(k)
            }
            let phase = (t * syllableRate).truncatingRemainder(dividingBy: 1)
            let envelope = max(0.02, pow(sin(Double.pi * phase), 0.7))
            samples[n] = Float(value * envelope * 0.5) * amplitude
        }
        return samples
    }

    static func sine(frequency: Double, duration: TimeInterval, sampleRate: Double, amplitude: Float = 1) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { n in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(n) / sampleRate))
        }
    }

    /// Low-level deterministic noise (room tone).
    static func noise(duration: TimeInterval, sampleRate: Double = 16_000, level: Float = 0.0005) -> [Float] {
        var state: UInt32 = 0x1234_5678
        return (0..<Int(duration * sampleRate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state) / Float(UInt32.max) * 2 - 1) * level
        }
    }
}

func rms(_ samples: [Float]) -> Float {
    VectorMath.rms(samples[...])
}

/// Counts upward zero crossings to estimate a tone's frequency.
func estimatedFrequency(_ samples: [Float], sampleRate: Double) -> Double {
    var crossings = 0
    for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 {
        crossings += 1
    }
    return Double(crossings) / (Double(samples.count) / sampleRate)
}

/// Scripted HTTP responses; records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var queue: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        queue = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = record(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }

    private func record(_ request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return queue.isEmpty ? Response(status: 500, body: Data()) : queue.removeFirst()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func bodyJSON(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}
