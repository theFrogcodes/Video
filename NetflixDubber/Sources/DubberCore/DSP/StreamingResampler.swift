import Foundation

/// Band-limited sample-rate converter (windowed-sinc interpolation) that can be
/// fed audio in arbitrarily sized blocks. Used for 48/44.1 kHz capture -> 16 kHz
/// analysis audio, and for TTS output -> playback rate.
public final class StreamingResampler {
    public let inputRate: Double
    public let outputRate: Double

    private let step: Double          // input samples advanced per output sample
    private let halfWidth: Int        // kernel half-width in input samples
    private let phases = 256          // kernel table resolution per input sample
    private let table: [Float]        // kernel(|x|) sampled at 1/phases steps
    private var history: [Float]      // unconsumed input incl. left context
    private var position: Double      // next output position, as an index into `history`

    /// - Parameter zeroCrossings: sinc zero crossings on each side of the
    ///   kernel; 16 gives >70 dB of stop-band rejection with a Blackman window.
    public init(inputRate: Double, outputRate: Double, zeroCrossings: Int = 16) {
        precondition(inputRate > 0 && outputRate > 0, "Sample rates must be positive")
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate

        // Cut-off relative to the input Nyquist frequency. When downsampling, cut
        // below the output Nyquist to avoid aliasing; leave a little transition band.
        let cutoff = min(1.0, outputRate / inputRate) * 0.92
        halfWidth = Int((Double(zeroCrossings) / cutoff).rounded(.up))

        var kernel = [Float](repeating: 0, count: halfWidth * phases + 2)
        for i in 0..<kernel.count {
            let x = Double(i) / Double(phases)
            kernel[i] = Float(Self.windowedSinc(x, cutoff: cutoff, halfWidth: Double(halfWidth)))
        }
        table = kernel

        history = [Float](repeating: 0, count: halfWidth)
        position = Double(halfWidth)
    }

    public var isPassthrough: Bool { inputRate == outputRate }

    /// Converts the next block of input; output length varies with block alignment.
    public func process(_ input: [Float]) -> [Float] {
        if isPassthrough { return input }
        guard !input.isEmpty else { return [] }

        history.append(contentsOf: input)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 2)

        history.withUnsafeBufferPointer { samples in
            table.withUnsafeBufferPointer { kernel in
                while Int(position) + halfWidth < samples.count {
                    output.append(interpolate(samples, kernel, at: position))
                    position += step
                }
            }
        }

        // Keep `halfWidth` samples of left context for the next block.
        let consumed = Int(position) - halfWidth
        if consumed > 0 {
            history.removeFirst(consumed)
            position -= Double(consumed)
        }
        return output
    }

    /// Emits the tail still held back for right-hand context.
    public func flush() -> [Float] {
        if isPassthrough { return [] }
        return process([Float](repeating: 0, count: halfWidth + 1))
    }

    /// One-shot conversion of a complete signal.
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty else { return samples }
        let resampler = StreamingResampler(inputRate: inputRate, outputRate: outputRate)
        var output = resampler.process(samples)
        output += resampler.flush()
        let expected = Int((Double(samples.count) * outputRate / inputRate).rounded())
        if output.count > expected { output.removeLast(output.count - expected) }
        return output
    }

    @inline(__always)
    private func interpolate(_ samples: UnsafeBufferPointer<Float>, _ kernel: UnsafeBufferPointer<Float>, at t: Double) -> Float {
        let center = Int(t)
        let fraction = t - Double(center)
        let scale = Double(phases)
        var accumulator: Float = 0
        var k = -halfWidth + 1
        while k <= halfWidth {
            // Distance between the tap and the output position, in input samples.
            let distance = abs(Double(k) - fraction) * scale
            let index = Int(distance)
            if index + 1 < kernel.count {
                let f = Float(distance - Double(index))
                let weight = kernel[index] + (kernel[index + 1] - kernel[index]) * f
                accumulator += samples[center + k] * weight
            }
            k += 1
        }
        return accumulator
    }

    private static func windowedSinc(_ x: Double, cutoff: Double, halfWidth: Double) -> Double {
        guard abs(x) < halfWidth else { return 0 }
        let arg = Double.pi * cutoff * x
        let sinc = x == 0 ? 1.0 : sin(arg) / arg
        let u = x / halfWidth
        let blackman = 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u)
        return cutoff * sinc * blackman
    }
}
