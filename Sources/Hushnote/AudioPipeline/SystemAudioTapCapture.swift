@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation

/// Captures the global system mix through Core Audio's process-tap API.
///
/// Unlike a ScreenCaptureKit display stream, this API is governed by macOS's
/// dedicated "System Audio Recording Only" privacy permission and never asks
/// for access to screen pixels.
final class SystemAudioTapCapture: @unchecked Sendable {
    typealias SampleHandler = @Sendable (AVAudioPCMBuffer, Double) -> Void

    private let callbackQueue = DispatchQueue(
        label: "com.hushnote.system-audio-tap",
        qos: .userInitiated
    )
    private let processingQueue = DispatchQueue(
        label: "com.hushnote.system-audio-processing",
        qos: .userInitiated
    )
    private let availableQueueSlots = DispatchSemaphore(value: 64)
    private let sampleHandler: SampleHandler

    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFormat: AVAudioFormat?
    private var running = false

    init(sampleHandler: @escaping SampleHandler) {
        self.sampleHandler = sampleHandler
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !running else { throw AudioPipelineError.alreadyRunning }

        let ownProcess = try Self.audioProcessObject(for: getpid())
        let exclusions = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: exclusions)
        tapDescription.name = "Hushnote System Audio"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTap = kAudioObjectUnknown
        try Self.check(
            AudioHardwareCreateProcessTap(tapDescription, &createdTap),
            operation: "create the system-audio tap"
        )
        guard createdTap != kAudioObjectUnknown else {
            throw AudioPipelineError.audioCaptureFailed
        }
        tapID = createdTap

        do {
            var streamDescription = AudioStreamBasicDescription()
            var streamDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try Self.check(
                AudioObjectGetPropertyData(
                    tapID,
                    &formatAddress,
                    0,
                    nil,
                    &streamDescriptionSize,
                    &streamDescription
                ),
                operation: "read the system-audio format"
            )
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw AudioPipelineError.unsupportedAudioFormat
            }
            audioFormat = format

            let aggregateUID = "dev.rishit.hushnote.tap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Hushnote System Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
            ]

            var createdDevice = kAudioObjectUnknown
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &createdDevice
                ),
                operation: "create the private system-audio device"
            )
            guard createdDevice != kAudioObjectUnknown else {
                throw AudioPipelineError.audioCaptureFailed
            }
            aggregateDeviceID = createdDevice
            let tapUID = try Self.tapUID(for: tapID)
            try Self.addTap(tapUID, to: aggregateDeviceID)
            try Self.waitUntilInputStreamIsReady(on: aggregateDeviceID)

            var createdIOProc: AudioDeviceIOProcID?
            let handler = sampleHandler
            let processingQueue = processingQueue
            let availableQueueSlots = availableQueueSlots
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProc,
                    aggregateDeviceID,
                    callbackQueue
                ) { _, inputData, inputTime, _, _ in
                    guard availableQueueSlots.wait(timeout: .now()) == .success else { return }
                    guard let buffer = Self.ownedCopy(of: inputData, format: format) else {
                        availableQueueSlots.signal()
                        return
                    }

                    let presentationSeconds: Double
                    if inputTime.pointee.mFlags.contains(.hostTimeValid) {
                        presentationSeconds = Double(
                            AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)
                        ) / 1_000_000_000
                    } else if inputTime.pointee.mFlags.contains(.sampleTimeValid) {
                        presentationSeconds = inputTime.pointee.mSampleTime / format.sampleRate
                    } else {
                        presentationSeconds = .nan
                    }
                    processingQueue.async {
                        handler(buffer, presentationSeconds)
                        availableQueueSlots.signal()
                    }
                },
                operation: "install the system-audio callback"
            )
            guard let createdIOProc else {
                throw AudioPipelineError.audioCaptureFailed
            }
            ioProcID = createdIOProc

            try Self.startDeviceWithRecovery(aggregateDeviceID, ioProcID: createdIOProc)
            running = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            if running {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        processingQueue.sync {}
        ioProcID = nil
        running = false

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        audioFormat = nil
    }

    func pause() throws {
        guard running, aggregateDeviceID != kAudioObjectUnknown, let ioProcID else {
            throw AudioPipelineError.notRunning
        }
        try Self.check(AudioDeviceStop(aggregateDeviceID, ioProcID), operation: "pause system-audio capture")
        running = false
        processingQueue.sync {}
    }

    func resume() throws {
        guard !running, aggregateDeviceID != kAudioObjectUnknown, let ioProcID else {
            throw AudioPipelineError.notRunning
        }
        try Self.check(AudioDeviceStart(aggregateDeviceID, ioProcID), operation: "resume system-audio capture")
        running = true
    }

    private static func audioProcessObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = pid
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), qualifierPointer, &size, &processID
            )
        }
        try check(status, operation: "identify Hushnote's audio process")
        return processID
    }

    private static func tapUID(for tapID: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        try check(status, operation: "read the system-audio tap identifier")
        return uid
    }

    private static func addTap(_ tapUID: CFString, to aggregateID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size),
            operation: "read the aggregate tap-list size"
        )
        var existing: CFArray?
        if size > 0 {
            let status = withUnsafeMutablePointer(to: &existing) { pointer in
                AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, pointer)
            }
            try check(status, operation: "read the aggregate tap list")
        }
        var identifiers = (existing as? [CFString]) ?? []
        if !identifiers.contains(where: { $0 as String == tapUID as String }) {
            identifiers.append(tapUID)
        }
        var updated: CFArray? = identifiers as CFArray
        let updatedSize = UInt32(MemoryLayout<CFString>.stride * identifiers.count)
        let status = withUnsafePointer(to: &updated) { pointer in
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil, updatedSize, pointer)
        }
        try check(status, operation: "attach the system-audio tap")
    }

    private static func ownedCopy(
        of inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let borrowed = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData,
            deallocator: nil
        ),
        let owned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: borrowed.frameLength)
        else { return nil }
        owned.frameLength = borrowed.frameLength

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { continue }
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return owned
    }

    /// Aggregate-device composition happens asynchronously inside the HAL.
    /// Creating the device and setting its tap list can both succeed before an
    /// input stream is published. Starting an IOProc in that window produces
    /// the intermittent `'nope'` (1852797029) error.
    private static func waitUntilInputStreamIsReady(on deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        for attempt in 0..<40 {
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
            if status == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
                return
            }
            if status != noErr, attempt > 4 {
                try check(status, operation: "prepare the system-audio input stream")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw AudioPipelineError.audioCaptureFailed
    }

    /// Core Audio can still briefly reject the first start while applying an
    /// aggregate-device graph update. Retrying the same fully configured
    /// device is safe and doesn't alter playback or any other recording app.
    private static func startDeviceWithRecovery(
        _ deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        let retryDelays: [TimeInterval] = [0, 0.05, 0.1, 0.2, 0.4]
        var lastStatus: OSStatus = noErr
        for delay in retryDelays {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lastStatus = AudioDeviceStart(deviceID, ioProcID)
            if lastStatus == noErr { return }
            // `'nope'` is HAL's transient illegal-operation response. Other
            // errors are deterministic and should be surfaced immediately.
            guard lastStatus == OSStatus(bitPattern: 0x6E6F7065) else {
                try check(lastStatus, operation: "start system-audio capture")
                return
            }
        }
        try check(lastStatus, operation: "start system-audio capture after waiting for Core Audio")
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            // Core Audio reports privacy denials as an OSStatus. Preserve the
            // numeric code for diagnostics without including captured content.
            throw AudioPipelineError.coreAudioFailure(operation, status)
        }
    }
}
