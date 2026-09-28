import Foundation

/// Radix-2 FFT for real input, returning the one-sided power spectrum.
/// Pure Swift so DubberCore has no platform dependencies and can be unit-tested anywhere.
public struct FFT: Sendable {
    public let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReversed: [Int]

    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size

        var cosines = [Float](repeating: 0, count: size / 2)
        var sines = [Float](repeating: 0, count: size / 2)
        for k in 0..<(size / 2) {
            let angle = 2 * Double.pi * Double(k) / Double(size)
            cosines[k] = Float(cos(angle))
            sines[k] = Float(sin(angle))
        }
        cosTable = cosines
        sinTable = sines

        let bits = size.trailingZeroBitCount
        bitReversed = (0..<size).map { index in
            var reversed = 0
            var value = index
            for _ in 0..<bits {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            return reversed
        }
    }

    /// |X[k]|² for k in 0...size/2. Input shorter than `size` is zero-padded.
    public func powerSpectrum(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        var real = [Float](repeating: 0, count: size)
        var imag = [Float](repeating: 0, count: size)
        let count = min(input.count, size)
        for i in 0..<count {
            real[bitReversed[i]] = input[i]
        }

        var half = 1
        while half < size {
            let tableStep = size / (half * 2)
            var start = 0
            while start < size {
                for j in 0..<half {
                    let twiddle = j * tableStep
                    let c = cosTable[twiddle]
                    let s = sinTable[twiddle]
                    let top = start + j
                    let bottom = top + half
                    // (re + i·im) · (cos − i·sin)
                    let tr = real[bottom] * c + imag[bottom] * s
                    let ti = imag[bottom] * c - real[bottom] * s
                    real[bottom] = real[top] - tr
                    imag[bottom] = imag[top] - ti
                    real[top] += tr
                    imag[top] += ti
                }
                start += half * 2
            }
            half *= 2
        }

        var power = [Float](repeating: 0, count: size / 2 + 1)
        for k in 0...(size / 2) {
            power[k] = real[k] * real[k] + imag[k] * imag[k]
        }
        return power
    }

    public func powerSpectrum(_ input: [Float]) -> [Float] {
        input.withUnsafeBufferPointer { powerSpectrum($0) }
    }
}
