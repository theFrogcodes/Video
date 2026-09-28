import XCTest
@testable import DubberCore

final class SpeakerRegistryTests: XCTestCase {
    /// Deterministic unit-ish vectors scattered around a centre.
    private func sample(around centre: [Float], seed: UInt32, noise: Float = 0.25) -> [Float] {
        var state = seed
        return centre.map { value in
            state = state &* 1_664_525 &+ 1_013_904_223
            return value + (Float(state) / Float(UInt32.max) * 2 - 1) * noise
        }
    }

    private func centre(_ seed: UInt32, dimension: Int = 64) -> [Float] {
        sample(around: [Float](repeating: 0, count: dimension), seed: seed, noise: 1)
    }

    func testClustersVoicesAndCreatesNewSpeakers() {
        let registry = SpeakerRegistry()
        let alice = centre(1), bob = centre(99)
        XCTAssertGreaterThan(VectorMath.cosineDistance(alice, bob), 0.6)

        let first = registry.identify(embedding: sample(around: alice, seed: 10), duration: 2)
        XCTAssertEqual(first, SpeakerMatch(speaker: SpeakerID(1), isNew: true, distance: 0, isConfident: true))

        let second = registry.identify(embedding: sample(around: bob, seed: 11), duration: 2)
        XCTAssertEqual(second?.speaker, SpeakerID(2))
        XCTAssertEqual(second?.isNew, true)

        for seed in UInt32(20)..<UInt32(30) {
            XCTAssertEqual(registry.identify(embedding: sample(around: alice, seed: seed), duration: 1.5)?.speaker, SpeakerID(1))
            XCTAssertEqual(registry.identify(embedding: sample(around: bob, seed: seed + 100), duration: 1.5)?.speaker, SpeakerID(2))
        }
        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.summaries.first?.utteranceCount, 11)
    }

    func testShortClipsDoNotFoundNewSpeakers() {
        let registry = SpeakerRegistry()
        _ = registry.identify(embedding: centre(1), duration: 2)
        let match = registry.identify(embedding: centre(50), duration: 0.5)
        XCTAssertEqual(match?.speaker, SpeakerID(1))
        XCTAssertEqual(match?.isNew, false)
        XCTAssertEqual(match?.isConfident, false)
        XCTAssertEqual(registry.count, 1)
    }

    func testFirstSpeakerIsAlwaysCreated() {
        let registry = SpeakerRegistry()
        XCTAssertEqual(registry.identify(embedding: centre(3), duration: 0.3)?.isNew, true)
    }

    func testRejectsDegenerateEmbeddings() {
        let registry = SpeakerRegistry()
        XCTAssertNil(registry.identify(embedding: [], duration: 2))
        XCTAssertNil(registry.identify(embedding: [0, 0, 0], duration: 2))
        XCTAssertNil(registry.identify(embedding: [1, .nan, 0], duration: 2))
    }

    func testThresholdControlsSplitting() {
        let registry = SpeakerRegistry(configuration: SpeakerRegistryConfiguration(newSpeakerDistance: 1.9))
        _ = registry.identify(embedding: centre(1), duration: 2)
        _ = registry.identify(embedding: centre(2), duration: 2)
        XCTAssertEqual(registry.count, 1, "a very permissive threshold merges everyone")
    }

    func testMaximumSpeakers() {
        var configuration = SpeakerRegistryConfiguration()
        configuration.maximumSpeakers = 3
        let registry = SpeakerRegistry(configuration: configuration)
        for seed in UInt32(1)...UInt32(6) {
            _ = registry.identify(embedding: centre(seed * 37), duration: 2)
        }
        XCTAssertEqual(registry.count, 3)
    }

    func testSpectralEmbedderSeparatesDifferentVoices() {
        let embedder = SpectralSpeakerEmbedder()
        let low1 = embedder.computeEmbedding(AudioClip(samples: Synth.voiced(f0: 105, duration: 1.2), sampleRate: 16_000))
        let high = embedder.computeEmbedding(AudioClip(samples: Synth.voiced(f0: 260, duration: 1.2), sampleRate: 16_000))
        let low2 = embedder.computeEmbedding(AudioClip(samples: Synth.voiced(f0: 108, duration: 1.4, syllableRate: 3.5), sampleRate: 16_000))
        XCTAssertEqual(low1.count, 40)
        XCTAssertLessThan(VectorMath.cosineDistance(low1, low2), VectorMath.cosineDistance(low1, high))
    }
}

final class VoiceDesignerTests: XCTestCase {
    private let catalog = [
        VoiceOption(id: "m1", name: "Male 1", gender: .masculine, quality: 2),
        VoiceOption(id: "m2", name: "Male 2", gender: .masculine, quality: 1),
        VoiceOption(id: "f1", name: "Female 1", gender: .feminine, quality: 2),
        VoiceOption(id: "f2", name: "Female 2", gender: .feminine, quality: 1),
        VoiceOption(id: "n1", name: "Neutral", gender: .neutral, quality: 1),
    ]

