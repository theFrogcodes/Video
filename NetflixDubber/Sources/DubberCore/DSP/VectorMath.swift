import Foundation

/// Small numeric helpers shared by the DSP and speaker-tracking code.
public enum VectorMath {
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dot: dimension mismatch")
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    public static func norm(_ a: [Float]) -> Float {
        dot(a, a).squareRoot()
    }

    /// Unit-length copy of `a`, or nil for an all-zero / non-finite vector.
    public static func l2Normalized(_ a: [Float]) -> [Float]? {
        let n = norm(a)
        guard n.isFinite, n > 1e-9 else { return nil }
        return a.map { $0 / n }
    }

    /// 1 - cosine similarity. Returns 2 (maximally different) for degenerate input.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        let na = norm(a), nb = norm(b)
        guard na > 1e-9, nb > 1e-9 else { return 2 }
        return 1 - dot(a, b) / (na * nb)
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func decibels(power: Float) -> Float {
        10 * log10(max(power, 1e-12))
    }

    /// Linear-interpolated percentile, `p` in 0...1.
    public static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = max(0, min(1, p)) * Float(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Float(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Welford running mean/variance per dimension.
public struct RunningStatistics: Sendable {
    public private(set) var count: Int = 0
    public private(set) var mean: [Double]
    private var m2: [Double]

    public init(dimension: Int) {
        mean = [Double](repeating: 0, count: dimension)
        m2 = [Double](repeating: 0, count: dimension)
    }

    public var dimension: Int { mean.count }

    public mutating func add(_ x: [Float]) {
        guard x.count == mean.count else { return }
        count += 1
        let n = Double(count)
        for i in 0..<x.count {
            let value = Double(x[i])
            let delta = value - mean[i]
            mean[i] += delta / n
            m2[i] += delta * (value - mean[i])
        }
    }

    public var standardDeviation: [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: mean.count) }
        return m2.map { ($0 / Double(count - 1)).squareRoot() }
    }
}
