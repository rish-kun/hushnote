@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// A stand-in for the Core Audio tap. Tests drive it directly, so the pipeline's
/// own rules can be checked without an aggregate device or a privacy grant.
final class FakeSystemAudioCapture: SystemAudioCapturing, @unchecked Sendable {
    enum Call: Equatable {
        case start
        case stop
        case pause
        case resume
    }

    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    private var notice: (@Sendable (CaptureNotice) -> Void)?
    private var _calls: [Call] = []
    private var _isRunning = false

    /// Simulates the real teardown cost: `AudioHardwareDestroyAggregateDevice`
    /// plus `AudioHardwareDestroyProcessTap` take real time.
    var stopCost: TimeInterval = 0
    var startError: Error?
    var resumeError: Error?
    /// Audio the device delivers from inside `resume()`, before the call
    /// returns.
    var emitDuringResumeMilliseconds = 0

    var calls: [Call] { lock.withLock { _calls } }
    var isRunning: Bool { lock.withLock { _isRunning } }

    func install(
        _ handler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
        notice: @escaping @Sendable (CaptureNotice) -> Void
    ) {
        lock.withLock {
            self.handler = handler
            self.notice = notice
        }
    }

    /// Fires the same channel the stall watchdog, the format listener and the
    /// drop accountant use.
    func report(_ notice: CaptureNotice) {
        let handler = lock.withLock { self.notice }
        handler?(notice)
    }

    func start() throws {
        lock.withLock { _calls.append(.start) }
        if let startError { throw startError }
        lock.withLock { _isRunning = true }
    }

    func stop() {
        lock.withLock {
            _calls.append(.stop)
            _isRunning = false
        }
        if stopCost > 0 { Thread.sleep(forTimeInterval: stopCost) }
    }

    func pause() throws {
        lock.withLock {
            _calls.append(.pause)
            _isRunning = false
        }
    }

    func resume() throws {
        lock.withLock { _calls.append(.resume) }
        if let resumeError { throw resumeError }
        lock.withLock { _isRunning = true }
        // The device begins delivering the instant it is started, which is
        // before `resume()` returns to its caller.
        if emitDuringResumeMilliseconds > 0 {
            emit(milliseconds: emitDuringResumeMilliseconds, startingAt: 2_000)
        }
    }

    /// Emits capture-sized 48 kHz buffers the way the HAL's IOProc would.
    /// Delivery is refused while stopped, exactly like a dead IOProc.
    @discardableResult
    func emit(
        milliseconds: Int,
        startingAt presentationSeconds: Double = 1_000,
        amplitude: Float = 0.25,
        evenIfStopped: Bool = false
    ) -> Int {
        let frameRate = 48_000.0
        let framesPerBuffer = 1_024
        let totalFrames = Int((Double(milliseconds) / 1_000 * frameRate).rounded())
        var emitted = 0
        var frame = 0
        while frame < totalFrames {
            let count = min(framesPerBuffer, totalFrames - frame)
            let buffer = Self.buffer(frames: count, amplitude: amplitude)
            let handler = lock.withLock { self.handler }
            guard let handler, isRunning || evenIfStopped else { break }
            handler(buffer, presentationSeconds + Double(frame) / frameRate)
            emitted += count
            frame += count
        }
        return emitted
    }

    static func buffer(frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            samples[index] = amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        return buffer
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioCaptureEvent] = []

    func record(_ event: AudioCaptureEvent) {
        lock.withLock { events.append(event) }
    }

    var drops: [AudioDropReport] {
        lock.withLock {
            events.compactMap { event in
                if case .dropped(let report) = event { return report }
                return nil
            }
        }
    }

    var chunks: [CapturedAudioChunk] {
        lock.withLock {
            events.compactMap { event in
                if case .chunk(let chunk) = event { return chunk }
                return nil
            }
        }
    }

    var sourceHealth: [AudioSourceCaptureHealth] {
        lock.withLock {
            events.compactMap { event in
                if case .sourceHealth(let health) = event { return health }
                return nil
            }
        }
    }

    var transitions: [AudioCaptureTransition] {
        lock.withLock {
            events.compactMap { event in
                if case .transition(let transition) = event { return transition }
                return nil
            }
        }
    }
}

