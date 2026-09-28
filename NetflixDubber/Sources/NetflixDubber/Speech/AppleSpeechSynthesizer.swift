import AVFoundation
import DubberCore
import Foundation

/// Free, on-device English voices (System Settings › Accessibility › Spoken
/// Content › System Voice › Manage Voices… to download higher-quality ones).
final class AppleSpeechSynthesizer: DubSpeechSynthesizer {
    enum SynthesisError: LocalizedError {
        case timedOut, noAudio
        var errorDescription: String? {
            switch self {
            case .timedOut: return "The system voice took too long to speak."
            case .noAudio: return "The system voice produced no audio."
            }
        }
    }

    /// English voices, best first. Novelty, personal and robotic "Eloquence" voices are excluded.
    static func englishVoices() -> [VoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && !voice.identifier.lowercased().contains("eloquence")
        }
        let options = voices.map { voice -> VoiceOption in
            let gender: VoiceGender
            switch voice.gender {
            case .male: gender = .masculine
            case .female: gender = .feminine
            default: gender = .neutral
            }
            var quality: Int
            switch voice.quality {
            case .premium: quality = 30
            case .enhanced: quality = 20
            default: quality = 10
            }
            if voice.language == "en-US" || voice.language == "en-GB" { quality += 2 }
            let region = voice.language.split(separator: "-").last.map(String.init) ?? voice.language
            return VoiceOption(id: voice.identifier, name: "\(voice.name) (\(region))", gender: gender, quality: quality)
        }
        return options.sorted { lhs, rhs in
            lhs.quality != rhs.quality ? lhs.quality > rhs.quality : lhs.name < rhs.name
        }
    }

    func synthesize(_ text: String, voice: VoiceProfile, delivery: DeliveryStyle) async throws -> AudioClip {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.voice.id) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.pitchMultiplier = max(0.5, min(2.0, voice.pitchMultiplier * delivery.pitchScale))
        let rate = AVSpeechUtteranceDefaultSpeechRate * 1.06 * delivery.rateScale
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
        utterance.volume = max(0, min(1, delivery.volume))
        utterance.prefersAssistiveTechnologySettings = false

        let collector = await MainActor.run { () -> SpeechCollector in
            let collector = SpeechCollector()
            collector.begin(utterance)
            return collector
        }
        return try await collector.result()
    }
}

/// Collects the PCM buffers AVSpeechSynthesizer renders for one utterance.
private final class SpeechCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 22_050
    private var finished = false
    private var continuation: CheckedContinuation<AudioClip, Error>?
    private var outcome: Result<AudioClip, Error>?

    @MainActor
    func begin(_ utterance: AVSpeechUtterance) {
        synthesizer.delegate = self
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.complete()   // a zero-length buffer marks the end of the utterance
                return
            }
            self.append(pcm)
        }
        // Safety net in case the end-of-speech signal never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.complete(timedOut: true)
        }
    }

    func result() async throws -> AudioClip {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Give any trailing buffer callbacks a moment before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.complete()
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if let floats = buffer.floatChannelData {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += floats[channel][frame * buffer.stride] }
                mono[frame] = sum / Float(max(channels, 1))
            }
        } else if let ints = buffer.int16ChannelData {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(ints[channel][frame * buffer.stride]) / 32768 }
                mono[frame] = sum / Float(max(channels, 1))
            }
        } else if let ints = buffer.int32ChannelData {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(ints[channel][frame * buffer.stride]) / 2_147_483_648 }
                mono[frame] = sum / Float(max(channels, 1))
            }
        }
        lock.lock()
        sampleRate = buffer.format.sampleRate
        samples.append(contentsOf: mono)
        lock.unlock()
    }

    private func complete(timedOut: Bool = false) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result: Result<AudioClip, Error>
        if samples.isEmpty {
            result = .failure(timedOut ? AppleSpeechSynthesizer.SynthesisError.timedOut : AppleSpeechSynthesizer.SynthesisError.noAudio)
        } else {
            result = .success(AudioClip(samples: samples, sampleRate: sampleRate))
        }
        let waiting = continuation
        continuation = nil
        outcome = result
        lock.unlock()
        waiting?.resume(with: result)
        DispatchQueue.main.async { [synthesizer] in
            synthesizer.delegate = nil
        }
    }
}
