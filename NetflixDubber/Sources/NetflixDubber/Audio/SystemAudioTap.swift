import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum CaptureTarget: String, CaseIterable, Identifiable, Codable {
    /// Everything the Mac plays except this app (most reliable for Netflix in any browser).
    case allSystemAudio
    /// Only web-browser processes, so notifications and other apps are left alone.
    case browsers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allSystemAudio: return "All system audio (recommended)"
        case .browsers: return "Web browsers only"
        }
    }
}

/// Captures what the Mac is playing with a Core Audio process tap (macOS 14.2+)
/// and, while running, mutes the original so only the dubbed mix is heard.
///
/// No DRM is touched: this is the same OS-level audio capture used by
/// accessibility captioning tools. Audio is processed in memory and never saved.
final class SystemAudioTap {
    struct StreamFormat: Equatable {
        var sampleRate: Double
        var channelCount: Int
    }

    typealias InputHandler = (UnsafePointer<AudioBufferList>) -> Void

    private let queue = DispatchQueue(label: "netflix-dubber.capture", qos: .userInteractive)
    private var tapID = AudioObjectID.unknownObject
    private var aggregateID = AudioObjectID.unknownObject
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// Browser bundle-ID prefixes. Safari and other WebKit apps play media from
    /// the shared `com.apple.WebKit.GPU` process; Chromium browsers from helper processes.
    static let browserBundlePrefixes = [
        "com.apple.Safari", "com.apple.WebKit",
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser", "com.operasoftware", "com.vivaldi",
        "org.mozilla.",
    ]

    deinit {
        stop()
    }

    /// Creates the tap and starts delivering audio to `handler` on a real-time capture queue.
    /// - Parameter muteOriginal: silence the tapped audio at the output (we re-play it, ducked).
    @discardableResult
    func start(target: CaptureTarget, muteOriginal: Bool, handler: @escaping InputHandler) throws -> StreamFormat {
        stop()
        do {
            let description = try makeTapDescription(for: target)
            description.uuid = UUID()
            description.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted

            var newTap = AudioObjectID.unknownObject
            var status = AudioHardwareCreateProcessTap(description, &newTap)
            guard status == noErr, newTap.isValidObject else {
                throw CoreAudioError.status(action: "create the system audio tap", code: status)
            }
            tapID = newTap

            let outputUID = try AudioObjectID.defaultOutputDevice().deviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Netflix Dubber Capture",
                kAudioAggregateDeviceUIDKey: "netflix-dubber-\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ],
                ],
            ]

            let asbd = try tapID.tapFormat()
            guard asbd.mFormatID == AudioFormatID(kAudioFormatLinearPCM),
                  (asbd.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsFloat)) != 0,
                  asbd.mBitsPerChannel == 32
            else {
                throw CoreAudioError.unavailable("The system audio tap uses an unsupported sample format.")
            }
            let format = StreamFormat(sampleRate: asbd.mSampleRate, channelCount: Int(asbd.mChannelsPerFrame))

            var newAggregate = AudioObjectID.unknownObject
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
            guard status == noErr else {
                throw CoreAudioError.status(action: "create the capture device", code: status)
            }
            aggregateID = newAggregate

            var newProc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) { _, inputData, _, _, _ in
                handler(inputData)
            }
            guard status == noErr, let newProc else {
                throw CoreAudioError.status(action: "attach to the capture device", code: status)
            }
            procID = newProc

            status = AudioDeviceStart(aggregateID, newProc)
            guard status == noErr else {
                throw CoreAudioError.status(action: "start capturing", code: status)
            }
            isRunning = true
            return format
        } catch {
            stop()
            throw error
        }
    }

    /// Tears everything down. Destroying the tap un-mutes the original audio.
    func stop() {
        if aggregateID.isValidObject {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = .unknownObject
        if tapID.isValidObject {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = .unknownObject
        isRunning = false
    }

    /// True when a web browser is currently sending audio to the speakers.
    static func isBrowserPlayingAudio() -> Bool {
        guard let processes = try? AudioObjectID.audioProcesses() else { return false }
        return processes.contains { process in
            guard let bundleID = process.processBundleID(),
                  browserBundlePrefixes.contains(where: { bundleID.hasPrefix($0) })
            else { return false }
            let running = (try? process.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return running != 0
        }
    }

    private func makeTapDescription(for target: CaptureTarget) throws -> CATapDescription {
        switch target {
        case .allSystemAudio:
            // Exclude ourselves, otherwise the dub would be captured, muted and re-dubbed.
            // Our process object exists because the playback engine is started first.
            guard let ownProcess = AudioObjectID.processObject(for: getpid()) else {
                throw CoreAudioError.unavailable("Start the playback engine before capturing so the dubber can exclude its own audio.")
            }
            return CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])

        case .browsers:
            let processes = try AudioObjectID.audioProcesses().filter { process in
                guard let bundleID = process.processBundleID() else { return false }
                return Self.browserBundlePrefixes.contains { bundleID.hasPrefix($0) }
            }
            guard !processes.isEmpty else {
                throw CoreAudioError.unavailable("No browser is playing audio yet. Start the Netflix episode first, then press Start.")
            }
            return CATapDescription(stereoMixdownOfProcesses: processes)
        }
    }
}
