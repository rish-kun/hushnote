@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import os

/// Captures the global system mix through Core Audio's process-tap API.
///
/// Unlike a ScreenCaptureKit display stream, this API is governed by macOS's
/// dedicated "System Audio Recording Only" privacy permission and never asks
/// for access to screen pixels.
final class SystemAudioTapCapture: @unchecked Sendable {
    typealias SampleHandler = @Sendable (AVAudioPCMBuffer, Double) -> Void
    typealias NoticeHandler = @Sendable (CaptureNotice) -> Void

    private let callbackQueue = DispatchQueue(
        label: "com.hushnote.system-audio-tap",
        qos: .userInitiated
    )
    private let processingQueue = DispatchQueue(
        label: "com.hushnote.system-audio-processing",
        qos: .userInitiated
    )
    private let listenerQueue = DispatchQueue(label: "com.hushnote.system-audio-listener")
    /// Roughly a second of headroom at typical device buffer sizes, and the
    /// number of pre-allocated copy slots the ring holds.
    static let queueSlotCount = 64
    private let availableQueueSlots = DispatchSemaphore(value: queueSlotCount)
    private let sampleHandler: SampleHandler
    private let noticeHandler: NoticeHandler?
    private let watchdog: CaptureStallWatchdog
    private let drops: CaptureDropAccountant
    private let hasReportedFailure = OSAllocatedUnfairLock(initialState: false)

    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFormat: AVAudioFormat?
    private var bufferRing: CaptureBufferRing?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var listeningTapID = kAudioObjectUnknown
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(
        sampleHandler: @escaping SampleHandler,
        noticeHandler: NoticeHandler? = nil,
        stallThreshold: TimeInterval = 3,
        consecutiveCopyFailureLimit: Int = 10
    ) {
        self.sampleHandler = sampleHandler
        self.noticeHandler = noticeHandler
        drops = CaptureDropAccountant(consecutiveFailureLimit: consecutiveCopyFailureLimit)
        watchdog = CaptureStallWatchdog(threshold: stallThreshold)
        watchdog.onStall = { [weak self] silence in
            let seconds = String(format: "%.1f", silence)
            self?.reportReconfiguration(
                .deviceChanged,
                detail: "System audio stopped arriving for \(seconds) s."
            )
        }
        // Drops are counted on the real-time thread and reported from here, off
        // it. Pulling on a timer also keeps one stalled disk from producing a
        // storm of events.
        watchdog.onTick = { [weak self] in
            guard let self else { return }
            if let report = self.drops.flush() {
                self.noticeHandler?(.dropped(report))
            }
            if self.drops.isPermanentlyFailing {
                self.reportReconfiguration(
                    .formatChanged,
                    detail: "The device rejected \(self.drops.consecutiveFailureLimit) consecutive buffers."
                )
            }
        }
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !running else { throw AudioPipelineError.alreadyRunning }
        hasReportedFailure.withLock { $0 = false }
        drops.reset()

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
            operation: Operation.createTap
        )
        guard createdTap != kAudioObjectUnknown else {
            throw AudioPipelineError.audioCaptureFailed
        }
        tapID = createdTap

        do {
            let format = try Self.tapFormat(for: tapID)
            audioFormat = format
            // The format used to be read once here and trusted for the rest of
            // the session. Plugging in AirPods mid-meeting changes it
            // underneath, and nothing noticed.
            installFormatListener(expecting: format)
            installDefaultOutputListener()

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

            // Allocated once, here, rather than once per callback inside the
            // IOProc. Sized from the device's own buffer size with room to
            // spare, and matched to the queue's slot count so a slot cannot be
            // reused while its buffer is still in flight.
            let slotFrames = max(2_048, Self.bufferFrameSize(of: aggregateDeviceID) * 2)
            guard let ring = CaptureBufferRing(
                format: format,
                capacityFrames: slotFrames,
                slotCount: Self.queueSlotCount
            ) else {
                throw AudioPipelineError.unsupportedAudioFormat
            }
            bufferRing = ring

            var createdIOProc: AudioDeviceIOProcID?
            let handler = sampleHandler
            let processingQueue = processingQueue
            let availableQueueSlots = availableQueueSlots
            let watchdog = watchdog
            let drops = drops
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProc,
                    aggregateDeviceID,
                    callbackQueue
                ) { _, inputData, inputTime, _, _ in
                    // Noted before any early return: a buffer that is dropped
                    // still proves the device is alive.
                    watchdog.noteActivity(at: watchdog.now())
                    let offeredFrames = Self.frameCount(of: inputData, format: format)
                    guard availableQueueSlots.wait(timeout: .now()) == .success else {
                        drops.noteBackpressureDrop(frames: offeredFrames)
                        return
                    }
                    guard let buffer = ring.copy(
                        from: inputData,
                        frames: AVAudioFrameCount(offeredFrames)
                    ) else {
                        availableQueueSlots.signal()
                        drops.noteCopyFailure(frames: offeredFrames)
                        return
                    }
                    drops.noteCopySuccess()

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
            // From here on, silence is a failure rather than a quiet meeting:
            // the IOProc fires whether or not anything is playing.
            watchdog.begin(at: watchdog.now())
            watchdog.startTimer()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        watchdog.stop()
        watchdog.stopTimer()
        removeFormatListener()
        removeDefaultOutputListener()
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
        bufferRing = nil
    }