@Suite("System capture reconfiguration")
struct SystemCaptureReconfigurationTests {
    @Test("A device change closes the current take and continues in a new one")
    func deviceChangeRotatesTake() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fleet = FakeCaptureFleet()
        let collector = EventCollector()
        let pipeline = makePipeline(directory: directory, fleet: fleet)
        let watcher = Task { for await event in pipeline.events { collector.record(event) } }
        defer { watcher.cancel() }

        _ = try await pipeline.start(sessionID: UUID())
        fleet[0].emit(milliseconds: 100)
        fleet[0].report(.reconfigure(.deviceChanged, detail: "Built-in Output → AirPods"))
        try await CaptureDurationTests.until { fleet.count == 2 && fleet[1].isRunning }
        fleet[1].emit(milliseconds: 100, startingAt: 9_000)

        let artifacts = try await pipeline.stop()
        let takes = artifacts.sourceArtifacts.filter { $0.source == .system }
        #expect(takes.count == 2)
        #expect(takes.map(\.timelineStartMilliseconds) == [0, 100])
        #expect(artifacts.durationMilliseconds == 200)
        #expect(collector.transitions.first?.kind == .deviceChanged)
        #expect(collector.transitions.first?.timelineMilliseconds == 100)
    }

    @Test("Recovery exhaustion warns without ending the meeting")
    func boundedFailureKeepsMeetingAlive() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fleet = FakeCaptureFleet()
        let collector = EventCollector()
        let pipeline = makePipeline(
            directory: directory,
            fleet: fleet,
            retryDelays: [0, 0, 0],
            failCapturesAfterFirst: true
        )
        let watcher = Task { for await event in pipeline.events { collector.record(event) } }
        defer { watcher.cancel() }

        _ = try await pipeline.start(sessionID: UUID())
        fleet[0].emit(milliseconds: 120)
        fleet[0].report(.reconfigure(.formatChanged, detail: "48000 Hz became 24000 Hz"))
        try await CaptureDurationTests.until {
            collector.sourceHealth.contains { health in
                guard health.source == .system else { return false }
                if case .unavailable = health.state { return true }
                return false
            }
        }

        #expect(fleet.count == 4, "one initial capture plus three bounded attempts")
        #expect(await pipeline.status == .recording)
        let artifacts = try await pipeline.stop()
        #expect(artifacts.durationMilliseconds == 120)
        #expect(collector.transitions.first?.kind == .formatChanged)
    }

    @Test("A notice from the closed take cannot rotate its replacement")
    func staleNoticeIsIgnored() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fleet = FakeCaptureFleet()
        let pipeline = makePipeline(directory: directory, fleet: fleet)

        _ = try await pipeline.start(sessionID: UUID())
        fleet[0].emit(milliseconds: 80)
        fleet[0].report(.reconfigure(.deviceChanged, detail: nil))
        try await CaptureDurationTests.until { fleet.count == 2 && fleet[1].isRunning }
        fleet[0].report(.reconfigure(.formatChanged, detail: "stale"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(fleet.count == 2)
        #expect(fleet[1].isRunning)
        _ = try await pipeline.stop()
    }

    private func makePipeline(
        directory: URL,
        fleet: FakeCaptureFleet,
        retryDelays: [Double] = [0],
        failCapturesAfterFirst: Bool = false
    ) -> AudioPipeline {
        AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                let capture = fleet.next(handler, notice)
                if failCapturesAfterFirst, fleet.count > 1 {
                    capture.startError = AudioPipelineError.audioCaptureFailed
                }
                return capture
            },
            microphoneCaptureFactory: { MicrophoneAudioCapture() },
            reconfigurationRetryDelays: retryDelays,
            reconfigurationSleep: { _ in }
        )
    }
}

/// Hands out one fake per `start()`, so a test can hold on to a previous
/// session's device after the pipeline has moved on.
final class FakeCaptureFleet: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeSystemAudioCapture] = []

    func next(
        _ handler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
        _ notice: @escaping @Sendable (CaptureNotice) -> Void
    ) -> FakeSystemAudioCapture {
        let fake = FakeSystemAudioCapture()
        fake.install(handler, notice: notice)
        lock.withLock { made.append(fake) }
        return fake
    }

    subscript(index: Int) -> FakeSystemAudioCapture {
        lock.withLock { made[index] }
    }

    var count: Int { lock.withLock { made.count } }
}

