import Foundation

public struct VADConfiguration: Sendable, Equatable {
    public var frameDuration: TimeInterval = 0.02
    /// Energy above the adaptive noise floor needed to *start* a speech run.
    public var startThresholdDB: Float = 9
    /// Lower threshold to *stay* in speech (hysteresis keeps words from being chopped).
    public var continueThresholdDB: Float = 5
    /// Frames quieter than this are never speech.
    public var absoluteFloorDB: Float = -55
    /// Window over which the background level (music, room tone) is estimated.
    public var noiseWindow: TimeInterval = 4
    /// Percentile of recent frame energies taken as the background level.
    public var noisePercentile: Float = 0.2

    public init() {}
}

public struct VADDecision: Sendable, Equatable {
    public var isSpeech: Bool
    public var energyDB: Float
    public var noiseFloorDB: Float
}

/// Energy-based voice activity detector with an adaptive noise floor.
///
/// TV audio has a music/effects bed under the dialogue, so the floor tracks a
/// low percentile of the last few seconds rather than assuming silence between
/// lines. A pre-emphasis filter favours the 1–4 kHz region where speech energy
/// sits, which de-emphasises bass-heavy score and rumble.
public final class VoiceActivityDetector {
    public let configuration: VADConfiguration
    public let frameLength: Int
    private var history: [Float] = []
    private let historyCapacity: Int
    private var previousSample: Float = 0
    public private(set) var noiseFloorDB: Float

    public init(sampleRate: Double, configuration: VADConfiguration = VADConfiguration()) {
        self.configuration = configuration
        frameLength = max(1, Int(sampleRate * configuration.frameDuration))
        historyCapacity = max(10, Int(configuration.noiseWindow / configuration.frameDuration))
        noiseFloorDB = configuration.absoluteFloorDB
    }

    public func reset() {
        history.removeAll()
        previousSample = 0
        noiseFloorDB = configuration.absoluteFloorDB
    }

    /// Classifies one frame of `frameLength` samples.
    public func classify(_ frame: ArraySlice<Float>, currentlySpeaking: Bool) -> VADDecision {
        var power: Float = 0
        var previous = previousSample
        for sample in frame {
            let emphasized = sample - 0.95 * previous
            power += emphasized * emphasized
            previous = sample
        }
        previousSample = previous
        let energyDB = VectorMath.decibels(power: power / Float(max(frame.count, 1)))

        history.append(energyDB)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        // Until a few frames exist, fall back to the absolute floor.
        if history.count >= 10, let floor = VectorMath.percentile(history, configuration.noisePercentile) {
            noiseFloorDB = max(floor, configuration.absoluteFloorDB - 20)
        }

        let margin = currentlySpeaking ? configuration.continueThresholdDB : configuration.startThresholdDB
        let threshold = max(noiseFloorDB + margin, configuration.absoluteFloorDB)
        return VADDecision(isSpeech: energyDB > threshold, energyDB: energyDB, noiseFloorDB: noiseFloorDB)
    }
}
