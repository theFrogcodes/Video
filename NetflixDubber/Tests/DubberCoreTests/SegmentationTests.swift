import XCTest
@testable import DubberCore

final class SegmentationTests: XCTestCase {
    private func run(_ samples: [Float], chunk: Int = 800, configuration: SegmenterConfiguration = SegmenterConfiguration()) -> [SegmenterEvent] {
        let segmenter = UtteranceSegmenter(configuration: configuration)
        var events: [SegmenterEvent] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            events += segmenter.append(Array(samples[offset..<end]))
            offset = end
        }
        events += segmenter.flush()
        return events
    }

    private func utterances(_ events: [SegmenterEvent]) -> [Utterance] {
        events.compactMap { event in
            if case .utterance(let utterance) = event { return utterance }
            return nil
        }
    }

    func testFindsTwoLinesSeparatedBySilence() {
        let audio = Synth.noise(duration: 1)
            + Synth.voiced(f0: 120, duration: 1.5)
            + Synth.noise(duration: 1)
            + Synth.voiced(f0: 230, duration: 1.0)
            + Synth.noise(duration: 1)
        let events = run(audio)
        let lines = utterances(events)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.id), [0, 1])
        XCTAssertEqual(lines[0].startTime, 1.0, accuracy: 0.3)
        XCTAssertEqual(lines[0].endTime, 2.5, accuracy: 0.3)
        XCTAssertEqual(lines[1].startTime, 3.5, accuracy: 0.3)
        XCTAssertEqual(lines[0].audio.sampleRate, 16_000)
        XCTAssertEqual(lines[0].audio.duration, lines[0].duration, accuracy: 0.001)

        let starts = events.filter { if case .speechStarted = $0 { return true }; return false }
        let ends = events.filter { if case .speechEnded = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(ends.count, 2)
    }

    func testIgnoresSilenceAndClicks() {
        var audio = Synth.noise(duration: 2)
        // A 30 ms click is shorter than the onset requirement.
        let click = Synth.voiced(f0: 200, duration: 0.03, amplitude: 0.8, syllableRate: 0.5)
        audio.replaceSubrange(16_000..<(16_000 + click.count), with: click)
        XCTAssertTrue(utterances(run(audio)).isEmpty)
    }

    func testSplitsLongMonologues() {
        let audio = Synth.noise(duration: 0.5) + Synth.voiced(f0: 150, duration: 14) + Synth.noise(duration: 1)
        let lines = utterances(run(audio))
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        for line in lines {
            XCTAssertLessThanOrEqual(line.duration, SegmenterConfiguration().maximumUtterance + 0.05)
        }
        // Consecutive pieces are contiguous.
        for (previous, next) in zip(lines, lines.dropFirst()) {
            XCTAssertEqual(previous.endTime, next.startTime, accuracy: 0.001)
        }
        XCTAssertEqual(lines.map(\.id), Array(0..<lines.count))
    }

    func testClockTracksInput() {
        let segmenter = UtteranceSegmenter()
        _ = segmenter.append([Float](repeating: 0, count: 16_000 + 100))
        XCTAssertEqual(segmenter.currentTime, 1.00625, accuracy: 1e-9)
    }
}

final class TranscriptFilterTests: XCTestCase {
    func testKeepsDialogue() {
        XCTAssertEqual(TranscriptFilter.clean("  おい、待てよ！ "), "おい、待てよ！")
    }

    func testDropsRecognizerHallucinations() {
        XCTAssertNil(TranscriptFilter.clean("ご視聴ありがとうございました。"))
        XCTAssertNil(TranscriptFilter.clean("チャンネル登録よろしくお願いします！"))
        XCTAssertNil(TranscriptFilter.clean("Thank you for watching!"))
        XCTAssertNil(TranscriptFilter.clean("字幕作成：ABC"))
    }

    func testRemovesAnnotationsAndMusic() {
        XCTAssertNil(TranscriptFilter.clean("♪〜♪"))
        XCTAssertNil(TranscriptFilter.clean("（笑）"))
        XCTAssertEqual(TranscriptFilter.clean("[音楽] 行くぞ"), "行くぞ")
        XCTAssertEqual(TranscriptFilter.clean("♪ラララ♪ 本当に？"), "本当に？")
    }

    func testCollapsesStuckRepetition() {
        XCTAssertEqual(TranscriptFilter.clean("あああああああああああ"), "あああ")
    }
}
