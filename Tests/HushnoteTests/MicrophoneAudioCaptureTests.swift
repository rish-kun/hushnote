import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Hushnote

@Suite("Microphone audio capture")
struct MicrophoneAudioCaptureTests {
    private static let builtIn = MicrophoneInputDevice(
        id: "built-in-uid",
        name: "MacBook Microphone",
        isDefault: true,
        audioDeviceID: 41
    )
    private static let headset = MicrophoneInputDevice(
        id: "headset-uid",
        name: "USB Headset",
        isDefault: false,
        audioDeviceID: 52
    )

    @Test("No selection resolves to the current default input")
    func defaultSelection() throws {
        let selected = try MicrophoneDeviceResolver.resolve(
            selectedUID: nil,
            among: [Self.headset, Self.builtIn]
        )

        #expect(selected.id == Self.builtIn.id)
    }

    @Test("A persistent UID resolves the selected input")
    func explicitSelection() throws {
        let selected = try MicrophoneDeviceResolver.resolve(
            selectedUID: Self.headset.id,
            among: [Self.builtIn, Self.headset]
        )

        #expect(selected.id == Self.headset.id)
    }

    @Test("A disconnected selected input produces an actionable error")
    func unavailableSelection() {
        #expect(throws: MicrophoneCaptureError.selectedDeviceUnavailable("gone")) {
            try MicrophoneDeviceResolver.resolve(
                selectedUID: "gone",
                among: [Self.builtIn]
            )
        }
        #expect(
            MicrophoneCaptureError.selectedDeviceUnavailable("gone")
                .localizedDescription.contains("choose another microphone")
        )
    }

    @Test("Host time is converted to the shared monotonic seconds domain")
    func hostTimePresentationClock() {
        let hostTime = AudioConvertNanosToHostTime(2_500_000_000)

        let seconds = MicrophonePresentationClock.seconds(
            hostTime: hostTime,
            sampleTime: nil,
            sampleRate: 48_000
        )

        #expect(abs(seconds - 2.5) < 0.000_001)
    }

    @Test("Sample time is the fallback when a host clock is unavailable")
    func sampleTimePresentationClock() {
        let seconds = MicrophonePresentationClock.seconds(
            hostTime: nil,
            sampleTime: 24_000,
            sampleRate: 48_000
        )

        #expect(seconds == 0.5)
        #expect(MicrophonePresentationClock.seconds(
            hostTime: nil,
            sampleTime: nil,
            sampleRate: 48_000
        ).isNaN)
    }

    @Test("Denied permission never opens audio hardware")
    func deniedPermission() async {
        let hardware = FakeMicrophoneHardwareSession()
        let capture = makeCapture(
            permission: .denied,
            hardware: hardware
        )

        do {
            _ = try await capture.start(selectedDeviceUID: nil) { _, _ in }
            Issue.record("Expected microphone permission denial")
        } catch {
            #expect(error as? MicrophoneCaptureError == .permissionDenied)
        }
        #expect(hardware.snapshot.starts.isEmpty)
    }

    @Test("First use requests permission before opening the selected device")
    func permissionRequestAndStart() async throws {
        let hardware = FakeMicrophoneHardwareSession()
        let capture = makeCapture(
            permission: .notDetermined,
            requestResult: true,
            hardware: hardware
        )

        let selected = try await capture.start(selectedDeviceUID: Self.headset.id) { _, _ in }

        #expect(selected.id == Self.headset.id)
        #expect(hardware.snapshot.starts == [Self.headset.id])
    }

    @Test("A denied first-use request reports permission guidance")
    func deniedPermissionRequest() async {
        let hardware = FakeMicrophoneHardwareSession()
        let capture = makeCapture(
            permission: .notDetermined,
            requestResult: false,
            hardware: hardware
        )

        do {
            _ = try await capture.start(selectedDeviceUID: nil) { _, _ in }
            Issue.record("Expected microphone permission denial")
        } catch {
            #expect(error as? MicrophoneCaptureError == .permissionDenied)
            #expect(error.localizedDescription.contains("Privacy & Security"))
        }
        #expect(hardware.snapshot.starts.isEmpty)
    }

    @Test("Pause, resume, and stop preserve one hardware session")
    func lifecycle() async throws {
        let hardware = FakeMicrophoneHardwareSession()
        let capture = makeCapture(permission: .authorized, hardware: hardware)

        _ = try await capture.start(selectedDeviceUID: nil) { _, _ in }
        try await capture.pause()
        try await capture.resume()
        try await capture.stop()

        #expect(hardware.snapshot == .init(starts: [Self.builtIn.id], pauses: 1, resumes: 1, stops: 1))
    }

    @Test("An empty catalog does not create a hardware session")
    func noInputs() async {
        let hardware = FakeMicrophoneHardwareSession()
        let capture = MicrophoneAudioCapture(
            deviceDiscovery: FakeMicrophoneDeviceDiscovery(devices: []),
            permissionAuthorizer: FakeMicrophonePermissionAuthorizer(status: .authorized),
            sessionFactory: FakeMicrophoneHardwareFactory(session: hardware)
        )

        do {
            _ = try await capture.start(selectedDeviceUID: nil) { _, _ in }
            Issue.record("Expected no-input-device error")
        } catch {
            #expect(error as? MicrophoneCaptureError == .noInputDevices)
        }
        #expect(hardware.snapshot.starts.isEmpty)
    }

    private func makeCapture(
        permission: MicrophoneAuthorizationStatus,
        requestResult: Bool = false,
        hardware: FakeMicrophoneHardwareSession
    ) -> MicrophoneAudioCapture {
        MicrophoneAudioCapture(
            deviceDiscovery: FakeMicrophoneDeviceDiscovery(devices: [Self.builtIn, Self.headset]),
            permissionAuthorizer: FakeMicrophonePermissionAuthorizer(
                status: permission,
                requestResult: requestResult
            ),
            sessionFactory: FakeMicrophoneHardwareFactory(session: hardware)
        )
    }
}

private struct FakeMicrophoneDeviceDiscovery: MicrophoneDeviceDiscovering {
    let devices: [MicrophoneInputDevice]

    func availableDevices() throws -> [MicrophoneInputDevice] {
        devices
    }
}

private struct FakeMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    let status: MicrophoneAuthorizationStatus
    var requestResult = false

    func authorizationStatus() async -> MicrophoneAuthorizationStatus {
        status
    }

    func requestAccess() async -> Bool {
        requestResult
    }
}

private struct FakeMicrophoneHardwareFactory: MicrophoneHardwareSessionMaking {
    let session: FakeMicrophoneHardwareSession

    func makeSession() -> any MicrophoneHardwareSession {
        session
    }
}

private final class FakeMicrophoneHardwareSession: MicrophoneHardwareSession, @unchecked Sendable {
    struct Snapshot: Equatable {
        var starts: [String] = []
        var pauses = 0
        var resumes = 0
        var stops = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { state }
    }

    func start(device: MicrophoneInputDevice, sampleHandler: @escaping MicrophoneSampleHandler) throws {
        lock.withLock { state.starts.append(device.id) }
    }

    func pause() throws {
        lock.withLock { state.pauses += 1 }
    }

    func resume() throws {
        lock.withLock { state.resumes += 1 }
    }

    func stop() {
        lock.withLock { state.stops += 1 }
    }
}
