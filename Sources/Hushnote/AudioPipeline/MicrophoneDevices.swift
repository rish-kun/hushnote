@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation

public struct MicrophoneInputDevice: Equatable, Identifiable, Sendable {
    /// Core Audio's persistent device UID. Unlike an `AudioDeviceID`, this
    /// survives device-list rebuilds and app relaunches.
    public let id: String
    public let name: String
    public let isDefault: Bool
    let audioDeviceID: AudioDeviceID

    public init(id: String, name: String, isDefault: Bool, audioDeviceID: AudioDeviceID) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.audioDeviceID = audioDeviceID
    }
}

public enum MicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum MicrophoneCaptureError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case permissionDenied
    case permissionRestricted
    case noInputDevices
    case selectedDeviceUnavailable(String)
    case deviceEnumerationFailed(OSStatus)
    case deviceConfigurationFailed(OSStatus)
    case invalidDeviceFormat
    case captureStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Microphone capture is already running."
        case .notRunning:
            "Microphone capture is not running."
        case .permissionDenied:
            "Microphone access is off for Hushnote. Open System Settings → Privacy & Security → Microphone, enable Hushnote, then try again."
        case .permissionRestricted:
            "Microphone access is restricted on this Mac. Ask an administrator to allow microphone access for Hushnote."
        case .noInputDevices:
            "No microphone is connected. Connect a microphone or choose Disable microphone before recording."
        case .selectedDeviceUnavailable(let uid):
            "The selected microphone (\(uid)) is no longer available. Reconnect it or choose another microphone."
        case .deviceEnumerationFailed(let status):
            "Hushnote could not read the available microphones (Core Audio error \(status)). Reconnect the device and try again."
        case .deviceConfigurationFailed(let status):
            "Hushnote could not select that microphone (Core Audio error \(status)). Reconnect it or choose another microphone."
        case .invalidDeviceFormat:
            "The selected microphone does not provide a recordable audio format. Choose another microphone."
        case .captureStartFailed(let reason):
            "Hushnote could not start microphone capture: \(reason)"
        }
    }
}

protocol MicrophoneDeviceDiscovering: Sendable {
    func availableDevices() throws -> [MicrophoneInputDevice]
}

struct CoreAudioMicrophoneDeviceDiscovery: MicrophoneDeviceDiscovering {
    func availableDevices() throws -> [MicrophoneInputDevice] {
        let defaultID = try Self.defaultInputDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else { throw MicrophoneCaptureError.deviceEnumerationFailed(status) }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { throw MicrophoneCaptureError.deviceEnumerationFailed(status) }

        return deviceIDs.compactMap { deviceID in
            guard Self.hasInputStreams(deviceID),
                  let uid = Self.stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                  let name = Self.stringProperty(kAudioObjectPropertyName, of: deviceID)
            else { return nil }
            return MicrophoneInputDevice(
                id: uid,
                name: name,
                isDefault: deviceID == defaultID,
                audioDeviceID: deviceID
            )
        }
        .sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        )
        guard status == noErr else { throw MicrophoneCaptureError.deviceEnumerationFailed(status) }
        return deviceID
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount)
        return status == noErr && byteCount >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Use the pointer-sized unmanaged representation for Core Audio's CF
        // out parameter. Passing `CFString?` as raw mutable bytes triggers a
        // Swift 6 warning because an Optional may contain a managed reference.
        var unmanagedValue: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            &unmanagedValue
        )
        guard status == noErr, let unmanagedValue else { return nil }
        return unmanagedValue.takeUnretainedValue() as String
    }
}

protocol MicrophonePermissionAuthorizing: Sendable {
    func authorizationStatus() async -> MicrophoneAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    func authorizationStatus() async -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

enum MicrophoneDeviceResolver {
    static func resolve(
        selectedUID: String?,
        among devices: [MicrophoneInputDevice]
    ) throws -> MicrophoneInputDevice {
        guard !devices.isEmpty else { throw MicrophoneCaptureError.noInputDevices }
        if let selectedUID {
            guard let selected = devices.first(where: { $0.id == selectedUID }) else {
                throw MicrophoneCaptureError.selectedDeviceUnavailable(selectedUID)
            }
            return selected
        }
        return devices.first(where: \.isDefault) ?? devices[0]
    }
}
