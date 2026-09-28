import Foundation

/// Produces a fixed-length "voiceprint" for a clip of one person speaking.
public protocol SpeakerEmbeddingExtractor: AnyObject {
    var displayName: String { get }
    /// Cosine distance above which two voiceprints are treated as different people.
    var recommendedNewSpeakerDistance: Float { get }
    func embedding(for audio: AudioClip) async throws -> [Float]
}

public struct SpeakerRegistryConfiguration: Sendable, Equatable {
    /// Cosine distance to the nearest known voice above which a new speaker is created.
    public var newSpeakerDistance: Float = 0.6
    /// A new speaker is only created from a clip at least this long;
    /// shorter clips are assigned to the closest known voice instead.
    public var minimumNewSpeakerDuration: TimeInterval = 1.0
    public var maximumSpeakers: Int = 16
    /// Seconds of speech after which a speaker's voiceprint stops drifting much.
    public var maximumCentroidWeight: Double = 40

    public init(newSpeakerDistance: Float = 0.6) {
        self.newSpeakerDistance = newSpeakerDistance
    }
}

public struct SpeakerMatch: Sendable, Equatable {
    public var speaker: SpeakerID
    public var isNew: Bool
    /// Cosine distance to the matched voiceprint (0 for a newly created speaker).
    public var distance: Float
    /// False when the clip was only *assigned* to the nearest voice because it was
    /// too short (or the speaker limit was hit) to justify a new speaker.
    public var isConfident: Bool
}

public struct SpeakerSummary: Sendable, Equatable, Identifiable {
    public var id: SpeakerID
    public var utteranceCount: Int
    public var totalSpeech: TimeInterval
    public var medianPitchHz: Double?
}

/// Online speaker clustering: each detected voice keeps a running voiceprint
/// (centroid); every new utterance joins the nearest voice or founds a new one.
public final class SpeakerRegistry {
    public var configuration: SpeakerRegistryConfiguration

    private struct Entry {
        var id: SpeakerID
        var centroid: [Float]
        var weight: Double
        var utteranceCount: Int
        var totalSpeech: TimeInterval
        var pitches: [Double]
    }

    private var entries: [Entry] = []
    private var nextRawID = 1

    public init(configuration: SpeakerRegistryConfiguration = SpeakerRegistryConfiguration()) {
        self.configuration = configuration
    }

    public var count: Int { entries.count }

    public var summaries: [SpeakerSummary] {
        entries.map {
            SpeakerSummary(
                id: $0.id,
                utteranceCount: $0.utteranceCount,
                totalSpeech: $0.totalSpeech,
                medianPitchHz: VectorMath.median($0.pitches)
            )
        }
    }

    public func medianPitch(of speaker: SpeakerID) -> Double? {
        entries.first { $0.id == speaker }.flatMap { VectorMath.median($0.pitches) }
    }

    public func reset() {
        entries.removeAll()
        nextRawID = 1
    }

    /// Assigns an utterance's voiceprint to a speaker. Returns nil only for an
    /// unusable (zero / non-finite) embedding.
    public func identify(embedding: [Float], duration: TimeInterval, pitchHz: Double? = nil) -> SpeakerMatch? {
        guard embedding.allSatisfy({ $0.isFinite }), let vector = VectorMath.l2Normalized(embedding) else {
            return nil
        }

        var nearest: (index: Int, distance: Float)?
        for (index, entry) in entries.enumerated() where entry.centroid.count == vector.count {
            let distance = 1 - VectorMath.dot(vector, entry.centroid)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }

        if let nearest, nearest.distance < configuration.newSpeakerDistance {
            update(index: nearest.index, with: vector, duration: duration, pitchHz: pitchHz, adaptCentroid: true)
            return SpeakerMatch(speaker: entries[nearest.index].id, isNew: false, distance: nearest.distance, isConfident: true)
        }

        let mayCreate = entries.isEmpty
            || (duration >= configuration.minimumNewSpeakerDuration && entries.count < configuration.maximumSpeakers)
        if mayCreate {
            let id = SpeakerID(nextRawID)
            nextRawID += 1
            entries.append(Entry(
                id: id,
                centroid: vector,
                weight: max(duration, 0.1),
                utteranceCount: 1,
                totalSpeech: duration,
                pitches: pitchHz.map { [$0] } ?? []
            ))
            return SpeakerMatch(speaker: id, isNew: true, distance: 0, isConfident: true)
        }

        // Too short to trust as a brand-new voice: use the closest one, but don't
        // let an uncertain match pull that speaker's voiceprint around.
        guard let nearest else { return nil }
        update(index: nearest.index, with: vector, duration: duration, pitchHz: nil, adaptCentroid: false)
        return SpeakerMatch(speaker: entries[nearest.index].id, isNew: false, distance: nearest.distance, isConfident: false)
    }

    private func update(index: Int, with vector: [Float], duration: TimeInterval, pitchHz: Double?, adaptCentroid: Bool) {
        var entry = entries[index]
        entry.utteranceCount += 1
        entry.totalSpeech += duration
        if let pitchHz {
            entry.pitches.append(pitchHz)
            if entry.pitches.count > 30 { entry.pitches.removeFirst(entry.pitches.count - 30) }
        }
        if adaptCentroid {
            let added = max(duration, 0.1)
            let total = entry.weight + added
            var blended = [Float](repeating: 0, count: vector.count)
            for i in 0..<vector.count {
                blended[i] = Float((Double(entry.centroid[i]) * entry.weight + Double(vector[i]) * added) / total)
            }
            if let normalized = VectorMath.l2Normalized(blended) {
                entry.centroid = normalized
            }
            entry.weight = min(total, configuration.maximumCentroidWeight)
        }
        entries[index] = entry
    }
}