    func testMatchesVoiceToPitch() {
        let designer = VoiceDesigner(catalog: catalog)
        XCTAssertEqual(designer.design(for: SpeakerID(1), pitchHz: 105).voice.gender, .masculine)
        XCTAssertEqual(designer.design(for: SpeakerID(2), pitchHz: 250).voice.gender, .feminine)
        XCTAssertEqual(designer.design(for: SpeakerID(3), pitchHz: 330).register, .veryHigh)
    }

    func testEachNewSpeakerGetsAFreshVoiceFirst() {
        let designer = VoiceDesigner(catalog: catalog)
        let deep = (1...3).map { designer.design(for: SpeakerID($0), pitchHz: 110) }
        // Two masculine voices, then the unused neutral one before any reuse.
        XCTAssertEqual(deep.map(\.voice.id), ["m1", "m2", "n1"])
        XCTAssertEqual(Set(deep.map(\.voice.id)).count, 3)
    }

    func testReusedVoicesAreVaried() {
        let designer = VoiceDesigner(catalog: [VoiceOption(id: "only", name: "Only", gender: .feminine)])
        let a = designer.design(for: SpeakerID(1), pitchHz: 240)
        let b = designer.design(for: SpeakerID(2), pitchHz: 240)
        XCTAssertEqual(a.voice, b.voice)
        XCTAssertNotEqual(a.pitchMultiplier, b.pitchMultiplier)
        XCTAssertNotEqual(a.persona, b.persona)
    }

    func testReassignUpdatesVoice() {
        let designer = VoiceDesigner(catalog: catalog)
        let profile = designer.design(for: SpeakerID(1), pitchHz: 120)
        let updated = designer.reassign(profile, to: catalog[2])
        XCTAssertEqual(updated.voice.id, "f1")
        XCTAssertEqual(updated.speaker, profile.speaker)
    }

    func testDeliveryStyleParsing() {
        XCTAssertGreaterThan(DeliveryStyle.parse("Angry, shouting").rateScale, 1)
        XCTAssertLessThan(DeliveryStyle.parse("whispering, nervous").volume, 1)
        XCTAssertEqual(DeliveryStyle.parse(nil), .neutral)
        XCTAssertEqual(DeliveryStyle.parse("calm").rateScale, 1)
    }
}

final class PlaybackLogicTests: XCTestCase {
    func testOrderedReleaseQueue() {
        var queue = OrderedReleaseQueue<String>()
        XCTAssertEqual(queue.complete(1, with: "b"), [])
        XCTAssertEqual(queue.complete(2, with: nil), [])
        XCTAssertEqual(queue.complete(0, with: "a"), ["a", "b"])
        XCTAssertEqual(queue.nextSequence, 3)
        XCTAssertEqual(queue.complete(4, with: "e"), [])
        XCTAssertEqual(queue.skip(upTo: 4), ["e"])
        XCTAssertEqual(queue.complete(3, with: "late"), [], "late results are dropped")
        XCTAssertEqual(queue.waitingCount, 0)
    }

    func testPacerSpeedsUpThenDrops() {
        let pacer = PlaybackPacer()
        let onTime = pacer.decide(sourceEnd: 10, now: 11.5, queuedAhead: 0)
        XCTAssertTrue(onTime.shouldPlay)
        XCTAssertEqual(onTime.rate, 1)

        let behind = pacer.decide(sourceEnd: 10, now: 13, queuedAhead: 2)
        XCTAssertTrue(behind.shouldPlay)
        XCTAssertGreaterThan(behind.rate, 1)
        XCTAssertLessThanOrEqual(behind.rate, pacer.configuration.maximumRate)

        let stale = pacer.decide(sourceEnd: 10, now: 16, queuedAhead: 2)
        XCTAssertFalse(stale.shouldPlay)
    }

    func testDuckingPolicy() {
        let policy = DuckingPolicy(duckedGain: 0.2)
        XCTAssertEqual(policy.targetGain(originalSpeechActive: false, secondsSinceSpeechEnded: nil, dubPlaying: false), 1)
        XCTAssertEqual(policy.targetGain(originalSpeechActive: true, secondsSinceSpeechEnded: nil, dubPlaying: false), 0.2)
        XCTAssertEqual(policy.targetGain(originalSpeechActive: false, secondsSinceSpeechEnded: 0.1, dubPlaying: false), 0.2)
        XCTAssertEqual(policy.targetGain(originalSpeechActive: false, secondsSinceSpeechEnded: 2, dubPlaying: true), 0.2)

        let lateDuck = DuckingPolicy(duckedGain: 0.2, duckDuringOriginalSpeech: false)
        XCTAssertEqual(lateDuck.targetGain(originalSpeechActive: true, secondsSinceSpeechEnded: nil, dubPlaying: false), 1)
    }
}