    func pause() throws {
        guard running, aggregateDeviceID != kAudioObjectUnknown, let ioProcID else {
            throw AudioPipelineError.notRunning
        }
        // Suspended before the device stops, so the watchdog cannot mistake a
        // deliberate pause for a dead HAL.
        watchdog.suspend()
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
        watchdog.resume(at: watchdog.now())
    }

    private func reportFailure(_ message: String) {
        let isFirst = hasReportedFailure.withLock { reported -> Bool in
            guard !reported else { return false }
            reported = true
            return true
        }
        guard isFirst else { return }
        noticeHandler?(.failure(message))
    }

    private func reportReconfiguration(
        _ kind: AudioCaptureTransitionKind,
        detail: String?
    ) {
        let isFirst = hasReportedFailure.withLock { reported -> Bool in
            guard !reported else { return false }
            reported = true
            return true
        }
        guard isFirst else { return }
        noticeHandler?(.reconfigure(kind, detail: detail))
    }

    /// Watches the one property the whole capture path is pinned to.
    private func installFormatListener(expecting format: AVAudioFormat) {
        let observedTap = tapID
        var address = Self.formatAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            guard let updated = try? Self.tapFormat(for: observedTap) else {
                self.reportReconfiguration(
                    .formatChanged,
                    detail: "The updated system-audio format could not be read."
                )
                return
            }
            guard Self.isFatalFormatChange(from: format, to: updated) else { return }
            self.reportReconfiguration(
                .formatChanged,
                detail: "\(Self.describe(format)) became \(Self.describe(updated))."
            )
        }
        let status = AudioObjectAddPropertyListenerBlock(observedTap, &address, listenerQueue, listener)
        guard status == noErr else { return }
        formatListener = listener
        listeningTapID = observedTap
    }

    private func removeFormatListener() {
        guard let formatListener, listeningTapID != kAudioObjectUnknown else { return }
        var address = Self.formatAddress
        // Removed before the tap is destroyed, so no callback can outlive it.
        AudioObjectRemovePropertyListenerBlock(listeningTapID, &address, listenerQueue, formatListener)
        self.formatListener = nil
        listeningTapID = kAudioObjectUnknown
    }

    private func installDefaultOutputListener() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reportReconfiguration(
                .deviceChanged,
                detail: "The default output device changed."
            )
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        guard status == noErr else { return }
        defaultOutputListener = listener
    }

    private func removeDefaultOutputListener() {
        guard let defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultOutputListener
        )
        self.defaultOutputListener = nil
    }

    private static let formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func tapFormat(for tapID: AudioObjectID) throws -> AVAudioFormat {
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = formatAddress
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription),
            operation: "read the system-audio format"
        )
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AudioPipelineError.unsupportedAudioFormat
        }
        return format
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz \(format.channelCount) ch"
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

    /// Frames in a HAL buffer list, by arithmetic.
    ///
    /// The alternative is allocating a throwaway `AVAudioPCMBuffer` purely to
    /// read `frameLength` off it, on the HAL's real-time thread.
    static func frameCount(
        of inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> Int64 {
        let bytesPerFrame = Int64(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = list.first else { return 0 }
        return Int64(first.mDataByteSize) / bytesPerFrame
    }

    /// Aggregate-device composition happens asynchronously inside the HAL.
    /// Creating the device and setting its tap list can both succeed before an
    /// input stream is published. Starting an IOProc in that window produces
    /// the intermittent `'nope'` (1852797029) error.
    /// The device's own IO buffer size, which is what the IOProc will deliver.
    private static func bufferFrameSize(of deviceID: AudioObjectID) -> AVAudioFrameCount {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              value > 0
        else { return 4_096 }
        return AVAudioFrameCount(value)
    }

    private static func waitUntilInputStreamIsReady(on deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        try CaptureStartPreparation.waitForInputStream(probe: {
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
            return .init(status: status, byteCount: size)
        })
    }

    /// Core Audio can still briefly reject the first start while applying an
    /// aggregate-device graph update. Retrying the same fully configured
    /// device is safe and doesn't alter playback or any other recording app.
    private static func startDeviceWithRecovery(
        _ deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        try CaptureStartPreparation.startDevice {
            AudioDeviceStart(deviceID, ioProcID)
        }
    }

    /// The format read at start is used to wrap every buffer for the rest of the
    /// session, so any change to it invalidates the whole capture path: a
    /// different channel count makes every buffer copy fail forever, and a
    /// different rate writes the remainder of the meeting pitch-shifted and
    /// time-stretched. There is no safe partial adaptation mid-take.
    static func isFatalFormatChange(from previous: AVAudioFormat, to updated: AVAudioFormat) -> Bool {
        previous.sampleRate != updated.sampleRate
            || previous.channelCount != updated.channelCount
            || previous.commonFormat != updated.commonFormat
            || previous.isInterleaved != updated.isInterleaved
    }

    /// Operation names that error mapping keys on, rather than matching prose.
    enum Operation {
        static let createTap = "create the system-audio tap"
        static let startDevice = "start system-audio capture"
        static let startDeviceAfterWaiting = "start system-audio capture after waiting for Core Audio"
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            // Core Audio reports privacy denials as an OSStatus. Preserve the
            // numeric code for diagnostics without including captured content.
            throw AudioPipelineError.coreAudioFailure(operation, status)
        }
    }
}
