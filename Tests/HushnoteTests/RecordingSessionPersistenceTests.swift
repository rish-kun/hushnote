import Foundation
import GRDB
import XCTest
@testable import Hushnote

final class RecordingSessionPersistenceTests: XCTestCase {
    func testPauseBoundaryCanBeOpenedThenFinalizedAndLoadedByMeeting() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Pause boundary")
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 1_000),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        var pause = RecordingEvent(
            sessionID: session.id,
            kind: .pause,
            timelineMilliseconds: 42_000,
            wallClockAt: Date(timeIntervalSince1970: 1_042)
        )
        try await store.saveMeeting(meeting)
        try await store.saveRecordingSession(session)
        try await store.saveRecordingEvent(pause)
        let openEvents = try await store.recordingEvents(meetingID: meeting.id)
        XCTAssertNil(openEvents.first?.durationMilliseconds)

        pause.durationMilliseconds = 252_000
        try await store.saveRecordingEvent(pause)

        let sessionEvents = try await store.recordingEvents(sessionID: session.id)
        let meetingEvents = try await store.recordingEvents(meetingID: meeting.id)
        XCTAssertEqual(sessionEvents, [pause])
        XCTAssertEqual(meetingEvents, [pause])
    }

    func testSessionSourceTakeEventAndJobRoundTrip() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Durable capture")
        try await store.saveMeeting(meeting)

        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 1_000),
            wallEndedAt: Date(timeIntervalSince1970: 1_120),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 110_000,
            state: .captured
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .system,
            label: "System Audio",
            isExpected: true
        )
        let take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: URL(filePath: "/tmp/hushnote-session-system-0.caf"),
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 110_000,
            isComplete: true
        )
        let event = RecordingEvent(
            sessionID: session.id,
            sourceID: source.id,
            kind: .formatChanged,
            timelineMilliseconds: 60_000,
            wallClockAt: Date(timeIntervalSince1970: 1_060),
            durationMilliseconds: 350,
            metadata: ["from": "48 kHz", "to": "24 kHz"]
        )
        var job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 1_120),
            audioDurationMilliseconds: 110_000
        )

        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(source)
        try await store.saveAudioTake(take)
        try await store.saveRecordingEvent(event)
        try await store.enqueueFinalizationJob(job)

        let fetchedSession = try await store.recordingSession(id: session.id)
        let sessions = try await store.recordingSessions(meetingID: meeting.id)
        let sources = try await store.sessionAudioSources(sessionID: session.id)
        let sourceTakes = try await store.audioTakes(sourceID: source.id)
        let sessionTakes = try await store.audioTakes(sessionID: session.id)
        let events = try await store.recordingEvents(sessionID: session.id)
        let fetchedJob = try await store.finalizationJob(sessionID: session.id)
        XCTAssertEqual(fetchedSession, session)
        XCTAssertEqual(sessions, [session])
        XCTAssertEqual(sources, [source])
        XCTAssertEqual(sourceTakes, [take])
        XCTAssertEqual(sessionTakes, [take])
        XCTAssertEqual(events, [event])
        XCTAssertEqual(fetchedJob, job)

        job.state = .transcribing
        job.attemptCount = 1
        job.progress = 0.4
        job.startedAt = Date(timeIntervalSince1970: 1_121)
        try await store.updateFinalizationJob(job)
        let updatedJob = try await store.finalizationJob(id: job.id)
        let jobs = try await store.finalizationJobs(meetingID: meeting.id)
        XCTAssertEqual(updatedJob, job)
        XCTAssertEqual(jobs, [job])
    }

    func testTakeIdentityAndParentageAreImmutable() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Take identity")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .microphone
        )
        var take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: URL(filePath: "/tmp/hushnote-microphone-0.caf"),
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1
        )
        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(source)
        try await store.saveAudioTake(take)

        take.durationMilliseconds = 2_000
        take.isComplete = true
        try await store.saveAudioTake(take)
        let updatedTakes = try await store.audioTakes(sourceID: source.id)
        XCTAssertEqual(updatedTakes, [take])

        take.fileURL = URL(filePath: "/tmp/replaced.caf")
        do {
            try await store.saveAudioTake(take)
            XCTFail("Expected immutable take identity to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidAudioTake = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testV10BackfillsLegacyAudioWithoutChangingTranscript() throws {
        let queue = try DatabaseQueue()
        try HushnoteDatabaseMigrations.migrator.migrate(queue, upTo: "v9_meeting_shares")
        let meetingID = UUID()
        let trackID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings
                        (id, title, notes, createdAt, startedAt, endedAt, updatedAt,
                         status, errorMessage, retainsAudio, activeSummaryVersionID,
                         deletedAt, folderID)
                    VALUES (?, 'Legacy capture', '', ?, ?, ?, ?, 'ready', NULL, 1, NULL, NULL, NULL)
                    """,
                arguments: [meetingID.uuidString, createdAt, createdAt, createdAt.addingTimeInterval(10), createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO audioTracks
                        (id, meetingID, source, filePath, sampleRate, channelCount,
                         durationMilliseconds, isComplete)
                    VALUES (?, ?, 'system', '/tmp/legacy-system.caf', 48000, 1, 10000, 1)
                    """,
                arguments: [trackID.uuidString, meetingID.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcriptSegments
                        (id, meetingID, source, revision, startMilliseconds,
                         endMilliseconds, text, modelText, isUserEdited,
                         wordsJSON, speakerID, speakerName, confidence, stability)
                    VALUES ('legacy-segment', ?, 'system', 1, 0, 1000,
                            'Do not rewrite me', 'Do not rewrite me', 0,
                            x'5B5D', NULL, NULL, NULL, 'final')
                    """,
                arguments: [meetingID.uuidString]
            )
        }

        try HushnoteDatabaseMigrations.migrator.migrate(queue)

        try queue.read { db in
            let sessions = try RecordingSessionRecord.fetchAll(db)
            let sources = try SessionAudioSourceRecord.fetchAll(db)
            let takes = try AudioTakeRecord.fetchAll(db)
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(try sessions[0].model().origin, .legacy)
            XCTAssertEqual(try sessions[0].model().capturedDurationMilliseconds, 10_000)
            XCTAssertEqual(sources.count, 1)
            XCTAssertEqual(try sources[0].model().kind, .system)
            XCTAssertEqual(takes.count, 1)
            XCTAssertEqual(takes[0].id, trackID.uuidString)
            XCTAssertEqual(try takes[0].model().fileURL.path, "/tmp/legacy-system.caf")

            let transcript = try SegmentRecord.fetchOne(db, key: "legacy-segment")
            XCTAssertEqual(transcript?.text, "Do not rewrite me")
            XCTAssertEqual(transcript?.revision, 1)
        }
    }

    func testJobClaimIsOldestFirstAtomicAndBlockedDuringCapture() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Queued work")
        try await store.saveMeeting(meeting)
        let firstSession = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 5_000,
            state: .captured
        )
        let secondSession = RecordingSession(
            meetingID: meeting.id,
            ordinal: 1,
            origin: .continued,
            wallStartedAt: Date(timeIntervalSince1970: 20),
            timelineStartMilliseconds: 5_000,
            capturedDurationMilliseconds: 2_000,
            state: .captured
        )
        try await store.saveRecordingSession(firstSession)
        try await store.saveRecordingSession(secondSession)
        let firstJob = FinalizationJob(
            sessionID: firstSession.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 100),
            audioDurationMilliseconds: 5_000
        )
        let secondJob = FinalizationJob(
            sessionID: secondSession.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 200),
            audioDurationMilliseconds: 2_000
        )
        try await store.enqueueFinalizationJob(secondJob)
        try await store.enqueueFinalizationJob(firstJob)

        let blocked = try await store.claimNextFinalizationJob(
            liveCaptureActive: true,
            at: Date(timeIntervalSince1970: 300)
        )
        XCTAssertNil(blocked)

        let claimed = try await store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(claimed?.id, firstJob.id)
        XCTAssertEqual(claimed?.state, .transcribing)
        XCTAssertEqual(claimed?.attemptCount, 1)
        XCTAssertEqual(claimed?.startedAt, Date(timeIntervalSince1970: 300))
        let claimedSession = try await store.recordingSession(id: firstSession.id)
        XCTAssertEqual(claimedSession?.state, .processing)

        async let contenderA = store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 301)
        )
        async let contenderB = store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 302)
        )
        let (resultA, resultB) = try await (contenderA, contenderB)
        let claimedIDs = [resultA?.id, resultB?.id].compactMap { $0 }
        XCTAssertEqual(claimedIDs, [secondJob.id])
    }

    func testFailedJobCanRetryButImpossibleTransitionIsRejected() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Retry")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            state: .captured
        )
        try await store.saveRecordingSession(session)
        var job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 100),
            audioDurationMilliseconds: 1_000
        )
        try await store.enqueueFinalizationJob(job)

        job.state = .succeeded
        do {
            try await store.updateFinalizationJob(job)
            XCTFail("Expected an impossible transition to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidFinalizationJob = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        job.state = .transcribing
        job.startedAt = Date(timeIntervalSince1970: 110)
        job.attemptCount = 1
        try await store.updateFinalizationJob(job)
        job.state = .failed
        job.finishedAt = Date(timeIntervalSince1970: 120)
        job.errorMessage = "decoder stopped"
        try await store.updateFinalizationJob(job)

        let retried = try await store.retryFinalizationJob(
            id: job.id,
            at: Date(timeIntervalSince1970: 130)
        )
        XCTAssertEqual(retried.state, .queued)
        XCTAssertEqual(retried.attemptCount, 1)
        XCTAssertNil(retried.startedAt)
        XCTAssertNil(retried.finishedAt)
        XCTAssertNil(retried.errorMessage)
        let resetSession = try await store.recordingSession(id: session.id)
        XCTAssertEqual(resetSession?.state, .captured)
    }

    func testRelaunchRecoveryInterruptsCaptureAndRequeuesProcessing() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Relaunch")
        try await store.saveMeeting(meeting)
        let capturing = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        let processing = RecordingSession(
            meetingID: meeting.id,
            ordinal: 1,
            origin: .continued,
            wallStartedAt: Date(timeIntervalSince1970: 20),
            timelineStartMilliseconds: 1_000,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        try await store.saveRecordingSession(capturing)
        try await store.saveRecordingSession(processing)
        var job = FinalizationJob(
            sessionID: processing.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 100),
            audioDurationMilliseconds: 1_000
        )
        try await store.enqueueFinalizationJob(job)
        job.state = .transcribing
        job.attemptCount = 1
        job.progress = 0.25
        job.startedAt = Date(timeIntervalSince1970: 110)
        try await store.updateFinalizationJob(job)
        job.state = .diarizing
        job.progress = 0.75
        try await store.updateFinalizationJob(job)

        let report = try await store.recoverInterruptedRecordingWork()

        XCTAssertEqual(report.interruptedSessionIDs, [capturing.id])
        XCTAssertEqual(report.resetProcessingSessionIDs, [processing.id])
        XCTAssertEqual(report.requeuedJobIDs, [job.id])
        let recoveredCapturing = try await store.recordingSession(id: capturing.id)
        let recoveredProcessing = try await store.recordingSession(id: processing.id)
        let recoveredJob = try await store.finalizationJob(id: job.id)
        XCTAssertEqual(recoveredCapturing?.state, .interrupted)
        XCTAssertEqual(recoveredProcessing?.state, .captured)
        XCTAssertEqual(recoveredJob?.state, .queued)
        XCTAssertEqual(recoveredJob?.attemptCount, 1)
        XCTAssertEqual(recoveredJob?.progress, 0)
        XCTAssertNil(recoveredJob?.startedAt)
    }

    func testQueuedFinalizationJobsAreReturnedInFIFOOrderAndSkipDeletedMeetings() async throws {
        let store = try MeetingStore(inMemory: ())
        let olderMeeting = Meeting(title: "Older queued")
        let newerMeeting = Meeting(title: "Newer queued")
        let deletedMeeting = Meeting(title: "Deleted queued")
        try await store.saveMeeting(olderMeeting)
        try await store.saveMeeting(newerMeeting)
        try await store.saveMeeting(deletedMeeting)

        func makeSession(for meeting: Meeting) -> RecordingSession {
            RecordingSession(
                meetingID: meeting.id,
                ordinal: 0,
                origin: .live,
                wallStartedAt: Date(timeIntervalSince1970: 1),
                timelineStartMilliseconds: 0,
                capturedDurationMilliseconds: 1_000,
                state: .captured
            )
        }
        let olderSession = makeSession(for: olderMeeting)
        let newerSession = makeSession(for: newerMeeting)
        let deletedSession = makeSession(for: deletedMeeting)
        try await store.saveRecordingSession(olderSession)
        try await store.saveRecordingSession(newerSession)
        try await store.saveRecordingSession(deletedSession)

        let olderJob = FinalizationJob(
            sessionID: olderSession.id,
            modelID: "base",
            queuedAt: Date(timeIntervalSince1970: 10),
            audioDurationMilliseconds: 1_000
        )
        let newerJob = FinalizationJob(
            sessionID: newerSession.id,
            modelID: "base",
            queuedAt: Date(timeIntervalSince1970: 20),
            audioDurationMilliseconds: 1_000
        )
        let deletedJob = FinalizationJob(
            sessionID: deletedSession.id,
            modelID: "base",
            queuedAt: Date(timeIntervalSince1970: 1),
            audioDurationMilliseconds: 1_000
        )
        try await store.enqueueFinalizationJob(olderJob)
        try await store.enqueueFinalizationJob(newerJob)
        try await store.enqueueFinalizationJob(deletedJob)
        try await store.softDeleteMeeting(id: deletedMeeting.id)

        let queued = try await store.queuedFinalizationJobs()
        XCTAssertEqual(queued.map(\.id), [olderJob.id, newerJob.id])
    }

    func testRunningFinalizationCanBeRequeuedWhenCaptureTakesOwnership() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Capture takes ownership")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        try await store.saveRecordingSession(session)
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "base",
            queuedAt: Date(timeIntervalSince1970: 20),
            audioDurationMilliseconds: 1_000
        )
        try await store.enqueueFinalizationJob(job)
        guard let claimed = try await store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 21)
        ) else {
            XCTFail("Expected the queued job to be claimed")
            return
        }
        let requeued = try await store.requeueRunningFinalizationJob(
            id: claimed.id,
            at: Date(timeIntervalSince1970: 22)
        )

        XCTAssertEqual(requeued.state, .queued)
        XCTAssertEqual(requeued.attemptCount, 1)
        XCTAssertNil(requeued.startedAt)
        let queuedIDs = try await store.queuedFinalizationJobs().map(\.id)
        let requeuedSession = try await store.recordingSession(id: session.id)
        XCTAssertEqual(queuedIDs, [job.id])
        XCTAssertEqual(requeuedSession?.state, .captured)
    }

    func testFailedFinalizationAndSoftDeletionPreserveSourceOriginals() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Recoverable failure")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .system
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appending(path: "system-0.caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: audioURL,
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 1_000,
            isComplete: true
        )
        var job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 20),
            audioDurationMilliseconds: 1_000
        )
        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(source)
        try await store.saveAudioTake(take)
        try await store.enqueueFinalizationJob(job)
        job.state = .transcribing
        job.attemptCount = 1
        job.startedAt = Date(timeIntervalSince1970: 21)
        try await store.updateFinalizationJob(job)
        job.state = .failed
        job.finishedAt = Date(timeIntervalSince1970: 22)
        job.errorMessage = "decoder stopped"
        try await store.updateFinalizationJob(job)

        try await store.softDeleteMeeting(
            id: meeting.id,
            at: Date(timeIntervalSince1970: 30)
        )

        let retainedTakes = try await store.audioTakes(sessionID: session.id)
        let retainedJob = try await store.finalizationJob(id: job.id)
        let deletedMeeting = try await store.meeting(id: meeting.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(retainedTakes, [take])
        XCTAssertEqual(retainedJob?.state, .failed)
        XCTAssertNotNil(deletedMeeting?.deletedAt)
    }

    func testSoftDeletedMeetingJobWaitsUntilRestore() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Deferred while deleted")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 20),
            audioDurationMilliseconds: 1_000
        )
        try await store.saveRecordingSession(session)
        try await store.enqueueFinalizationJob(job)
        try await store.softDeleteMeeting(
            id: meeting.id,
            at: Date(timeIntervalSince1970: 30)
        )

        let whileDeleted = try await store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 40)
        )
        let queuedJob = try await store.finalizationJob(id: job.id)
        XCTAssertNil(whileDeleted)
        XCTAssertEqual(queuedJob?.state, .queued)

        try await store.restoreMeeting(
            id: meeting.id,
            at: Date(timeIntervalSince1970: 50)
        )
        let afterRestore = try await store.claimNextFinalizationJob(
            liveCaptureActive: false,
            at: Date(timeIntervalSince1970: 60)
        )
        XCTAssertEqual(afterRestore?.id, job.id)
        XCTAssertEqual(afterRestore?.state, .transcribing)
    }

    func testRetentionCleanupRemovesLegacyAndSessionTakeMetadataTogether() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Transcript only")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 2_000,
            state: .captured
        )
        let system = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .system
        )
        let microphone = SessionAudioSource(
            sessionID: session.id,
            ordinal: 1,
            kind: .microphone
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appending(path: "system-0.caf")
        let microphoneURL = directory.appending(path: "microphone-0.caf")
        try Data([1]).write(to: systemURL)
        try Data([2]).write(to: microphoneURL)
        let systemTake = AudioTake(
            sourceID: system.id,
            ordinal: 0,
            fileURL: systemURL,
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 2_000,
            isComplete: true
        )
        let microphoneTake = AudioTake(
            sourceID: microphone.id,
            ordinal: 0,
            fileURL: microphoneURL,
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 2_000,
            isComplete: true
        )
        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(system)
        try await store.saveSessionAudioSource(microphone)
        try await store.saveAudioTake(systemTake)
        try await store.saveAudioTake(microphoneTake)
        // A migrated recording points both compatibility generations at the
        // same system file. Cleanup must deduplicate this path.
        try await store.saveAudioTrack(MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: systemURL,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 2_000,
            isComplete: true
        ))

        try await store.deleteAudioFiles(meetingID: meeting.id)

        let remainingLegacyTracks = try await store.audioTracks(meetingID: meeting.id)
        let remainingTakes = try await store.audioTakes(sessionID: session.id)
        let remainingSources = try await store.sessionAudioSources(sessionID: session.id)
        let retainedSession = try await store.recordingSession(id: session.id)
        let retainedMeeting = try await store.meeting(id: meeting.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(remainingLegacyTracks.isEmpty)
        XCTAssertTrue(remainingTakes.isEmpty)
        XCTAssertEqual(remainingSources.count, 2)
        XCTAssertNotNil(retainedSession)
        XCTAssertNotNil(retainedMeeting)
    }

    func testRetentionCleanupKeepsMetadataWhenFileRemovalFails() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Retry cleanup")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .ready
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .microphone
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let audioURL = directory.appending(path: "microphone-0.caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: audioURL,
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 1_000,
            isComplete: true
        )
        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(source)
        try await store.saveAudioTake(take)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )

        do {
            try await store.deleteAudioFiles(meetingID: meeting.id)
            XCTFail("Expected read-only directory to reject audio removal")
        } catch {
            // The filesystem failure is the behavior under test.
        }

        let retainedTakes = try await store.audioTakes(sessionID: session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(retainedTakes, [take])
    }

    func testPurgeRemovesNewTakeFilesAndCascadesSessionGraph() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Expired source originals")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 10),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .microphone
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appending(path: "microphone-0.caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: audioURL,
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 1_000,
            isComplete: true
        )
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            queuedAt: Date(timeIntervalSince1970: 20),
            audioDurationMilliseconds: 1_000
        )
        try await store.saveRecordingSession(session)
        try await store.saveSessionAudioSource(source)
        try await store.saveAudioTake(take)
        try await store.enqueueFinalizationJob(job)
        try await store.softDeleteMeeting(
            id: meeting.id,
            at: Date(timeIntervalSince1970: 30)
        )

        let purged = try await store.purgeDeletedMeetings(
            olderThan: Date(timeIntervalSince1970: 31)
        )

        let deletedMeeting = try await store.meeting(id: meeting.id)
        let deletedSession = try await store.recordingSession(id: session.id)
        let deletedJob = try await store.finalizationJob(id: job.id)
        XCTAssertEqual(purged, [meeting.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNil(deletedMeeting)
        XCTAssertNil(deletedSession)
        XCTAssertNil(deletedJob)
    }
}
