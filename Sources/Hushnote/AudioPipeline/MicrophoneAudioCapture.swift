@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreAudio
import Foundation

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
    func pause() throws
    func resume() throws
    func stop()
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
        sampleHandler: @escaping MicrophoneSampleHandler
    ) async throws -> MicrophoneInputDevice {
        guard session == nil else { throw MicrophoneCaptureError.alreadyRunning }
        try await authorizeIfNeeded()
        let device = try MicrophoneDeviceResolver.resolve(
            selectedUID: selectedDeviceUID,
            among: deviceDiscovery.availableDevices()
        )
        let newSession = sessionFactory.makeSession()
        do {
            try newSession.start(device: device, sampleHandler: sampleHandler)
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
    private var hasTap = false
    private var running = false

    deinit {
        stop()
    }

    func start(device: MicrophoneInputDevice, sampleHandler: @escaping MicrophoneSampleHandler) throws {
        guard !hasTap else { throw MicrophoneCaptureError.alreadyRunning }
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
            let presentationSeconds = MicrophonePresentationClock.seconds(
                hostTime: time.isHostTimeValid ? time.hostTime : nil,
                sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                sampleRate: format.sampleRate
            )
            sampleHandler(buffer, presentationSeconds)
        }
        hasTap = true

        do {
            engine.prepare()
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            hasTap = false
            throw MicrophoneCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func pause() throws {
        guard running else { throw MicrophoneCaptureError.notRunning }
        engine.pause()
        running = false
    }

    func resume() throws {
        guard hasTap, !running else { throw MicrophoneCaptureError.notRunning }
        do {
            try engine.start()
            running = true
        } catch {
            throw MicrophoneCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        if running {
            engine.stop()
        }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        hasTap = false
        running = false
    }
}
