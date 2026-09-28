import Foundation

/// How a line should be performed, derived from the translator's short
/// delivery note ("angry, shouting", "whispering"…). Synthesizers without an
/// instruction prompt (Apple voices) use the numeric scales.
public struct DeliveryStyle: Sendable, Equatable {
    public var note: String
    public var rateScale: Float
    public var pitchScale: Float
    public var volume: Float

    public init(note: String, rateScale: Float = 1, pitchScale: Float = 1, volume: Float = 1) {
        self.note = note
        self.rateScale = rateScale
        self.pitchScale = pitchScale
        self.volume = volume
    }

    public static let neutral = DeliveryStyle(note: "")

    private static let intense = ["shout", "yell", "scream", "angry", "furious", "rage", "panic", "urgent", "excited", "frantic", "desperate"]
    private static let quiet = ["whisper", "quiet", "soft", "murmur", "sad", "tired", "weak", "hesitant", "gentle", "tearful", "somber"]
    private static let bright = ["happy", "cheerful", "laugh", "playful", "teasing", "joyful", "delighted"]

    public static func parse(_ note: String?) -> DeliveryStyle {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .neutral }
        let lower = note.lowercased()
        if intense.contains(where: { lower.contains($0) }) {
            return DeliveryStyle(note: note, rateScale: 1.08, pitchScale: 1.05, volume: 1)
        }
        if quiet.contains(where: { lower.contains($0) }) {
            return DeliveryStyle(note: note, rateScale: 0.93, pitchScale: 0.97, volume: 0.75)
        }
        if bright.contains(where: { lower.contains($0) }) {
            return DeliveryStyle(note: note, rateScale: 1.04, pitchScale: 1.04, volume: 1)
        }
        return DeliveryStyle(note: note)
    }
}