/// A failure carries no session identity, so a late one from a finished meeting
/// stopped whatever capture happened to be current. Reachable in the ordinary
/// way: a failure fires, the user stops, the user starts the next meeting, and
/// the stale task then kills the brand-new recording with the old message.
@Suite("Failure ownership")
struct CaptureFailureOwnershipTests {
    @Test("A failure from a finished session cannot stop the next one")
    func staleFailureIsIgnored() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fleet = FakeCaptureFleet()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fleet.next(handler, notice)
        }

        _ = try await pipeline.start(sessionID: UUID())
        fleet[0].emit(milliseconds: 200)
        _ = try await pipeline.stop()

        _ = try await pipeline.start(sessionID: UUID())
        fleet[1].emit(milliseconds: 300)

        // The dead session's device finally reports what killed it.
        fleet[0].report(.failure("System audio stopped reaching Hushnote 3.2 s ago."))
        try await Task.sleep(for: .milliseconds(120))

        #expect(await pipeline.status == .recording, "the new meeting is still recording")
        #expect(fleet[1].isRunning, "the new meeting's device must not be torn down")

        fleet[1].emit(milliseconds: 300, startingAt: 1_010)
        let artifacts = try await pipeline.stop()
        #expect(
            abs(artifacts.durationMilliseconds - 600) <= 5,
            "stored \(artifacts.durationMilliseconds) ms; the second meeting recorded 600 ms"
        )
    }

    @Test("A failure from the current session still stops it")
    func currentFailureStillStops() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fleet = FakeCaptureFleet()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fleet.next(handler, notice)
        }

        _ = try await pipeline.start(sessionID: UUID())
        fleet[0].emit(milliseconds: 200)
        fleet[0].report(.failure("the tap died"))

        try await CaptureDurationTests.until { await pipeline.status != .recording }
        #expect(await pipeline.status == .failed("the tap died"))
    }
}

/// `pause()` stops accepting samples before stopping the device. `resume()` did
/// the mirror image of the wrong thing: it started the device first, so
/// anything the HAL delivered before `output.resume()` ran was discarded, and
/// `accumulatedPause` never accounted for it either.
@Suite("Pause and resume")
struct CaptureResumeTests {
    @Test("Audio delivered while resuming is kept")
    func resumeKeepsTheFirstBuffers() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 500)
        try await pipeline.pause()
        // The device delivers 200 ms from inside its own start call, before
        // `resume()` returns.
        fake.emitDuringResumeMilliseconds = 200
        try await pipeline.resume()
        fake.emit(milliseconds: 300, startingAt: 2_001)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 1_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms; 200 ms of it arrived during the resume"
        )
    }

    @Test("A device that refuses to restart leaves the meeting paused")
    func failedResumeRollsBack() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 500)
        try await pipeline.pause()
        fake.resumeError = AudioPipelineError.audioCaptureFailed

        await #expect(throws: AudioPipelineError.audioCaptureFailed) {
            try await pipeline.resume()
        }

        #expect(await pipeline.status == .paused, "a refused restart is still a pause")
        // A straggler from a device that never restarted must not land in a
        // meeting the user believes is paused.
        fake.emit(milliseconds: 300, startingAt: 2_000, evenIfStopped: true)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 500) <= 5,
            "stored \(artifacts.durationMilliseconds) ms; only the first 500 ms was recorded"
        )
    }
}

@Suite("Recorded duration")
struct CaptureDurationTests {
    /// A meeting's stored duration is what the recovery file will report if the
    /// app ever has to reopen it. The two must not be able to disagree.
    @Test("Duration counts the audio actually written, not the wall clock")
    func durationFollowsWrittenFrames() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        let session = UUID()
        _ = try await pipeline.start(sessionID: session)
        let frames = fake.emit(milliseconds: 2_000)
        #expect(frames == 96_000, "fixture should have delivered two seconds of capture")
        let artifacts = try await pipeline.stop()

        let file = try AVAudioFile(forReading: artifacts.systemAudioURL)
        let fileMilliseconds = Int64((Double(file.length) / file.fileFormat.sampleRate * 1_000).rounded())

