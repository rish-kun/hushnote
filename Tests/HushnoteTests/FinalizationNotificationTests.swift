import Foundation
import Testing
@testable import Hushnote

@Suite("Finalization notifications")
struct FinalizationNotificationTests {
    @Test("Terminal notification keeps the meeting route and action category")
    func notificationContent() {
        let id = UUID()
        let ready = FinalizationNotification(
            meetingID: id,
            title: "Planning is ready",
            body: "Your transcript and summary are ready to review.",
            kind: .ready
        )
        #expect(ready.meetingID == id)
        #expect(ready.categoryIdentifier == UserNotificationCategory.ready)

        let failed = FinalizationNotification(
            meetingID: id,
            title: "Planning needs attention",
            body: "Finalization stopped, but the original recording is safe.",
            kind: .failed
        )
        #expect(failed.categoryIdentifier == UserNotificationCategory.failed)
    }

    @Test("Completion notification bookkeeping is idempotent")
    func notificationBookkeeping() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Planning")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 30_000,
            state: .captured
        )
        try await store.saveRecordingSession(session)
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "small",
            audioDurationMilliseconds: 30_000
        )
        try await store.enqueueFinalizationJob(job)

        var running = try #require(try await store.finalizationJob(id: job.id))
        running.state = .transcribing
        running.startedAt = Date(timeIntervalSince1970: 20)
        try await store.updateFinalizationJob(running)
        running.state = .diarizing
        try await store.updateFinalizationJob(running)
        running.state = .succeeded
        running.progress = 1
        running.realtimeFactor = 0.25
        running.finishedAt = Date(timeIntervalSince1970: 21)
        try await store.updateFinalizationJob(running)

        let first = try await store.markFinalizationNotificationSent(
            id: job.id,
            at: Date(timeIntervalSince1970: 22)
        )
        let second = try await store.markFinalizationNotificationSent(
            id: job.id,
            at: Date(timeIntervalSince1970: 23)
        )
        #expect(first?.completionNotifiedAt == Date(timeIntervalSince1970: 22))
        #expect(second == nil)
        #expect(try await store.finalizationJob(id: job.id)?.completionNotifiedAt == Date(timeIntervalSince1970: 22))
        #expect(try await store.recentCompletedFinalizationJobs().map(\.id) == [job.id])

    }
}
