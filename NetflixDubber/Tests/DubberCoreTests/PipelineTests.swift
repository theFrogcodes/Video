import XCTest
@testable import DubberCore

/// Voiceprint stub: separates voices by pitch so the test controls who is "speaking".
private final class PitchVoiceprint: SpeakerEmbeddingExtractor {
    let displayName = "test"
    let recommendedNewSpeakerDistance: Float = 0.6

    func embedding(for audio: AudioClip) async throws -> [Float] {
        let hz = PitchEstimator().summarize(audio.resampled(to: 16_000).samples).medianHz ?? 0
        return hz < 170 ? [1, 0.05, 0] : [0.05, 1, 0]
    }
}

private final class StubTranscriber: SpeechTranscriber {
    /// High voices "hallucinate" a stock phrase; long low lines answer slowly so a
    /// later line finishes first, which proves playback order is preserved.
    func transcribe(_ audio: AudioClip, context: TranscriptionContext) async throws -> String {
        let hz = PitchEstimator().summarize(audio.resampled(to: 16_000).samples).medianHz ?? 0
        if hz >= 170 { return "ご視聴ありがとうございました" }
        if audio.duration > 1.6 { try await Task.sleep(nanoseconds: 300_000_000) }
        return "低い声"
    }
}

private final class StubTranslator: DialogueTranslator {
    private let lock = NSLock()
    private(set) var requests: [TranslationRequest] = []

    private func record(_ request: TranslationRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    func translate(_ request: TranslationRequest) async throws -> Translation {
        record(request)
        return Translation(english: "Line \(request.japanese)", delivery: "calm")
    }
}

private final class StubSynthesizer: DubSpeechSynthesizer {
    func synthesize(_ text: String, voice: VoiceProfile, delivery: DeliveryStyle) async throws -> AudioClip {
        AudioClip(samples: [Float](repeating: 0.1, count: 2_400), sampleRate: 24_000)
    }
}

private final class FailingTranslator: DialogueTranslator {
    func translate(_ request: TranslationRequest) async throws -> Translation {
        throw DubberServiceError.authentication(service: "Claude", message: "invalid x-api-key")
    }
}

final class DubPipelineTests: XCTestCase {
    private let voices = [
        VoiceOption(id: "deep", name: "Deep", gender: .masculine),
        VoiceOption(id: "bright", name: "Bright", gender: .feminine),
    ]

    private func lineHasSpeaker(_ id: Int) -> ([PipelineEvent]) -> Bool {
        { events in
            events.contains { event in
                if case .line(let line) = event, line.id == id, line.speaker != nil { return true }
                return false
            }
        }
    }

    private func clips(in events: [PipelineEvent]) -> [DubClip] {
        events.compactMap { event -> DubClip? in
            if case .clip(let clip) = event { return clip }
            return nil
        }
    }

    /// Reads events (appending to `existing`) until `done` holds for the whole list.
    private func collect(
        _ pipeline: DubPipeline,
        after existing: [PipelineEvent] = [],
        timeout: TimeInterval = 10,
        until done: @escaping ([PipelineEvent]) -> Bool
    ) async -> [PipelineEvent] {
        if done(existing) { return existing }
        let collector = Task { () -> [PipelineEvent] in
            var events = existing
            for await event in pipeline.events {
                events.append(event)
                if done(events) { break }
            }
            return events
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        let events = await collector.value
        watchdog.cancel()
        return events
    }

    private func feed(_ samples: [Float], to pipeline: DubPipeline) async {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 640, samples.count)
            await pipeline.ingest(Array(samples[offset..<end]))
            offset = end
        }
    }