        #expect(
            abs(artifacts.durationMilliseconds - 2_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for two seconds of audio"
        )
        #expect(
            artifacts.durationMilliseconds == fileMilliseconds,
            "stored \(artifacts.durationMilliseconds) ms but the recovery file reports \(fileMilliseconds) ms"
        )
    }

    /// `capture.stop()` synchronously destroys the aggregate device and the
    /// process tap. None of that is recorded audio.
    @Test("Teardown after the last buffer is not counted as recorded audio")
    func teardownIsNotRecordedAudio() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        fake.stopCost = 0.4
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 1_000)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 1_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for one second of audio plus 400 ms of teardown"
        )
    }

    /// Paused time is not written to the file, so it must not be stored either.
    @Test("A pause does not lengthen the recording")
    func pauseIsExcluded() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 500)
        try await pipeline.pause()
        try await Task.sleep(for: .milliseconds(120))
        try await pipeline.resume()
        fake.emit(milliseconds: 500, startingAt: 1_002)
        let artifacts = try await pipeline.stop()

        #expect(
            abs(artifacts.durationMilliseconds - 1_000) <= 5,
            "stored \(artifacts.durationMilliseconds) ms for one second of audio around a 120 ms pause"
        )
    }

    /// The watchdog and the format listener are only worth having if what they
    /// report actually reaches the meeting.
    @Test("A capture failure stops the session and surfaces the reason")
    func captureFailureStopsTheSession() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 200)
        fake.report(.failure("System audio stopped reaching Hushnote 3.2 s ago."))

        try await Self.until { await pipeline.status != .recording }

        #expect(await pipeline.status == .failed("System audio stopped reaching Hushnote 3.2 s ago."))
        #expect(fake.calls.contains(.stop), "a dead device must not be left running")
    }

    /// Lost audio has to reach the meeting as an event. It cannot stop the
    /// recording — the rest of the meeting is still worth keeping — but it must
    /// not pass silently either.
    @Test("Dropped buffers reach the meeting as an event without stopping it")
    func dropsAreSurfaced() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(rootDirectory: directory) { handler, notice in
            fake.install(handler, notice: notice)
            return fake
        }

        let collector = EventCollector()
        let events = pipeline.events
        let watcher = Task { for await event in events { collector.record(event) } }
        defer { watcher.cancel() }

        _ = try await pipeline.start(sessionID: UUID())
        fake.emit(milliseconds: 100)
        fake.report(.dropped(AudioDropReport(
            backpressureBuffers: 4,
            formatMismatchBuffers: 0,
            droppedFrames: 4_096,
            totalDroppedBuffers: 4
        )))

        try await Self.until { collector.drops.isEmpty == false }

        #expect(collector.drops.first?.backpressureBuffers == 4)
        #expect(collector.drops.first?.droppedFrames == 4_096)
        #expect(await pipeline.status == .recording, "a drop is not a reason to end the meeting")
        _ = try await pipeline.stop()
    }

    static func until(
        _ condition: @Sendable () async -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Suite("Dual-source audio pipeline")
struct DualSourceAudioPipelineTests {
    @Test("System and microphone produce separate aligned originals")
    func capturesSeparateOriginals() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let microphoneHardware = PipelineFakeMicrophoneHardwareSession()
        let microphone = Self.microphoneCapture(hardware: microphoneHardware)
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: { microphone }
        )
        let collector = EventCollector()
        let watcher = Task {
            for await event in pipeline.events { collector.record(event) }
        }
        defer { watcher.cancel() }

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 200, startingAt: 1_000)
        microphoneHardware.emit(milliseconds: 200, startingAt: 1_000.05)
        let artifacts = try await pipeline.stop()

        let systemArtifact = try #require(artifacts.artifact(for: .system))
        let microphoneArtifact = try #require(artifacts.artifact(for: .microphone))
        #expect(systemArtifact.audioURL != microphoneArtifact.audioURL)
        #expect(systemArtifact.durationMilliseconds == 200)
        #expect(microphoneArtifact.durationMilliseconds == 200)
        #expect(microphoneArtifact.deviceUID == "built-in")
        #expect(artifacts.durationMilliseconds == 250)
        let systemFile = try AVAudioFile(forReading: systemArtifact.audioURL)
        let microphoneFile = try AVAudioFile(forReading: microphoneArtifact.audioURL)
        #expect(systemFile.length == 9_600)
        #expect(microphoneFile.length == 9_600)
    }

    @Test("Microphone can be disabled and re-enabled into a fresh take")
    func liveToggleRotatesTakes() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let hardwareFactory = PipelineFakeMicrophoneHardwareFleet()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: hardwareFactory.next())
            }
        )

        _ = try await pipeline.start(sessionID: UUID())
        system.emit(milliseconds: 400, startingAt: 2_000)
        try await pipeline.setMicrophoneCaptureEnabled(true)
        hardwareFactory[0].emit(milliseconds: 100, startingAt: 2_000.1)
        try await pipeline.setMicrophoneCaptureEnabled(false)
        try await pipeline.setMicrophoneCaptureEnabled(true)
        hardwareFactory[1].emit(milliseconds: 100, startingAt: 2_000.3)
        let artifacts = try await pipeline.stop()

        let microphoneTakes = artifacts.sourceArtifacts.filter { $0.source == .microphone }
        #expect(microphoneTakes.count == 2)
        #expect(Set(microphoneTakes.map(\.audioURL)).count == 2)
        #expect(microphoneTakes.map(\.timelineStartMilliseconds) == [400, 500])
    }

    @Test("A denied microphone degrades that source without stopping system audio")
    func permissionFailureIsSourceSpecific() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let microphone = Self.microphoneCapture(
            permission: .denied,
            hardware: PipelineFakeMicrophoneHardwareSession()
        )
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: { microphone }
        )
        let collector = EventCollector()
        let watcher = Task {
            for await event in pipeline.events { collector.record(event) }
        }
        defer { watcher.cancel() }

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 100)
        try await CaptureDurationTests.until {
            collector.sourceHealth.contains { health in
                health.source == .microphone && {
                    if case .unavailable = health.state { return true }
                    return false
                }()
            }
        }
        #expect(await pipeline.status == .recording)
        let artifacts = try await pipeline.stop()
        #expect(artifacts.artifact(for: .system) != nil)
        #expect(artifacts.artifact(for: .microphone) == nil)
    }

    @Test("Disabling during a permission request cannot resurrect a stale take")
    func stalePermissionStartIsDiscarded() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let permission = SuspendedMicrophonePermission()
        let hardware = PipelineFakeMicrophoneHardwareSession()
        let microphone = MicrophoneAudioCapture(
            deviceDiscovery: PipelineFakeMicrophoneDiscovery(),
            permissionAuthorizer: permission,
            sessionFactory: PipelineFakeMicrophoneHardwareFactory(session: hardware)
        )
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: { microphone }
        )
        let collector = EventCollector()
        let watcher = Task {
            for await event in pipeline.events { collector.record(event) }
        }
        defer { watcher.cancel() }

        _ = try await pipeline.start(sessionID: UUID())
        let enabling = Task {
            try await pipeline.setMicrophoneCaptureEnabled(true)
        }
        try await CaptureDurationTests.until { await permission.isWaiting }
        try await pipeline.setMicrophoneCaptureEnabled(false)
        await permission.resolve(true)
        try await enabling.value

        #expect(await pipeline.microphoneTakeIdentifier == nil)
        #expect(!hardware.isRunning)
        let microphoneHealth = collector.sourceHealth.filter { $0.source == .microphone }
        let lastHealthy = microphoneHealth.lastIndex { $0.state == .healthy }
        let lastDisabled = microphoneHealth.lastIndex { $0.state == .disabled }
        #expect(lastDisabled != nil)
        #expect(lastHealthy == nil || lastHealthy! < lastDisabled!)

        let artifacts = try await pipeline.stop()
        #expect(artifacts.artifact(for: .microphone) == nil)
    }

    @Test("A delayed failure from an old take cannot close its replacement")
    func staleTakeFailureIsIgnored() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let hardwareFactory = PipelineFakeMicrophoneHardwareFleet()
        let sessionID = UUID()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: hardwareFactory.next())
            }
        )

        _ = try await pipeline.start(sessionID: sessionID)
        try await pipeline.setMicrophoneCaptureEnabled(true)
        let oldTakeID = try #require(await pipeline.microphoneTakeIdentifier)
        hardwareFactory[0].emit(milliseconds: 100, startingAt: 1_000)
        try await pipeline.setMicrophoneCaptureEnabled(false)
        try await pipeline.setMicrophoneCaptureEnabled(true)
        let replacementTakeID = try #require(await pipeline.microphoneTakeIdentifier)
        #expect(replacementTakeID != oldTakeID)

        await pipeline.microphoneDidFail(
            "the old writer failed late",
            session: sessionID,
            takeID: oldTakeID
        )

        #expect(await pipeline.microphoneTakeIdentifier == replacementTakeID)
        hardwareFactory[1].emit(milliseconds: 100, startingAt: 1_000.2)
        let artifacts = try await pipeline.stop()
        #expect(artifacts.sourceArtifacts.filter { $0.source == .microphone }.count == 2)
    }

    @Test("A microphone pause failure pauses system audio and closes only the microphone")
    func microphonePauseFailureIsSourceSpecific() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let hardware = PipelineFakeMicrophoneHardwareSession()
        hardware.pauseError = MicrophoneCaptureError.notRunning
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: hardware)
            }
        )
        let collector = EventCollector()
        let watcher = Task {
            for await event in pipeline.events { collector.record(event) }
        }
        defer { watcher.cancel() }

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 100)
        hardware.emit(milliseconds: 100, startingAt: 1_000)

        try await pipeline.pause()

        #expect(await pipeline.status == .paused)
        #expect(!system.isRunning)
        #expect(await pipeline.microphoneTakeIdentifier == nil)
        try await CaptureDurationTests.until {
            collector.sourceHealth.contains { health in
                guard health.source == .microphone else { return false }
                if case .unavailable = health.state { return true }
                return false
            }
        }
        #expect(collector.sourceHealth.contains { health in
            guard health.source == .microphone else { return false }
            if case .unavailable = health.state { return true }
            return false
        })
        _ = try await pipeline.stop()
    }

    @Test("Stopping before the first microphone buffer removes the empty take")
    func zeroFrameMicrophoneTakeIsRemoved() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let system = FakeSystemAudioCapture()
        let hardware = PipelineFakeMicrophoneHardwareSession()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: hardware)
            }
        )

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 100)
        let artifacts = try await pipeline.stop()

        #expect(artifacts.artifact(for: .microphone) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: artifacts.directoryURL.path)
        #expect(!names.contains(where: { $0.hasPrefix("microphone-") }))
    }

    @Test("A microphone disconnect rotates only the microphone take")
    func microphoneNoticeRotatesMicOnly() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystemAudioCapture()
        let fleet = PipelineFakeMicrophoneHardwareFleet()
        let collector = EventCollector()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: fleet.next())
            },
            reconfigurationRetryDelays: [0],
            reconfigurationSleep: { _ in }
        )
        let watcher = Task { for await event in pipeline.events { collector.record(event) } }
        defer { watcher.cancel() }

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 200)
        fleet[0].emit(milliseconds: 100, startingAt: 1_000.1)
        fleet[0].report(.reconfigure(.deviceChanged, detail: "unplugged"))
        try await CaptureDurationTests.until { fleet.count == 2 && fleet[1].isRunning }

        #expect(system.isRunning)
        #expect(system.calls.filter { $0 == .stop }.isEmpty)
        #expect(collector.transitions.contains { transition in
            transition.source == .microphone && transition.kind == .deviceChanged
        })
        fleet[1].emit(milliseconds: 100, startingAt: 1_000.3)
        let artifacts = try await pipeline.stop()
        #expect(artifacts.sourceArtifacts.filter { $0.source == .microphone }.count == 2)
        #expect(artifacts.sourceArtifacts.filter { $0.source == .system }.count == 1)
    }

    @Test("Microphone recovery exhaustion leaves system capture recording")
    func microphoneNoticeRecoveryExhaustionIsSourceSpecific() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystemAudioCapture()
        let fleet = PipelineFakeMicrophoneHardwareFleet()
        let collector = EventCollector()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                let hardware = fleet.next()
                if fleet.count > 1 { hardware.startError = MicrophoneCaptureError.notRunning }
                return Self.microphoneCapture(hardware: hardware)
            },
            reconfigurationRetryDelays: [0, 0],
            reconfigurationSleep: { _ in }
        )
        let watcher = Task { for await event in pipeline.events { collector.record(event) } }
        defer { watcher.cancel() }

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        system.emit(milliseconds: 150)
        fleet[0].emit(milliseconds: 100, startingAt: 1_000)
        fleet[0].report(.reconfigure(.deviceChanged, detail: "unplugged"))
        try await CaptureDurationTests.until {
            collector.sourceHealth.contains { health in
                guard health.source == .microphone else { return false }
                if case .unavailable = health.state { return true }
                return false
            }
        }

        #expect(system.isRunning)
        #expect(await pipeline.status == .recording)
        #expect(await pipeline.microphoneTakeIdentifier == nil)
        let artifacts = try await pipeline.stop()
        #expect(artifacts.artifact(for: .system) != nil)
    }

    @Test("A stale microphone notice cannot rotate its replacement")
    func staleMicrophoneNoticeIsIgnored() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystemAudioCapture()
        let fleet = PipelineFakeMicrophoneHardwareFleet()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                system.install(handler, notice: notice)
                return system
            },
            microphoneCaptureFactory: {
                Self.microphoneCapture(hardware: fleet.next())
            },
            reconfigurationRetryDelays: [0],
            reconfigurationSleep: { _ in }
        )

        _ = try await pipeline.start(
            sessionID: UUID(),
            configuration: .init(capturesMicrophone: true)
        )
        fleet[0].report(.reconfigure(.deviceChanged, detail: "unplugged"))
        try await CaptureDurationTests.until { fleet.count == 2 && fleet[1].isRunning }
        fleet[0].report(.reconfigure(.formatChanged, detail: "stale"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(fleet.count == 2)
        #expect(fleet[1].isRunning)
        _ = try await pipeline.stop()
    }

    private static func microphoneCapture(
        permission: MicrophoneAuthorizationStatus = .authorized,
        hardware: PipelineFakeMicrophoneHardwareSession
    ) -> MicrophoneAudioCapture {
        MicrophoneAudioCapture(
            deviceDiscovery: PipelineFakeMicrophoneDiscovery(),
            permissionAuthorizer: PipelineFakeMicrophonePermission(status: permission),
            sessionFactory: PipelineFakeMicrophoneHardwareFactory(session: hardware)
        )
    }
}

