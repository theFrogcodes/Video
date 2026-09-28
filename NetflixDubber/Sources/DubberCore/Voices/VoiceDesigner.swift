import Foundation

/// Creates a distinct English voice for every newly detected speaker.
///
/// The original speaker's pitch picks a matching voice family (deep male,
/// female, child-like…). Voices are spread so each speaker gets an unused voice
/// while any remain; once a voice has to be reused, pitch and persona are
/// varied so two characters sharing a base voice still sound different.
public final class VoiceDesigner {
    public private(set) var catalog: [VoiceOption]
    private var usage: [String: Int] = [:]

    /// Multipliers applied on successive reuses of the same base voice.
    private static let reuseVariation: [Float] = [1.0, 1.1, 0.91, 1.18, 0.85, 1.05, 0.95]
    private static let reuseFlavours = ["", "slightly brighter", "slightly huskier", "lighter and quicker", "lower and calmer", "softer", "sharper"]

    public init(catalog: [VoiceOption]) {
        self.catalog = catalog
    }

    public func replaceCatalog(_ newCatalog: [VoiceOption]) {
        catalog = newCatalog
        usage.removeAll()
    }

    public func reset() {
        usage.removeAll()
    }

    public func design(for speaker: SpeakerID, pitchHz: Double?) -> VoiceProfile {
        let register = VocalRegister(pitchHz: pitchHz)
        let preferred = Self.genderPreference(register: register, pitchHz: pitchHz)
        let voice = pickVoice(preferring: preferred) ?? VoiceOption(id: "default", name: "System default", gender: .neutral)
        let reuse = usage[voice.id, default: 0]
        usage[voice.id] = reuse + 1

        let variation = Self.reuseVariation[reuse % Self.reuseVariation.count]
        let pitch = min(1.5, max(0.75, Self.basePitch(for: register) * variation))
        var persona = Self.persona(register: register, gender: voice.gender)
        let flavour = Self.reuseFlavours[reuse % Self.reuseFlavours.count]
        if !flavour.isEmpty {
            persona += " Make this character sound \(flavour) than the voice's default so they're distinct from others."
        }

        return VoiceProfile(
            speaker: speaker,
            displayName: speaker.description,
            voice: voice,
            pitchMultiplier: pitch,
            register: register,
            persona: persona
        )
    }

    /// Manually swaps a speaker onto a different base voice.
    public func reassign(_ profile: VoiceProfile, to voice: VoiceOption) -> VoiceProfile {
        if let count = usage[profile.voice.id], count > 0 { usage[profile.voice.id] = count - 1 }
        usage[voice.id, default: 0] += 1
        var updated = profile
        updated.voice = voice
        updated.pitchMultiplier = Self.basePitch(for: profile.register)
        updated.persona = Self.persona(register: profile.register, gender: voice.gender)
        return updated
    }

    // MARK: - Selection

    private func pickVoice(preferring genders: [VoiceGender]) -> VoiceOption? {
        // Cost = how far down the gender preference list the voice is, plus a
        // penalty per previous use. An unused next-best-gender voice therefore
        // beats reusing the best-gender one, but a voice of an unlisted gender
        // (e.g. feminine for a deep voice) is only used if nothing else exists.
        func cost(_ voice: VoiceOption) -> Double {
            let genderRank: Double = genders.firstIndex(of: voice.gender).map { Double($0) } ?? 100
            return genderRank + 1.2 * Double(usage[voice.id, default: 0])
        }
        let ranked = catalog.enumerated().min { lhs, rhs in
            let lc = cost(lhs.element), rc = cost(rhs.element)
            if lc != rc { return lc < rc }
            if lhs.element.quality != rhs.element.quality { return lhs.element.quality > rhs.element.quality }
            return lhs.offset < rhs.offset
        }
        return ranked?.element
    }

    static func genderPreference(register: VocalRegister, pitchHz: Double?) -> [VoiceGender] {
        switch register {
        case .low:
            return [.masculine, .neutral]
        case .mid:
            if let hz = pitchHz, hz >= 172 { return [.feminine, .neutral, .masculine] }
            return [.masculine, .neutral, .feminine]
        case .high, .veryHigh:
            return [.feminine, .neutral]
        }
    }

    static func basePitch(for register: VocalRegister) -> Float {
        switch register {
        case .low: return 0.9
        case .mid: return 1.0
        case .high: return 1.06
        case .veryHigh: return 1.2
        }
    }

    static func persona(register: VocalRegister, gender: VoiceGender) -> String {
        switch (register, gender) {
        case (.low, _):
            return "A deep, mature adult voice with weight and authority."
        case (.mid, .masculine):
            return "A natural adult male voice, clear and grounded."
        case (.mid, .feminine):
            return "A natural adult female voice, warm and clear."
        case (.mid, .neutral):
            return "A natural adult voice, clear and even."
        case (.high, _):
            return "A bright, expressive young-adult voice."
        case (.veryHigh, _):
            return "A high, youthful, energetic voice, like a teenage or child character."
        }
    }
}
