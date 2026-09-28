import Foundation

public struct MFCCConfiguration: Sendable {
    public var sampleRate: Double = 16_000
    public var frameLength: Int = 400          // 25 ms
    public var hopLength: Int = 160            // 10 ms
    public var fftSize: Int = 512
    public var melBands: Int = 40
    public var coefficients: Int = 20          // including c0
    public var minFrequency: Double = 60
    public var maxFrequency: Double = 7_600
    public var preEmphasis: Float = 0.97

    public init() {}
}

/// Mel-frequency cepstral coefficients: the classic compact description of
/// vocal-tract shape (timbre), used by the fallback speaker voiceprint.
public final class MFCCExtractor {
    public let configuration: MFCCConfiguration
    private let fft: FFT
    private let window: [Float]
    private let filters: [(start: Int, weights: [Float])]
    private let dct: [[Float]]   // [coefficient][band]

    public init(configuration: MFCCConfiguration = MFCCConfiguration()) {
        self.configuration = configuration
        fft = FFT(size: configuration.fftSize)

        let n = configuration.frameLength
        window = (0..<n).map { i in
            Float(0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
        }

        filters = Self.melFilterbank(configuration)

        let bands = configuration.melBands
        dct = (0..<configuration.coefficients).map { k in
            let scale = k == 0 ? (1.0 / Double(bands)).squareRoot() : (2.0 / Double(bands)).squareRoot()
            return (0..<bands).map { m in
                Float(scale * cos(Double.pi * Double(k) * (Double(m) + 0.5) / Double(bands)))
            }
        }
    }

    public struct Frames {
        /// One row per frame, `coefficients` values per row (c0 first).
        public var coefficients: [[Float]]
        /// Frame energy in dB (pre-emphasised signal).
        public var energyDB: [Float]
    }

    public func extract(_ samples: [Float]) -> Frames {
        let config = configuration
        guard samples.count >= config.frameLength else {
            return Frames(coefficients: [], energyDB: [])
        }

        var emphasized = [Float](repeating: 0, count: samples.count)
        emphasized[0] = samples[0]
        for i in 1..<samples.count {
            emphasized[i] = samples[i] - config.preEmphasis * samples[i - 1]
        }

        var rows: [[Float]] = []
        var energies: [Float] = []
        var frame = [Float](repeating: 0, count: config.frameLength)
        var start = 0
        while start + config.frameLength <= emphasized.count {
            var energy: Float = 0
            for i in 0..<config.frameLength {
                let value = emphasized[start + i]
                energy += value * value
                frame[i] = value * window[i]
            }
            energies.append(VectorMath.decibels(power: energy / Float(config.frameLength)))

            let power = fft.powerSpectrum(frame)
            var logMel = [Float](repeating: 0, count: filters.count)
            for (band, filter) in filters.enumerated() {
                var sum: Float = 0
                for (offset, weight) in filter.weights.enumerated() {
                    sum += power[filter.start + offset] * weight
                }
                logMel[band] = log(max(sum, 1e-10))
            }

            rows.append(dct.map { basis in
                var c: Float = 0
                for m in 0..<basis.count { c += basis[m] * logMel[m] }
                return c
            })
            start += config.hopLength
        }
        return Frames(coefficients: rows, energyDB: energies)
    }

    private static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    private static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

    private static func melFilterbank(_ config: MFCCConfiguration) -> [(start: Int, weights: [Float])] {
        let bins = config.fftSize / 2 + 1
        let maxFrequency = min(config.maxFrequency, config.sampleRate / 2)
        let lowMel = hzToMel(config.minFrequency)
        let highMel = hzToMel(maxFrequency)
        let points = (0...(config.melBands + 1)).map { i -> Double in
            let mel = lowMel + (highMel - lowMel) * Double(i) / Double(config.melBands + 1)
            return melToHz(mel) * Double(config.fftSize) / config.sampleRate   // fractional FFT bin
        }

        return (0..<config.melBands).map { band in
            let left = points[band], center = points[band + 1], right = points[band + 2]
            let first = max(0, Int(left.rounded(.up)))
            let last = min(bins - 1, Int(right.rounded(.down)))
            guard first <= last else { return (start: min(first, bins - 1), weights: [0]) }
            let weights = (first...last).map { bin -> Float in
                let x = Double(bin)
                if x <= center {
                    return Float(center > left ? (x - left) / (center - left) : 1)
                }
                return Float(right > center ? (right - x) / (right - center) : 1)
            }
            return (start: first, weights: weights)
        }
    }
}
