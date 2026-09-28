import Foundation

public struct PitchSummary: Sendable, Equatable {
    /// Median fundamental frequency of voiced frames, nil when nothing was voiced.
    public var medianHz: Double?
    /// Fraction of analysed (non-silent) frames that were voiced.
    public var voicedFraction: Double

    public init(medianHz: Double?, voicedFraction: Double) {
        self.medianHz = medianHz
        self.voicedFraction = voicedFraction
    }
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
/// Voice pitch drives the automatic voice design (deep / mid / high / child-like).
public struct PitchEstimator: Sendable {
    public var sampleRate: Double
    public var minimumHz: Double
    public var maximumHz: Double
    /// Cumulative-mean-normalised difference threshold; lower is stricter.
    public var threshold: Float
    public var windowLength: Int
    public var hopLength: Int

    public init(
        sampleRate: Double = 16_000,
        minimumHz: Double = 60,
        maximumHz: Double = 600,
        threshold: Float = 0.15,
        windowDuration: Double = 0.025,
        hopDuration: Double = 0.02
    ) {
        self.sampleRate = sampleRate
        self.minimumHz = minimumHz
        self.maximumHz = maximumHz
        self.threshold = threshold
        windowLength = Int(windowDuration * sampleRate)
        hopLength = max(1, Int(hopDuration * sampleRate))
    }

    /// Per-frame F0 in Hz (nil = unvoiced or silent).
    public func track(_ samples: [Float]) -> [Double?] {
        let tauMax = Int(sampleRate / minimumHz)
        let tauMin = max(2, Int(sampleRate / maximumHz))
        let span = windowLength + tauMax + 1
        guard samples.count >= span, tauMax > tauMin else { return [] }

        // Ignore frames far quieter than the loudest part of the clip.
        var peakRMS: Float = 0
        var start = 0
        while start + windowLength <= samples.count {
            peakRMS = max(peakRMS, VectorMath.rms(samples[start..<(start + windowLength)]))
            start += hopLength
        }
        let silenceRMS = max(peakRMS * 0.05, 1e-4)

        var result: [Double?] = []
        var difference = [Float](repeating: 0, count: tauMax + 2)
        samples.withUnsafeBufferPointer { x in
            var frameStart = 0
            while frameStart + span <= x.count {
                defer { frameStart += hopLength }
                let rms = VectorMath.rms(samples[frameStart..<(frameStart + windowLength)])
                guard rms >= silenceRMS else {
                    result.append(nil)
                    continue
                }

                // Difference function d(τ).
                for tau in 1...tauMax {
                    var sum: Float = 0
                    for j in 0..<windowLength {
                        let delta = x[frameStart + j] - x[frameStart + j + tau]
                        sum += delta * delta
                    }
                    difference[tau] = sum
                }

                // Cumulative mean normalised difference d'(τ).
                difference[0] = 1
                var running: Float = 0
                for tau in 1...tauMax {
                    running += difference[tau]
                    difference[tau] = running > 0 ? difference[tau] * Float(tau) / running : 1
                }

                // First dip under the threshold, then walk to its local minimum.
                var estimate: Int?
                var tau = tauMin
                while tau <= tauMax {
                    if difference[tau] < threshold {
                        while tau + 1 <= tauMax && difference[tau + 1] < difference[tau] {
                            tau += 1
                        }
                        estimate = tau
                        break
                    }
                    tau += 1
                }

                guard let best = estimate else {
                    result.append(nil)
                    continue
                }

                // Parabolic interpolation around the minimum for sub-sample accuracy.
                var refined = Double(best)
                if best > 1 && best < tauMax {
                    let a = difference[best - 1], b = difference[best], c = difference[best + 1]
                    let denominator = a - 2 * b + c
                    if abs(denominator) > 1e-9 {
                        refined += Double(0.5 * (a - c) / denominator)
                    }
                }
                let hz = sampleRate / refined
                result.append(hz >= minimumHz && hz <= maximumHz ? hz : nil)
            }
        }
        return result
    }

    public func summarize(_ samples: [Float]) -> PitchSummary {
        let frames = track(samples)
        let analysed = frames.count
        let voiced = frames.compactMap { $0 }
        guard analysed > 0 else { return PitchSummary(medianHz: nil, voicedFraction: 0) }
        return PitchSummary(
            medianHz: voiced.count >= 3 ? VectorMath.median(voiced) : nil,
            voicedFraction: Double(voiced.count) / Double(analysed)
        )
    }
}
