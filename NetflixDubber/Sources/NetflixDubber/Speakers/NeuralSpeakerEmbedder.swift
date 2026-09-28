import DubberCore
import FluidAudio
import Foundation

/// Neural voiceprints from the WeSpeaker model (via FluidAudio), running on the
/// Apple Neural Engine. The Core ML models (up to ~100 MB) download from Hugging Face
/// on first use and are cached in Application Support.
final class NeuralSpeakerEmbedder: SpeakerEmbeddingExtractor, @unchecked Sendable {
    let displayName = "Neural voiceprint (WeSpeaker, on-device)"
    /// Cosine distance between utterance-level WeSpeaker embeddings above which
    /// voices are treated as different people. Tunable in the UI.
    let recommendedNewSpeakerDistance: Float = 0.65

    private let manager: DiarizerManager
    /// DiarizerManager isn't thread-safe; all inference runs on this queue.
    private let queue = DispatchQueue(label: "netflix-dubber.speaker-embedding", qos: .userInitiated)
    /// The model's receptive window is 10 s; longer clips are trimmed to their middle.
    private let maximumSamples = 160_000
    private let minimumSamples = 4_000

    private init(manager: DiarizerManager) {
        self.manager = manager
    }

    static func load() async throws -> NeuralSpeakerEmbedder {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return NeuralSpeakerEmbedder(manager: manager)
    }

    func embedding(for audio: DubberCore.AudioClip) async throws -> [Float] {
        var samples = audio.resampled(to: 16_000).samples
        if samples.count > maximumSamples {
            let start = (samples.count - maximumSamples) / 2
            samples = Array(samples[start..<(start + maximumSamples)])
        }
        // The extractor masks to the clip's real length, so short clips need no padding
        // (padding would dilute the voiceprint with silence).
        // Too short to fingerprint reliably: an empty voiceprint makes the pipeline
        // attribute the line to the previous speaker.
        guard samples.count >= minimumSamples else { return [] }
        let input = samples
        let manager = self.manager
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try manager.extractSpeakerEmbedding(from: input))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
