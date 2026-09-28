import AVFoundation
import DubberCore
import Foundation

/// Output side of the dubber:
///
///     captured original ─► ring buffer ─► source node ─► gain ramp (ducking) ─┐
///                                                                              ├─► main mixer ─► speakers
///     English dub clips ─► player node ─► time-pitch (catch-up speed) ─────────┘
final class DubAudioEngine {
    static let dubSampleRate: Double = 48_000

    private let engine = AVAudioEngine()
    private let dubPlayer = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let dubFormat = AVAudioFormat(standardFormatWithSampleRate: DubAudioEngine.dubSampleRate, channels: 1)!
    private var passthroughNode: AVAudioSourceNode?
    private var gainRamp: GainRamp?

    let passthroughBuffer = StereoRingBuffer()

    private(set) var isRunning = false

    init() {
        engine.attach(dubPlayer)
        engine.attach(timePitch)
        engine.connect(dubPlayer, to: timePitch, format: dubFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: dubFormat)
    }

    /// Starts audio output. Must run before the capture tap is created so Core
    /// Audio knows this process and the global tap can exclude it.
    func startOutput() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
        dubPlayer.play()
        isRunning = true
    }

    /// Adds the pass-through of the (muted-at-source) original audio.
    func attachPassthrough(sampleRate: Double) throws {
        detachPassthrough()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CoreAudioError.unavailable("Unsupported capture sample rate \(sampleRate).")
        }
        let ramp = GainRamp(sampleRate: sampleRate)
        let ring = passthroughBuffer
        ring.reset()
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            ring.read(left: left, right: right, frames: frames)
            ramp.apply(left: left, right: right, frames: frames)
            return noErr
        }

        // Reconnecting a running graph is fragile; briefly stop, rewire, restart.
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        passthroughNode = node
        gainRamp = ramp
        if wasRunning {
            engine.prepare()
            try engine.start()
            dubPlayer.play()
        }
    }

    private func detachPassthrough() {
        if let node = passthroughNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        passthroughNode = nil
        gainRamp = nil
    }

    /// Gain (0…1) of the original programme audio; ramps smoothly.
    func setOriginalGain(_ gain: Float) {
        gainRamp?.setTarget(gain)
    }

    var dubVolume: Float {
        get { dubPlayer.volume }
        set { dubPlayer.volume = max(0, min(1, newValue)) }
    }

    /// Playback speed of the dub track (pitch preserved).
    func setDubRate(_ rate: Float) {
        timePitch.rate = max(0.5, min(2, rate))
    }

    /// Queues a dub clip (48 kHz mono). `completion` fires once it has been heard.
    func schedule(_ clip: AudioClip, gain: Float, completion: @escaping () -> Void) {
        let audio = clip.sampleRate == Self.dubSampleRate ? clip : clip.resampled(to: Self.dubSampleRate)
        guard !audio.samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: dubFormat, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else {
            completion()
            return
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        let scale = max(0, min(2, gain))
        for (index, sample) in audio.samples.enumerated() {
            channel[index] = max(-1, min(1, sample * scale))
        }
        dubPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completion()
        }
        if !dubPlayer.isPlaying { dubPlayer.play() }
    }

    func stop() {
        dubPlayer.stop()
        detachPassthrough()
        engine.stop()
        passthroughBuffer.reset()
        isRunning = false
    }
}
