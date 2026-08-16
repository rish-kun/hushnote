import Foundation
import XCTest
@testable import Hushnote

final class PersistenceTests: XCTestCase {
    func testMeetingNotesRoundTripAndUpdatePreservesFormatting() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Weekly sync", notes: "Agenda\n- Launch")
        try await store.saveMeeting(meeting)

        var fetched = try await store.meeting(id: meeting.id)
        XCTAssertEqual(fetched?.notes, "Agenda\n- Launch")

        let updateDate = Date(timeIntervalSince1970: 1_750_000_000)
        let updatedNotes = "  Decisions\n\n- Ship Friday  "
        try await store.updateMeetingNotes(
            id: meeting.id,
            notes: updatedNotes,
            at: updateDate
        )

        fetched = try await store.meeting(id: meeting.id)
        XCTAssertEqual(fetched?.notes, updatedNotes)
        XCTAssertEqual(fetched?.updatedAt, updateDate)
    }

    func testUpdatingNotesForMissingMeetingFails() async throws {
        let store = try MeetingStore(inMemory: ())
        let missingID = UUID()

        do {
            try await store.updateMeetingNotes(id: missingID, notes: "Not saved")
            XCTFail("Expected missing meeting rejection")
        } catch let error as PersistenceError {
            XCTAssertEqual(error, .meetingNotFound(missingID))
        }
    }

    func testRoundTripsMeetingTrackWordsAndRevision() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Design review", status: .recording)
        try await store.saveMeeting(meeting)

        let track = MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: URL(filePath: "/tmp/system.caf"),
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 4_200,
            isComplete: true
        )
        try await store.saveAudioTrack(track)

        let word = TranscriptWord(
            id: "word-1",
            text: "Launch",
            startMilliseconds: 100,
            endMilliseconds: 330,
            confidence: 0.96
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            meetingID: meeting.id,
            source: .system,
            revision: 3,
            startMilliseconds: 100,
            endMilliseconds: 900,
            text: "Launch the private beta",
            words: [word],
            speakerID: "speaker-a",
            speakerName: "Ari",
            confidence: 0.93,
            stability: .stable
        )
        try await store.upsertSegments([segment])

        let fetchedMeeting = try await store.meeting(id: meeting.id)
        let fetchedTracks = try await store.audioTracks(meetingID: meeting.id)
        let fetchedSegment = try await store.segment(id: segment.id)
        XCTAssertEqual(fetchedMeeting?.title, "Design review")
        XCTAssertEqual(fetchedMeeting?.notes, "")
        XCTAssertEqual(fetchedTracks, [track])
        XCTAssertEqual(fetchedSegment, segment)
    }

    func testFTSFollowsInsertsEditsAndSpeakerRenames() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Planning")
        try await store.saveMeeting(meeting)
        var segment = TranscriptSegment(
            id: "s1",
            meetingID: meeting.id,
            source: .microphone,
            revision: 1,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "The nebula milestone ships Friday",
            speakerID: "local",
            stability: .stable
        )
        try await store.upsertSegments([segment])

        var matches = try await store.searchSegments("nebula")
        XCTAssertEqual(matches.map(\.id), ["s1"])
        _ = try await store.renameSpeaker(meetingID: meeting.id, speakerID: "local", to: "Rhea")
        matches = try await store.searchSegments("Rhea")
        XCTAssertEqual(matches.map(\.id), ["s1"])

        segment.revision = 2
        segment.text = "The aurora milestone ships Monday"
        try await store.upsertSegments([segment])
        let oldMatches = try await store.searchSegments("nebula")
        let newMatches = try await store.searchSegments("aurora")
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches.map(\.id), ["s1"])
    }

    func testRecoveryMarksActiveMeetingsInterrupted() async throws {
        let store = try MeetingStore(inMemory: ())
        let recording = Meeting(title: "Recording", status: .recording)
        let finalizing = Meeting(title: "Finalizing", status: .finalizing)
        let ready = Meeting(title: "Ready", status: .ready)
        for meeting in [recording, finalizing, ready] {
            try await store.saveMeeting(meeting)
        }

        let recovered = try await store.recoverInterruptedMeetings()
        let fetchedReady = try await store.meeting(id: ready.id)
        XCTAssertEqual(Set(recovered.map(\.id)), Set([recording.id, finalizing.id]))
        XCTAssertTrue(recovered.allSatisfy { $0.status == .interrupted })
        XCTAssertEqual(fetchedReady?.status, .ready)
    }

    func testDeletionCascadesRowsAndRemovesAudio() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Disposable")
        try await store.saveMeeting(meeting)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appending(path: "microphone.caf")
        try Data([0, 1, 2]).write(to: audioURL)
        let track = MeetingAudioTrack(
            meetingID: meeting.id,
            source: .microphone,
            fileURL: audioURL,
            sampleRate: 48_000,
            channelCount: 1
        )
        try await store.saveAudioTrack(track)
        try await store.upsertSegments([TranscriptSegment(
            id: "delete-me",
            meetingID: meeting.id,
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "ephemeral",
            stability: .final
        )])

        try await store.deleteMeeting(id: meeting.id)
        let fetchedMeeting = try await store.meeting(id: meeting.id)
        let fetchedSegment = try await store.segment(id: "delete-me")
        XCTAssertNil(fetchedMeeting)
        XCTAssertNil(fetchedSegment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRejectsInvalidBatchesWithoutPartiallyWriting() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Atomic write")
        try await store.saveMeeting(meeting)
        let valid = TranscriptSegment(
            id: "valid",
            meetingID: meeting.id,
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "valid"
        )
        let invalid = TranscriptSegment(
            id: "invalid",
            meetingID: meeting.id,
            source: .microphone,
            startMilliseconds: 200,
            endMilliseconds: 100,
            text: "invalid"
        )

        do {
            try await store.upsertSegments([valid, invalid])
            XCTFail("Expected invalid segment rejection")
        } catch let error as PersistenceError {
            guard case .invalidSegment = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }

        let persisted = try await store.segments(meetingID: meeting.id)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testSearchCanBeScopedToOneMeeting() async throws {
        let store = try MeetingStore(inMemory: ())
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        try await store.saveMeeting(first)
        try await store.saveMeeting(second)
        try await store.upsertSegments([TranscriptSegment(
            id: "first-segment",
            meetingID: first.id,
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "shared keyword"
        )])
        try await store.upsertSegments([TranscriptSegment(
            id: "second-segment",
            meetingID: second.id,
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "shared keyword"
        )])

        let all = try await store.searchSegments("shared")
        let scoped = try await store.searchSegments("shared", meetingID: second.id)

        XCTAssertEqual(Set(all.map(\.id)), ["first-segment", "second-segment"])
        XCTAssertEqual(scoped.map(\.id), ["second-segment"])
    }

    func testReplaceTranscriptRemovesOldFTSRowsAndPreservesNewWords() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Final pass")
        try await store.saveMeeting(meeting)
        try await store.upsertSegments([TranscriptSegment(
            id: "draft",
            meetingID: meeting.id,
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "draft comet"
        )])

        let final = TranscriptSegment(
            id: "final",
            meetingID: meeting.id,
            source: .system,
            revision: 4,
            startMilliseconds: 0,
            endMilliseconds: 120,
            text: "final aurora",
            stability: .final
        )
        try await store.replaceTranscript(TranscriptSnapshot(
            meetingID: meeting.id,
            revision: 4,
            segments: [final]
        ))

        let oldMatches = try await store.searchSegments("comet")
        let newMatches = try await store.searchSegments("aurora")
        let segments = try await store.segments(meetingID: meeting.id)
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches, [final])
        XCTAssertEqual(segments, [final])
    }

    func testBlankSearchIsRejected() async throws {
        let store = try MeetingStore(inMemory: ())

        do {
            _ = try await store.searchSegments("  \n\t ")
            XCTFail("Expected blank query rejection")
        } catch let error as PersistenceError {
            XCTAssertEqual(error, .invalidSearchQuery)
        }
    }

    func testReplacingAudioTrackReusesMeetingSourceIdentity() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Recovery")
        try await store.saveMeeting(meeting)
        let partial = MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: URL(filePath: "/tmp/partial.caf"),
            sampleRate: 48_000,
            channelCount: 1
        )
        try await store.saveAudioTrack(partial)
        let complete = MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: URL(filePath: "/tmp/complete.caf"),
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 3_000,
            isComplete: true
        )
        try await store.saveAudioTrack(complete)

        let tracks = try await store.audioTracks(meetingID: meeting.id)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].id, partial.id)
        XCTAssertEqual(tracks[0].fileURL.path, "/tmp/complete.caf")
        XCTAssertTrue(tracks[0].isComplete)
    }

    func testUserEditSurvivesAutomatedUpsertAndFinalReplacement() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Editing")
        try await store.saveMeeting(meeting)
        var segment = TranscriptSegment(
            id: "edited-segment",
            meetingID: meeting.id,
            source: .microphone,
            revision: 1,
            startMilliseconds: 0,
            endMilliseconds: 500,
            text: "machine draft",
            stability: .stable
        )
        try await store.upsertSegments([segment])
        try await store.editSegmentText(id: segment.id, text: "User correction")

        segment.revision = 2
        segment.text = "new machine draft"
        try await store.upsertSegments([segment])
        let afterUpsert = try await store.segment(id: segment.id)
        XCTAssertEqual(afterUpsert?.text, "User correction")

        segment.revision = 3
        segment.text = "final machine text"
        segment.stability = .final
        try await store.replaceTranscript(TranscriptSnapshot(
            meetingID: meeting.id,
            revision: 3,
            segments: [segment]
        ))
        let afterFinal = try await store.segment(id: segment.id)
        XCTAssertEqual(afterFinal?.text, "User correction")
    }

    func testSegmentIDCannotMoveAcrossMeetings() async throws {
        let store = try MeetingStore(inMemory: ())
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        try await store.saveMeeting(first)
        try await store.saveMeeting(second)
        let original = TranscriptSegment(
            id: "shared-id",
            meetingID: first.id,
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: "first"
        )
        try await store.upsertSegments([original])
        var collision = original
        collision.meetingID = second.id

        do {
            try await store.upsertSegments([collision])
            XCTFail("Expected a cross-meeting ID collision to be rejected")
        } catch let error as PersistenceError {
            guard case .invalidSegment = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInsightSnapshotsAndProviderRunsRoundTrip() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Insights")
        try await store.saveMeeting(meeting)
        let citation = EvidenceCitation(
            segmentID: "s1",
            startMilliseconds: 10,
            endMilliseconds: 50,
            quote: "Ship Friday"
        )
        let output = ValidatedMeetingInsights(
            insights: MeetingInsights(
                overview: CitedInsight(id: "overview", text: "A plan", citations: [citation])
            ),
            validation: InsightValidationReport()
        )

        let runID = try await store.beginProviderRun(
            meetingID: meeting.id,
            providerID: "local",
            purpose: "summary"
        )
        _ = try await store.saveInsightSnapshot(
            meetingID: meeting.id,
            providerID: "local",
            output: output
        )
        try await store.finishProviderRun(id: runID, status: .succeeded)

        let snapshots = try await store.insightSnapshots(meetingID: meeting.id)
        let runs = try await store.providerRuns(meetingID: meeting.id)
        XCTAssertEqual(snapshots.map(\.output), [output])
        XCTAssertEqual(runs.map(\.status), [.succeeded])
        XCTAssertNotNil(runs[0].finishedAt)
    }

    func testDeleteAudioFilesAlsoRemovesTrackMetadata() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "No retention")
        try await store.saveMeeting(meeting)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "system.caf")
        try Data([1, 2, 3]).write(to: file)
        try await store.saveAudioTrack(MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: file,
            sampleRate: 48_000,
            channelCount: 1
        ))

        try await store.deleteAudioFiles(meetingID: meeting.id)

        let tracks = try await store.audioTracks(meetingID: meeting.id)
        let fetchedMeeting = try await store.meeting(id: meeting.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertNotNil(fetchedMeeting)
    }
}
