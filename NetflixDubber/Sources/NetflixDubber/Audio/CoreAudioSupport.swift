import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case status(action: String, code: OSStatus)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .status(let action, let code):
            return "Core Audio couldn't \(action) (error \(code)\(Self.fourCC(code)))."
        case .unavailable(let message):
            return message
        }
    }

    private static func fourCC(_ code: OSStatus) -> String {
        let value = UInt32(bitPattern: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }
}

/// Typed access to Core Audio HAL object properties.
extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    var isValidObject: Bool { self != AudioObjectID(kAudioObjectUnknown) }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudioError.status(action: "read property \(selector)", code: status) }
        return result
    }

    func read<T, Q>(_ selector: AudioObjectPropertySelector, qualifier: Q, default value: T) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        var qualifierValue = qualifier
        let status = withUnsafeMutablePointer(to: &qualifierValue) { qualifierPointer in
            withUnsafeMutablePointer(to: &result) { pointer in
                AudioObjectGetPropertyData(self, &address, UInt32(MemoryLayout<Q>.size), qualifierPointer, &size, pointer)
            }
        }
        guard status == noErr else { throw CoreAudioError.status(action: "read property \(selector)", code: status) }
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudioError.status(action: "read string property \(selector)", code: status) }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError.status(action: "size property \(selector)", code: status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknownObject, count: count)
        status = list.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError.status(action: "read list property \(selector)", code: status) }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    // MARK: - Concrete properties

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let device = try AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknownObject)
        guard device.isValidObject else { throw CoreAudioError.unavailable("No audio output device is available.") }
        return device
    }

    func deviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    /// Core Audio's process object for a pid; only exists once that process has used audio.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        let object = try? AudioObjectID.systemObject.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            qualifier: pid,
            default: AudioObjectID.unknownObject
        )
        guard let object, object.isValidObject else { return nil }
        return object
    }

    static func audioProcesses() throws -> [AudioObjectID] {
        try AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList)
    }

    func processBundleID() -> String? {
        guard let id = try? readString(kAudioProcessPropertyBundleID), !id.isEmpty else { return nil }
        return id
    }

    func tapFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }
}