private struct PipelineFakeMicrophoneDiscovery: MicrophoneDeviceDiscovering {
    func availableDevices() throws -> [MicrophoneInputDevice] {
        [MicrophoneInputDevice(
            id: "built-in",
            name: "MacBook Microphone",
            isDefault: true,
            audioDeviceID: 7
        )]
    }
}

private struct PipelineFakeMicrophonePermission: MicrophonePermissionAuthorizing {
    let status: MicrophoneAuthorizationStatus

    func authorizationStatus() async -> MicrophoneAuthorizationStatus { status }
    func requestAccess() async -> Bool { status == .authorized }
}

private struct PipelineFakeMicrophoneHardwareFactory: MicrophoneHardwareSessionMaking {
    let session: PipelineFakeMicrophoneHardwareSession

    func makeSession() -> any MicrophoneHardwareSession { session }
}

private final class PipelineFakeMicrophoneHardwareFleet: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [PipelineFakeMicrophoneHardwareSession] = []

    func next() -> PipelineFakeMicrophoneHardwareSession {
        lock.withLock {
            let session = PipelineFakeMicrophoneHardwareSession()
            sessions.append(session)
            return session
        }
    }

    subscript(index: Int) -> PipelineFakeMicrophoneHardwareSession {
        lock.withLock { sessions[index] }
    }

    var count: Int { lock.withLock { sessions.count } }
}

