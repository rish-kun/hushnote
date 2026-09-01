import Foundation
import Testing
@testable import Hushnote

@Suite("Recording sleep resilience")
struct RecordingSleepResilienceTests {
    @Test("Sleep closes a take and wake resumes on the same media timeline")
    func pipelineRotatesTakeAcrossSleep() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                capture.install(handler, notice: notice)
                return capture
            }
        )

        _ = try await pipeline.start(sessionID: UUID())
        capture.emit(milliseconds: 100, startingAt: 1_000)
        let boundary = try await pipeline.prepareForSleep(at: 10)
        #expect(boundary == 100)
        #expect(!capture.isRunning)

        let omission = try #require(try await pipeline.resumeAfterWake(at: 14.2))
        #expect(omission.reason == .sleep)
        #expect(omission.atMilliseconds == 100)
        #expect(omission.wallDurationMilliseconds == 4_200)

        capture.emit(milliseconds: 100, startingAt: 8_000)
        let artifacts = try await pipeline.stop()
        let takes = artifacts.sourceArtifacts.filter { $0.source == .system }
        #expect(takes.count == 2)
        #expect(takes.map(\.timelineStartMilliseconds) == [0, 100])
        #expect(takes.map(\.durationMilliseconds) == [100, 100])
        #expect(artifacts.durationMilliseconds == 200)
    }

    @Test("Stop while asleep preserves the take already closed")
    func stopWhileSleeping() async throws {
        let directory = CaptureDurationTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = FakeSystemAudioCapture()
        let pipeline = AudioPipeline(
            rootDirectory: directory,
            captureFactory: { handler, notice in
                capture.install(handler, notice: notice)
                return capture
            }
        )

        _ = try await pipeline.start(sessionID: UUID())
        capture.emit(milliseconds: 125)
        _ = try await pipeline.prepareForSleep(at: 10)

        let artifacts = try await pipeline.stop()
        #expect(artifacts.durationMilliseconds == 125)
        #expect(artifacts.sourceArtifacts.count == 1)
        #expect(FileManager.default.fileExists(atPath: artifacts.sourceArtifacts[0].audioURL.path))
    }

    @Test("Power lifecycle prevents idle sleep and reports an honest gap")
    @MainActor
    func lifecycleUsesInjectedEventsAndClocks() async throws {
        let events = FakeRecordingPowerEvents()
        let activity = FakeRecordingSystemActivity()
        let monotonic = LockedValues([10.0, 14.25])
        let wall = LockedValues([
            Date(timeIntervalSinceReferenceDate: 1_000),
            Date(timeIntervalSinceReferenceDate: 1_004.25),
        ])
        let calls = SleepLifecycleCalls()

        let lifecycle = RecordingSleepResilience(
            powerEvents: events,
            activity: activity,
            retryPolicy: .init(delaysSeconds: []),
            monotonicClock: { monotonic.next() },
            wallClock: { wall.next() },
            sleep: { _ in },
            prepare: { instant in
                calls.prepared.append(instant)
                return 640
            },
            resume: { instant in
                calls.resumed.append(instant)
                return CapturedMediaOmission(
                    reason: .sleep,
                    atMilliseconds: 640,
                    wallDurationMilliseconds: 4_250
                )
            },
            onGap: { calls.gaps.append($0) },
            onRecoveryFailure: { _ in calls.failures += 1 }
        )

        lifecycle.start()
        #expect(activity.beginCount == 1)
        events.send(.willSleep)
        try await waitUntil { calls.prepared.count == 1 }
        events.send(.didWake)
        try await waitUntil { calls.gaps.count == 1 }
        lifecycle.stop()

        #expect(calls.prepared == [10])
        #expect(calls.resumed == [14.25])
        #expect(calls.gaps.first?.timelineMilliseconds == 640)
        #expect(calls.gaps.first?.durationMilliseconds == 4_250)
        #expect(calls.failures == 0)
        #expect(activity.endCount == 1)
    }

    @Test("Wake recovery retries only for the configured bound")
    @MainActor
    func wakeRecoveryIsBounded() async throws {
        let events = FakeRecordingPowerEvents()
        let calls = SleepLifecycleCalls()
        let lifecycle = RecordingSleepResilience(
            powerEvents: events,
            activity: FakeRecordingSystemActivity(),
            retryPolicy: .init(delaysSeconds: [0, 0]),
            monotonicClock: { 10 },
            wallClock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            sleep: { _ in },
            prepare: { instant in
                calls.prepared.append(instant)
                return 80
            },
            resume: { _ in
                calls.resumeAttempts += 1
                throw AudioPipelineError.audioCaptureFailed
            },
            onGap: { calls.gaps.append($0) },
            onRecoveryFailure: { _ in calls.failures += 1 }
        )

        lifecycle.start()
        events.send(.willSleep)
        try await waitUntil { calls.prepared.count == 1 }
        events.send(.didWake)
        try await waitUntil { calls.failures == 1 }
        lifecycle.stop()

        #expect(calls.resumeAttempts == 3)
        #expect(calls.gaps.isEmpty)
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the power lifecycle")
    }
}

@MainActor
private final class FakeRecordingPowerEvents: RecordingPowerEventProviding {
    let events: AsyncStream<RecordingPowerEvent>
    private let continuation: AsyncStream<RecordingPowerEvent>.Continuation

    init() {
        let pair = AsyncStream<RecordingPowerEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start() {}
    func stop() {}
    func send(_ event: RecordingPowerEvent) { continuation.yield(event) }
}

@MainActor
private final class FakeRecordingSystemActivity: RecordingSystemActivityManaging {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginRecordingActivity() { beginCount += 1 }
    func endRecordingActivity() { endCount += 1 }
}

@MainActor
private final class SleepLifecycleCalls {
    var prepared: [Double] = []
    var resumed: [Double] = []
    var gaps: [RecordingSleepGap] = []
    var failures = 0
    var resumeAttempts = 0
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]

    init(_ values: [Value]) { self.values = values }

    func next() -> Value {
        lock.withLock { values.removeFirst() }
    }
}
