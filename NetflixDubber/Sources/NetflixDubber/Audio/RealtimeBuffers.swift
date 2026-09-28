import AudioToolbox
import Foundation
import os

/// Minimal wrapper over `os_unfair_lock` — safe to use briefly on audio threads.
final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}

/// Views an AudioBufferList as per-channel strided Float32 pointers, whether
/// the HAL delivered it interleaved (one buffer) or planar (one per channel).
struct FloatChannels {
    var pointers: [UnsafePointer<Float>] = []
    var strides: [Int] = []
    var frameCount = 0

    init(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            frameCount = frameCount == 0 ? frames : min(frameCount, frames)
            for channel in 0..<channels {
                pointers.append(base + channel)
                strides.append(channels)
            }
        }
    }

    @inline(__always)
    func sample(channel: Int, frame: Int) -> Float {
        pointers[channel][frame * strides[channel]]
    }
}

/// Stereo FIFO between the capture thread (writer) and the playback render
/// thread (reader) for the pass-through of the original programme audio.
final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let lock = UnfairLock()
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var primed = false
    /// Frames buffered before playback begins (and after an underrun) to absorb jitter.
    private let primeFrames: Int

    init(capacityFrames: Int = 96_000, primeFrames: Int = 1_024) {
        capacity = capacityFrames
        self.primeFrames = primeFrames
        left = .allocate(capacity: capacityFrames)
        right = .allocate(capacity: capacityFrames)
        left.initialize(repeating: 0, count: capacityFrames)
        right.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func reset() {
        lock.withLock {
            readIndex = 0
            writeIndex = 0
            available = 0
            primed = false
        }
    }

    func write(_ channels: FloatChannels) {
        guard !channels.pointers.isEmpty else { return }
        let rightChannel = channels.pointers.count > 1 ? 1 : 0
        lock.withLock {
            for frame in 0..<channels.frameCount {
                left[writeIndex] = channels.sample(channel: 0, frame: frame)
                right[writeIndex] = channels.sample(channel: rightChannel, frame: frame)
                writeIndex = (writeIndex + 1) % capacity
                if available == capacity {
                    readIndex = (readIndex + 1) % capacity   // overrun: drop the oldest frame
                } else {
                    available += 1
                }
            }
        }
    }

    /// Fills `frames` samples of each output channel, padding with silence on underrun.
    func read(left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLock {
            if !primed && available >= primeFrames { primed = true }
            // Drift guard: if latency has crept up, skip ahead to keep lip-sync tight.
            if available > primeFrames * 6 {
                let skip = available - primeFrames * 2
                readIndex = (readIndex + skip) % capacity
                available -= skip
            }
            var produced = 0
            if primed {
                let count = min(frames, available)
                for i in 0..<count {
                    outLeft[i] = left[readIndex]
                    outRight[i] = right[readIndex]
                    readIndex = (readIndex + 1) % capacity
                }
                available -= count
                produced = count
                if count < frames { primed = false }
            }
            for i in produced..<frames {
                outLeft[i] = 0
                outRight[i] = 0
            }
        }
    }
}

/// Mono accumulator for the analysis path; drained periodically off the audio thread.
final class MonoAccumulator: @unchecked Sendable {
    private let lock = UnfairLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    private let limit: Int

    init(limit: Int = 48_000 * 10) {
        self.limit = limit
        samples.reserveCapacity(48_000)
    }

    func append(_ channels: FloatChannels) {
        let channelCount = channels.pointers.count
        guard channelCount > 0 else { return }
        let scale = 1 / Float(channelCount)
        lock.withLock {
            for frame in 0..<channels.frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels.sample(channel: channel, frame: frame)
                }
                let mono = sum * scale
                peak = max(peak, abs(mono))
                samples.append(mono)
            }
            if samples.count > limit {
                samples.removeFirst(samples.count - limit)
            }
        }
    }

    /// Returns everything captured since the last drain, plus its peak level.
    func drain() -> (samples: [Float], peak: Float) {
        lock.withLock {
            let result = (samples, peak)
            samples.removeAll(keepingCapacity: true)
            peak = 0
            return result
        }
    }
}

/// Smoothly ramps the pass-through gain toward a target (ducking), per sample,
/// so level changes never click.
final class GainRamp: @unchecked Sendable {
    private let lock = UnfairLock()
    private var target: Float = 1
    private var current: Float = 1
    private let sampleRate: Float

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
    }

    func setTarget(_ value: Float) {
        lock.withLock { target = max(0, min(1, value)) }
    }

    func apply(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let goal = lock.withLock { target }
        var gain = current
        // ~40 ms attack when ducking down, ~350 ms release when coming back up.
        let time: Float = goal < gain ? 0.04 : 0.35
        let coefficient = 1 - exp(-1 / (time * sampleRate))
        for i in 0..<frames {
            gain += (goal - gain) * coefficient
            left[i] *= gain
            right[i] *= gain
        }
        current = gain
    }
}