private final class PipelineFakeMicrophoneHardwareSession: MicrophoneHardwareSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MicrophoneSampleHandler?
    private var running = false
    var pauseError: Error?

    var isRunning: Bool { lock.withLock { running } }

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
        if let startError { throw startError }
        lock.withLock {
            handler = sampleHandler
            self.noticeHandler = noticeHandler
            running = true
        }
    }

    func pause() throws {
        if let pauseError { throw pauseError }
        lock.withLock { running = false }
    }
    func resume() throws { lock.withLock { running = true } }
    func stop() { lock.withLock { running = false } }

    func emit(milliseconds: Int, startingAt presentationSeconds: Double) {
        let frames = Int((Double(milliseconds) / 1_000 * 48_000).rounded())
        let callback = lock.withLock { running ? handler : nil }
        callback?(
            FakeSystemAudioCapture.buffer(frames: frames, amplitude: 0.2),
            presentationSeconds
        )
    }

    func report(_ notice: CaptureNotice) {
        let callback = lock.withLock { noticeHandler }
        callback?(notice)
    }

    var startError: Error?

    private var noticeHandler: (@Sendable (CaptureNotice) -> Void)?
}

private actor SuspendedMicrophonePermission: MicrophonePermissionAuthorizing {
    private var continuation: CheckedContinuation<Bool, Never>?

    var isWaiting: Bool { continuation != nil }

    func authorizationStatus() async -> MicrophoneAuthorizationStatus { .notDetermined }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
