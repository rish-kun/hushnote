@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreAudio
import Foundation
import os

typealias MicrophoneSampleHandler = @Sendable (AVAudioPCMBuffer, Double) -> Void

enum MicrophonePresentationClock {
    static func seconds(
        hostTime: UInt64?,
        sampleTime: AVAudioFramePosition?,
        sampleRate: Double
    ) -> Double {
        if let hostTime {
            return Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
        }
        if let sampleTime, sampleRate > 0 {
            return Double(sampleTime) / sampleRate
        }
        return .nan
    }
}

protocol MicrophoneHardwareSession: AnyObject, Sendable {
    func start(device: MicrophoneInputDevice, sampleHandler: @escaping MicrophoneSampleHandler) throws
    func start(
        device: MicrophoneInputDevice,
        followsDefaultInput: Bool,
        sampleHandler: @escaping MicrophoneSampleHandler,
        noticeHandler: @escaping @Sendable (CaptureNotice) -> Void
    ) throws
    func pause() throws
    func resume() throws
    func stop()
}

/// The default implementation keeps older hardware fakes source-compatible;
/// real sessions opt into notices so a device disappearing underneath an
/// AVAudioEngine tap can be recovered without ending the meeting.
extension MicrophoneHardwareSession {
    func start(
        device: MicrophoneInputDevice,
        followsDefaultInput: Bool,
        sampleHandler: @escaping MicrophoneSampleHandler,
        noticeHandler: @escaping @Sendable (CaptureNotice) -> Void
    ) throws {
        try start(device: device, sampleHandler: sampleHandler)
    }
}

protocol MicrophoneHardwareSessionMaking: Sendable {
    func makeSession() -> any MicrophoneHardwareSession
}

struct AVAudioEngineMicrophoneSessionFactory: MicrophoneHardwareSessionMaking {
    func makeSession() -> any MicrophoneHardwareSession {
        AVAudioEngineMicrophoneSession()
    }
}

