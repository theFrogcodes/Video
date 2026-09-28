import XCTest
@testable import DubberCore

final class ResamplerTests: XCTestCase {
    func testDownsamplePreservesToneAndLength() {
        let input = Synth.sine(frequency: 1_000, duration: 1, sampleRate: 48_000, amplitude: 0.8)
        let output = StreamingResampler.resample(input, from: 48_000, to: 16_000)

        XCTAssertEqual(output.count, 16_000)
        let body = Array(output[1_000..<15_000])   // skip filter edges
        XCTAssertEqual(estimatedFrequency(body, sampleRate: 16_000), 1_000, accuracy: 5)
        XCTAssertEqual(rms(body), 0.8 / Float(2).squareRoot(), accuracy: 0.02)
    }

    func testNonIntegerRatioAndUpsampling() {
        let input = Synth.sine(frequency: 440, duration: 1, sampleRate: 44_100, amplitude: 0.5)
        let down = StreamingResampler.resample(input, from: 44_100, to: 16_000)
        XCTAssertEqual(down.count, 16_000)
        XCTAssertEqual(estimatedFrequency(Array(down[1_000..<15_000]), sampleRate: 16_000), 440, accuracy: 4)

        let tts = Synth.sine(frequency: 300, duration: 0.5, sampleRate: 24_000, amplitude: 0.5)
        let up = StreamingResampler.resample(tts, from: 24_000, to: 48_000)
        XCTAssertEqual(up.count, 24_000)
        XCTAssertEqual(rms(Array(up[2_000..<22_000])), 0.5 / Float(2).squareRoot(), accuracy: 0.02)
    }

    func testRejectsContentAboveOutputNyquist() {
        // A 10 kHz tone can't be represented at 16 kHz; it must be filtered, not aliased to 6 kHz.
        let input = Synth.sine(frequency: 10_000, duration: 0.5, sampleRate: 48_000, amplitude: 0.8)
        let output = StreamingResampler.resample(input, from: 48_000, to: 16_000)
        XCTAssertLessThan(rms(Array(output[500..<7_500])), 0.01)
    }

    func testStreamingMatchesOneShot() {
        let input = Synth.voiced(f0: 150, duration: 0.6, sampleRate: 48_000)
        let oneShot = StreamingResampler.resample(input, from: 48_000, to: 16_000)

        let streaming = StreamingResampler(inputRate: 48_000, outputRate: 16_000)
        var chunked: [Float] = []
        var offset = 0
        let sizes = [512, 480, 1_000, 17, 4_096]
        var index = 0
        while offset < input.count {
            let size = min(sizes[index % sizes.count], input.count - offset)
            chunked += streaming.process(Array(input[offset..<(offset + size)]))
            offset += size
            index += 1
        }
        chunked += streaming.flush()

        let compared = min(oneShot.count, chunked.count)
        XCTAssertGreaterThan(compared, 9_000)
        for i in 0..<compared {
            XCTAssertEqual(oneShot[i], chunked[i], accuracy: 1e-5, "sample \(i)")
        }
    }
}

final class FFTAndFeatureTests: XCTestCase {
    func testFFTPeakBin() {
        let fft = FFT(size: 512)
        let tone = Synth.sine(frequency: 16 * 16_000 / 512, duration: 512.0 / 16_000, sampleRate: 16_000)
        let power = fft.powerSpectrum(tone)
        XCTAssertEqual(power.count, 257)
        XCTAssertEqual(power.indices.max { power[$0] < power[$1] }, 16)
    }

    func testMFCCShape() {
        let extractor = MFCCExtractor()
        let frames = extractor.extract(Synth.voiced(f0: 140, duration: 1))
        XCTAssertEqual(frames.coefficients.count, 98)   // (16000 - 400) / 160 + 1
        XCTAssertEqual(frames.coefficients.first?.count, 20)
        XCTAssertTrue(frames.coefficients.allSatisfy { $0.allSatisfy(\.isFinite) })
    }

    func testPitchOfLowAndHighVoices() {
        let estimator = PitchEstimator()
        let low = estimator.summarize(Synth.voiced(f0: 115, duration: 1))
        let high = estimator.summarize(Synth.voiced(f0: 245, duration: 1))
        XCTAssertEqual(try XCTUnwrap(low.medianHz), 115, accuracy: 115 * 0.03)
        XCTAssertEqual(try XCTUnwrap(high.medianHz), 245, accuracy: 245 * 0.03)
        XCTAssertGreaterThan(low.voicedFraction, 0.5)
    }

    func testPitchIsNilForSilence() {
        let summary = PitchEstimator().summarize(Synth.noise(duration: 0.5, level: 0))
        XCTAssertNil(summary.medianHz)
    }

    func testVocalRegister() {
        XCTAssertEqual(VocalRegister(pitchHz: 100), .low)
        XCTAssertEqual(VocalRegister(pitchHz: 160), .mid)
        XCTAssertEqual(VocalRegister(pitchHz: 230), .high)
        XCTAssertEqual(VocalRegister(pitchHz: 340), .veryHigh)
        XCTAssertEqual(VocalRegister(pitchHz: nil), .mid)
    }
}
