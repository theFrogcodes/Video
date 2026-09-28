import Foundation

/// Lightweight, fully offline voiceprint built from MFCC statistics and pitch.
///
/// Used when the neural (WeSpeaker/Core ML) model can't be loaded. It separates
/// clearly different voices (e.g. a man and a woman, an adult and a child) well,
/// but is less reliable than the neural model for similar-sounding voices.
public final class SpectralSpeakerEmbedder: SpeakerEmbeddingExtractor, @unchecked Sendable {
    public let displayName = "Built-in spectral voiceprint (offline fallback)"
    public let recommendedNewSpeakerDistance: Float = 0.5

    private let sampleRate: Double = 16_000
    private let mfcc = MFCCExtractor()
    private let pitch = PitchEstimator()
    private let lock = NSLock()
    /// Show-wide statistics of MFCC frames; voiceprints describe how a voice
    /// deviates from the programme's average sound, which cancels most of the
    /// channel colouring (mixing, EQ) shared by every speaker.
    private var statistics = RunningStatistics(dimension: 19)

    public init() {}

    public func embedding(for audio: AudioClip) async throws -> [Float] {
        computeEmbedding(audio)
    }

    public func computeEmbedding(_ audio: AudioClip) -> [Float] {
        let clip = audio.resampled(to: sampleRate)
        let frames = mfcc.extract(clip.samples)
        guard !frames.coefficients.isEmpty else { return [] }

        // Keep the louder frames (voiced speech); drop pauses and breaths.
        let loudest = frames.energyDB.max() ?? 0
        var selected: [[Float]] = []
        for (index, row) in frames.coefficients.enumerated() where frames.energyDB[index] > loudest - 30 {
            selected.append(Array(row.dropFirst()))   // drop c0 (loudness)
        }
        if selected.count < 5 {
            selected = frames.coefficients.map { Array($0.dropFirst()) }
        }

        lock.lock()
        for row in selected { statistics.add(row) }
        let mean = statistics.mean
        let deviation = statistics.standardDeviation
        lock.unlock()

        let dimension = mean.count
        var sum = [Double](repeating: 0, count: dimension)
        var sumSquares = [Double](repeating: 0, count: dimension)
        for row in selected {
            for i in 0..<dimension {
                let z = (Double(row[i]) - mean[i]) / max(deviation[i], 1e-3)
                sum[i] += z
                sumSquares[i] += z * z
            }
        }
        let n = Double(selected.count)
        var vector: [Float] = []
        vector.reserveCapacity(dimension * 2 + 2)
        for i in 0..<dimension {
            vector.append(Float(sum[i] / n))
        }
        for i in 0..<dimension {
            let m = sum[i] / n
            let variance = max(0, sumSquares[i] / n - m * m)
            vector.append(Float((variance.squareRoot() - 1) * 0.5))
        }

        // Pitch strongly separates male / female / child voices.
        let summary = pitch.summarize(clip.samples)
        if let hz = summary.medianHz {
            vector.append(Float(log2(hz / 160) * 3))
        } else {
            vector.append(0)
        }
        vector.append(Float(summary.voicedFraction - 0.5))
        return vector
    }
}