    func testDubsEachLineWithTheRightVoiceInOrder() async throws {
        let translator = StubTranslator()
        let pipeline = DubPipeline(
            embedder: PitchVoiceprint(),
            transcriber: StubTranscriber(),
            translator: translator,
            synthesizer: StubSynthesizer(),
            voiceCatalog: voices
        )

        // Speaker A (low), then B (high, a recogniser hallucination), then A again.
        // Each line is fed once the previous speaker is known, so IDs are deterministic.
        await feed(Synth.noise(duration: 1) + Synth.voiced(f0: 110, duration: 1.5) + Synth.noise(duration: 1), to: pipeline)
        var events = await collect(pipeline, until: lineHasSpeaker(0))
        await feed(Synth.voiced(f0: 250, duration: 1.5) + Synth.noise(duration: 1), to: pipeline)
        events = await collect(pipeline, after: events, until: lineHasSpeaker(1))
        await feed(Synth.voiced(f0: 115, duration: 1.25) + Synth.noise(duration: 1), to: pipeline)
        events = await collect(pipeline, after: events) { self.clips(in: $0).count >= 2 }

        let created = events.compactMap { event -> VoiceProfile? in
            if case .speakerCreated(let profile) = event { return profile }
            return nil
        }
        XCTAssertEqual(created.map(\.speaker), [SpeakerID(1), SpeakerID(2)], "A and B each get a new voice; A's return reuses it")
        XCTAssertEqual(created.map(\.voice.id), ["deep", "bright"])

        let dubbed = clips(in: events)
        XCTAssertEqual(dubbed.map(\.lineID), [0, 2], "the hallucinated middle line is skipped and order is preserved")
        XCTAssertEqual(dubbed.map(\.speaker), [SpeakerID(1), SpeakerID(1)])
        XCTAssertEqual(dubbed.first?.text, "Line 低い声")
        XCTAssertEqual(dubbed.first?.audio.sampleRate, 24_000)

        let skipped = events.contains { event in
            if case .line(let line) = event, line.id == 1, case .skipped = line.status { return true }
            return false
        }
        XCTAssertTrue(skipped)

        let activity = events.filter { if case .speechActivity = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(activity.count, 6)

        XCTAssertEqual(translator.requests.count, 2)
        XCTAssertTrue(translator.requests.allSatisfy { $0.speakerName == "Speaker 1" })
        XCTAssertTrue(translator.requests.contains { $0.history.first?.japanese == "低い声" })
        await pipeline.finish()
    }

    func testFatalServiceErrorsAreReported() async {
        let pipeline = DubPipeline(
            embedder: PitchVoiceprint(),
            transcriber: StubTranscriber(),
            translator: FailingTranslator(),
            synthesizer: StubSynthesizer(),
            voiceCatalog: voices
        )
        await feed(Synth.noise(duration: 0.5) + Synth.voiced(f0: 120, duration: 1.2) + Synth.noise(duration: 1), to: pipeline)
        let events = await collect(pipeline) { events in
            events.contains { if case .problem = $0 { return true }; return false }
        }
        let problem = events.compactMap { event -> PipelineProblem? in
            if case .problem(let problem) = event { return problem }
            return nil
        }.first
        XCTAssertEqual(problem?.stage, "Translation")
        XCTAssertEqual(problem?.isFatal, true)
        await pipeline.finish()
    }

    func testMutedSpeakerIsNotDubbed() async {
        let pipeline = DubPipeline(
            embedder: PitchVoiceprint(),
            transcriber: StubTranscriber(),
            translator: StubTranslator(),
            synthesizer: StubSynthesizer(),
            voiceCatalog: voices
        )
        await feed(Synth.noise(duration: 0.5) + Synth.voiced(f0: 120, duration: 1.2) + Synth.noise(duration: 1), to: pipeline)
        _ = await collect(pipeline) { events in
            events.contains { if case .clip = $0 { return true }; return false }
        }
        await pipeline.setMuted(true, for: SpeakerID(1))
        await feed(Synth.voiced(f0: 118, duration: 1.2) + Synth.noise(duration: 1), to: pipeline)
        let events = await collect(pipeline) { events in
            events.contains { event in
                if case .line(let line) = event, line.id == 1, line.status.isFinished { return true }
                return false
            }
        }
        XCTAssertFalse(clips(in: events).map(\.lineID).contains(1))
        await pipeline.finish()
    }
}
