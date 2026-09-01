import Foundation
import Synchronization
import Testing
@testable import Hushnote

@Suite("Background finalization queue")
struct FinalizationQueueControllerTests {
    private func queuedJob(
        store: MeetingStore,
        title: String = "Queue",
        queuedAt: Date = Date(timeIntervalSince1970: 10),
        duration: Int64 = 60_000
    ) async throws -> FinalizationJob {
        let meeting = Meeting(title: title)
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 1),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: duration,
            state: .captured
        )
        try await store.saveRecordingSession(session)
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: queuedAt,
            audioDurationMilliseconds: duration
        )
        try await store.enqueueFinalizationJob(job)
        return job
    }

    @Test("One claimed job advances durably through progress to ready")
    func completesJob() async throws {
        let store = try MeetingStore(inMemory: ())
        let original = try await queuedJob(store: store)
        let events = QueueEventCollector()
        let processor = SuccessfulQueueProcessor(realtimeFactor: 0.4)
        let controller = FinalizationQueueController(
            store: store,
            processor: processor,
            now: { Date(timeIntervalSince1970: 100) },
            onEvent: { events.append($0) }
        )

        #expect(await controller.runNext() == .completed(original.id))

        let durable = try #require(try await store.finalizationJob(id: original.id))
        #expect(durable.state == .succeeded)
        #expect(durable.progress == 1)
        #expect(durable.attemptCount == 1)
        #expect(durable.realtimeFactor == 0.4)
        #expect((try await store.recordingSession(id: original.sessionID))?.state == .ready)
        #expect(events.values.contains { if case .claimed = $0 { true } else { false } })
        #expect(events.values.contains { if case .updated = $0 { true } else { false } })
        #expect(events.values.contains { if case .succeeded = $0 { true } else { false } })
    }

    @Test("Live capture pauses claims without consuming an attempt")
    func pausesForCapture() async throws {
        let store = try MeetingStore(inMemory: ())
        let original = try await queuedJob(store: store)
        let controller = FinalizationQueueController(store: store, processor: SuccessfulQueueProcessor())
        await controller.setLiveCaptureActive(true)

        #expect(await controller.runNext() == .pausedForLiveCapture)
        let durable = try #require(try await store.finalizationJob(id: original.id))
        #expect(durable.state == .queued)
        #expect(durable.attemptCount == 0)

        await controller.setLiveCaptureActive(false)
        #expect(await controller.runNext() == .completed(original.id))
    }

    @Test("A processing failure preserves a retryable durable job")
    func failureCanRetry() async throws {
        let store = try MeetingStore(inMemory: ())
        let original = try await queuedJob(store: store)
        let controller = FinalizationQueueController(store: store, processor: FailingQueueProcessor())

        #expect(await controller.runNext() == .failed(original.id))
        let failed = try #require(try await store.finalizationJob(id: original.id))
        #expect(failed.state == .failed)
        #expect(failed.errorMessage?.contains("decoder failed") == true)
        #expect((try await store.recordingSession(id: original.sessionID))?.state == .failed)

        let retried = try await controller.retry(jobID: original.id, at: Date(timeIntervalSince1970: 200))
        #expect(retried.state == .queued)
        #expect(retried.attemptCount == 1)
    }

    @Test("The controller admits only one processor at a time and cancellation requeues")
    func oneAtATimeAndCancellation() async throws {
        let store = try MeetingStore(inMemory: ())
        let original = try await queuedJob(store: store)
        let processor = SuspendedQueueProcessor()
        let controller = FinalizationQueueController(store: store, processor: processor)

        let first = Task { await controller.runNext() }
        await processor.waitUntilStarted()
        #expect(await controller.runNext() == .busy)
        first.cancel()
        #expect(await first.value == .cancelled(original.id))

        let durable = try #require(try await store.finalizationJob(id: original.id))
        #expect(durable.state == .queued)
        #expect(durable.attemptCount == 1)
        #expect(durable.errorMessage == nil)
    }

    @Test("ETA uses matching recent factors and returns a range")
    func etaRange() {
        let fallbackSmall = FinalizationETAPolicy.estimate(
            audioDurationMilliseconds: 600_000,
            modelID: "small",
            recentSamples: []
        )
        let fallbackLarge = FinalizationETAPolicy.estimate(
            audioDurationMilliseconds: 600_000,
            modelID: "large-v3",
            recentSamples: []
        )
        #expect(fallbackLarge.lowerBoundSeconds > fallbackSmall.lowerBoundSeconds)
        #expect(fallbackLarge.upperBoundSeconds > fallbackLarge.lowerBoundSeconds)

        let measured = FinalizationETAPolicy.estimate(
            audioDurationMilliseconds: 600_000,
            modelID: "large-v3",
            progress: 0.5,
            recentSamples: [
                FinalizationRuntimeSample(modelID: "small", realtimeFactor: 9),
                FinalizationRuntimeSample(modelID: "large-v3", realtimeFactor: 0.4),
                FinalizationRuntimeSample(modelID: "large-v3", realtimeFactor: 0.5),
                FinalizationRuntimeSample(modelID: "large-v3", realtimeFactor: 0.6)
            ]
        )
        #expect(measured.lowerBoundSeconds == 120)
        #expect(measured.upperBoundSeconds == 180)
    }
}

private final class QueueEventCollector: @unchecked Sendable {
    private let storage = Mutex<[FinalizationQueueEvent]>([])
    var values: [FinalizationQueueEvent] { storage.withLock { $0 } }
    func append(_ event: FinalizationQueueEvent) { storage.withLock { $0.append(event) } }
}

private struct SuccessfulQueueProcessor: FinalizationJobProcessing {
    var realtimeFactor: Double? = nil

    func process(
        job: FinalizationJob,
        report: @escaping FinalizationProgressReporter
    ) async throws -> FinalizationProcessingResult {
        try await report(FinalizationProgressUpdate(state: .transcribing, progress: 0.4))
        try await report(FinalizationProgressUpdate(state: .diarizing, progress: 0.85))
        return FinalizationProcessingResult(realtimeFactor: realtimeFactor)
    }
}

private struct FailingQueueProcessor: FinalizationJobProcessing {
    func process(
        job: FinalizationJob,
        report: @escaping FinalizationProgressReporter
    ) async throws -> FinalizationProcessingResult {
        try await report(FinalizationProgressUpdate(state: .transcribing, progress: 0.2))
        throw QueueProcessorFailure.decoderFailed
    }
}

private enum QueueProcessorFailure: Error, LocalizedError {
    case decoderFailed
    var errorDescription: String? { "decoder failed but audio remains intact" }
}

private actor SuspendedQueueProcessor: FinalizationJobProcessing {
    private var started = false

    func process(
        job: FinalizationJob,
        report: @escaping FinalizationProgressReporter
    ) async throws -> FinalizationProcessingResult {
        started = true
        try await Task.sleep(for: .seconds(60))
        return FinalizationProcessingResult()
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
