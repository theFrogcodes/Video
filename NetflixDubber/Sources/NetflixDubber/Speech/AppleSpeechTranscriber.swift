import AVFoundation
import DubberCore
import Foundation
import Speech

/// On-device Japanese speech recognition (no audio leaves the Mac).
/// Less accurate than the cloud model on noisy TV audio, but free and private.
final class AppleSpeechTranscriber: SpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case unavailable
        case notAuthorized
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Japanese speech recognition isn't available on this Mac. Add Japanese in System Settings › Keyboard › Dictation, or switch to OpenAI recognition."
            case .notAuthorized:
                return "Speech recognition permission was denied. Allow it in System Settings › Privacy & Security › Speech Recognition."
            case .failed(let message):
                return "Speech recognition failed: \(message)"
            }
        }
    }

    private let recognizer: SFSpeechRecognizer
    /// Recognition requests run one at a time; parallel on-device requests fail intermittently.
    private let gate = AsyncGate(limit: 1)

    init() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }
        self.recognizer = recognizer
    }

    static func requestAuthorization() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    func transcribe(_ audio: AudioClip, context: TranscriptionContext) async throws -> String {
        try await gate.run { try await self.recognize(audio, context: context) }
    }

    private func recognize(_ audio: AudioClip, context: TranscriptionContext) async throws -> String {
        let clip = audio.resampled(to: 16_000)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else {
            throw TranscriberError.failed("couldn't prepare audio")
        }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        for (index, sample) in clip.samples.enumerated() { channel[index] = sample }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.append(buffer)
        request.endAudio()

        let recognizer = self.recognizer
        let once = ResumeOnce<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                once.set(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        once.resume(.success(result.bestTranscription.formattedString))
                    } else if let error {
                        let nsError = error as NSError
                        // 1110 = "No speech detected": not a failure, just nothing to dub.
                        if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 203) {
                            once.resume(.success(""))
                        } else {
                            once.resume(.failure(TranscriberError.failed(nsError.localizedDescription)))
                        }
                    }
                }
                once.onCancel = { task.cancel() }
            }
        } onCancel: {
            once.cancel()
        }
    }
}

/// Resumes a continuation exactly once, from whichever callback gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false
    var onCancel: (() -> Void)?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if done {
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
        }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        let cancelHandler: (() -> Void)?
        lock.lock()
        cancelHandler = onCancel
        lock.unlock()
        cancelHandler?()
        resume(.failure(CancellationError()))
    }
}