/// Owns one independently selectable microphone capture session. Hardware and
/// permission work are injected so unit tests never enumerate or open devices.
actor MicrophoneAudioCapture {
    private let deviceDiscovery: any MicrophoneDeviceDiscovering
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let sessionFactory: any MicrophoneHardwareSessionMaking
    private var session: (any MicrophoneHardwareSession)?
    private var paused = false

    init(
        deviceDiscovery: any MicrophoneDeviceDiscovering = CoreAudioMicrophoneDeviceDiscovery(),
        permissionAuthorizer: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        sessionFactory: any MicrophoneHardwareSessionMaking = AVAudioEngineMicrophoneSessionFactory()
    ) {
        self.deviceDiscovery = deviceDiscovery
        self.permissionAuthorizer = permissionAuthorizer
        self.sessionFactory = sessionFactory
    }

    func availableDevices() throws -> [MicrophoneInputDevice] {
        try deviceDiscovery.availableDevices()
    }

    func start(
        selectedDeviceUID: String?,
        sampleHandler: @escaping MicrophoneSampleHandler,
        noticeHandler: @escaping @Sendable (CaptureNotice) -> Void = { _ in }
    ) async throws -> MicrophoneInputDevice {
        guard session == nil else { throw MicrophoneCaptureError.alreadyRunning }
        try await authorizeIfNeeded()
        let device = try MicrophoneDeviceResolver.resolve(
            selectedUID: selectedDeviceUID,
            among: deviceDiscovery.availableDevices()
        )
        let newSession = sessionFactory.makeSession()
        do {
            try newSession.start(
                device: device,
                followsDefaultInput: selectedDeviceUID == nil,
                sampleHandler: sampleHandler,
                noticeHandler: noticeHandler
            )
            session = newSession
            paused = false
            return device
        } catch let error as MicrophoneCaptureError {
            newSession.stop()
            throw error
        } catch {
            newSession.stop()
            throw MicrophoneCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func pause() throws {
        guard let session, !paused else { throw MicrophoneCaptureError.notRunning }
        try session.pause()
        paused = true
    }

    func resume() throws {
        guard let session, paused else { throw MicrophoneCaptureError.notRunning }
        try session.resume()
        paused = false
    }

    func stop() throws {
        guard let session else { throw MicrophoneCaptureError.notRunning }
        session.stop()
        self.session = nil
        paused = false
    }

    private func authorizeIfNeeded() async throws {
        switch await permissionAuthorizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            guard await permissionAuthorizer.requestAccess() else {
                throw MicrophoneCaptureError.permissionDenied
            }
        case .denied:
            throw MicrophoneCaptureError.permissionDenied
        case .restricted:
            throw MicrophoneCaptureError.permissionRestricted
        }
    }
}

private final class AVAudioEngineMicrophoneSession: MicrophoneHardwareSession, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let listenerQueue = DispatchQueue(label: "com.hushnote.microphone-listener")
    private let watchdog: CaptureStallWatchdog
    private let noticeLock = OSAllocatedUnfairLock(initialState: false)
    private var hasTap = false
    private var running = false
    private var selectedDeviceID = kAudioObjectUnknown
    private var followsDefaultInput = false
    private var noticeHandler: (@Sendable (CaptureNotice) -> Void)?
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var streamConfigurationListener: AudioObjectPropertyListenerBlock?
    private var nominalSampleRateListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var engineConfigurationObserver: NSObjectProtocol?

    init(stallThreshold: TimeInterval = 3) {
        watchdog = CaptureStallWatchdog(threshold: stallThreshold)
        watchdog.onStall = { [weak self] silence in
            self?.reportNotice(
                .reconfigure(
                    .deviceChanged,
                    detail: "Microphone callback watchdog expired after \(silence) s."
                )
            )
        }
    }

    deinit {
        stop()
    }

    func start(device: MicrophoneInputDevice, sampleHandler: @escaping MicrophoneSampleHandler) throws {
        try start(
            device: device,
            followsDefaultInput: false,
            sampleHandler: sampleHandler,
            noticeHandler: { _ in }
        )
    }

    func start(
        device: MicrophoneInputDevice,
        followsDefaultInput: Bool,
        sampleHandler: @escaping MicrophoneSampleHandler,
        noticeHandler: @escaping @Sendable (CaptureNotice) -> Void
    ) throws {
        guard !hasTap else { throw MicrophoneCaptureError.alreadyRunning }
        noticeLock.withLock { $0 = false }
        self.noticeHandler = noticeHandler
        selectedDeviceID = device.audioDeviceID
        self.followsDefaultInput = followsDefaultInput
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw MicrophoneCaptureError.invalidDeviceFormat
        }

        var deviceID = device.audioDeviceID
        let selectionStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard selectionStatus == noErr else {
            throw MicrophoneCaptureError.deviceConfigurationFailed(selectionStatus)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.invalidDeviceFormat
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            self.watchdog.noteActivity(at: self.watchdog.now())
            let presentationSeconds = MicrophonePresentationClock.seconds(
                hostTime: time.isHostTimeValid ? time.hostTime : nil,
                sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                sampleRate: format.sampleRate
            )
            sampleHandler(buffer, presentationSeconds)
        }
        hasTap = true

        installListeners(for: device.audioDeviceID)
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.reportNotice(.reconfigure(
                .formatChanged,
                detail: "The microphone audio engine configuration changed."
            ))
        }

        do {
            engine.prepare()
            try engine.start()
            running = true
            watchdog.begin(at: watchdog.now())
            watchdog.startTimer()
        } catch {
            stop()
            throw MicrophoneCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func pause() throws {
        guard running else { throw MicrophoneCaptureError.notRunning }
        watchdog.suspend()
        engine.pause()
        running = false
    }

    func resume() throws {
        guard hasTap, !running else { throw MicrophoneCaptureError.notRunning }
        do {
            try engine.start()
            running = true
            watchdog.resume(at: watchdog.now())
        } catch {
            throw MicrophoneCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        watchdog.stop()
        watchdog.stopTimer()
        removeListeners()
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        self.engineConfigurationObserver = nil
        if running {
            engine.stop()
        }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        hasTap = false
        running = false
        selectedDeviceID = kAudioObjectUnknown
        followsDefaultInput = false
        noticeHandler = nil
    }

    private func reportNotice(_ notice: CaptureNotice) {
        let isFirst = noticeLock.withLock { reported -> Bool in
            guard !reported else { return false }
            reported = true
            return true
        }
        guard isFirst else { return }
        noticeHandler?(notice)
    }

    private func installListeners(for deviceID: AudioDeviceID) {
        deviceAliveListener = installDeviceListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            listener: { [weak self] _, _ in
                guard let self else { return }
                guard Self.isDeviceAlive(deviceID) else {
                    self.reportNotice(.reconfigure(
                        .deviceChanged,
                        detail: "The microphone was disconnected."
                    ))
                    return
                }
            }
        )
        streamConfigurationListener = installDeviceListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            listener: { [weak self] _, _ in
                self?.reportNotice(.reconfigure(
                    .formatChanged,
                    detail: "The microphone input stream configuration changed."
                ))
            }
        )
        nominalSampleRateListener = installDeviceListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            listener: { [weak self] _, _ in
                self?.reportNotice(.reconfigure(.formatChanged, detail: "The microphone sample rate changed."))
            }
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            guard Self.deviceIsPresent(deviceID) else {
                self.reportNotice(.reconfigure(
                    .deviceChanged,
                    detail: "The microphone was removed from the audio device list."
                ))
                return
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            listenerQueue,
            devicesListener
        ) == noErr {
            deviceListListener = devicesListener
        }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.followsDefaultInput else { return }
            guard let current = Self.defaultInputDeviceID(), current != deviceID else { return }
            self.reportNotice(.reconfigure(
                .deviceChanged,
                detail: "The default input microphone changed."
            ))
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            listenerQueue,
            defaultListener
        ) == noErr {
            defaultInputListener = defaultListener
        }
    }

    private func installDeviceListener(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> AudioObjectPropertyListenerBlock? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, listener) == noErr {
            return listener
        }
        return nil
    }

    private func removeListeners() {
        guard selectedDeviceID != kAudioObjectUnknown else { return }
        let deviceID = selectedDeviceID
        removeDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, listener: deviceAliveListener)
        removeDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyStreamConfiguration, listener: streamConfigurationListener)
        removeDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate, listener: nominalSampleRateListener)
        deviceAliveListener = nil
        streamConfigurationListener = nil
        nominalSampleRateListener = nil
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let deviceListListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                listenerQueue,
                deviceListListener
            )
        }
        self.deviceListListener = nil
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                listenerQueue,
                defaultInputListener
            )
        }
        self.defaultInputListener = nil
    }

    private func removeDeviceListener(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        listener: AudioObjectPropertyListenerBlock?
    ) {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listener)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    private static func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    private static func deviceIsPresent(_ selectedID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return false }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard devices.withUnsafeMutableBytes({ bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }) == noErr else { return false }
        return devices.contains(selectedID)
    }
}
