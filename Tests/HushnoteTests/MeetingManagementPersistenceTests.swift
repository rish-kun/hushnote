import Foundation
import GRDB
import XCTest

@testable import Hushnote

final class MeetingManagementPersistenceTests: XCTestCase {
    private static let beforeSummaryVersions = "v6_repair_transcript_pollution"

    private func output(_ summary: String) -> ValidatedMeetingInsights {
        ValidatedMeetingInsights(
            insights: MeetingInsights(
                overview: CitedInsight(id: UUID().uuidString, text: summary, citations: [])
            ),
            validation: InsightValidationReport()
        )
    }

    func testTargetedTitleUpdateTrimsAndPreservesMeetingState() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Original", notes: "Do not overwrite", status: .ready)
        try await store.saveMeeting(meeting)
        let changedAt = Date(timeIntervalSince1970: 12_345)

        try await store.updateMeetingTitle(id: meeting.id, title: "  Renamed meeting  ", at: changedAt)

        let storedMeeting = try await store.meeting(id: meeting.id)
        let fetched = try XCTUnwrap(storedMeeting)
        XCTAssertEqual(fetched.title, "Renamed meeting")
        XCTAssertEqual(fetched.notes, meeting.notes)
        XCTAssertEqual(fetched.status, meeting.status)
        XCTAssertEqual(fetched.updatedAt, changedAt)
        await XCTAssertThrowsErrorAsync {
            try await store.updateMeetingTitle(id: meeting.id, title: " \n ")
        }
        await XCTAssertThrowsErrorAsync {
            try await store.updateMeetingTitle(id: meeting.id, title: String(repeating: "x", count: 201))
        }
    }

    func testManualSummaryPreservesWhitespaceAndHistoryIsPaginated() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Summary versions")
        try await store.saveMeeting(meeting)
        let first = try await store.createSummaryVersion(
            meetingID: meeting.id,
            kind: .manual,
            text: "  First draft\n",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = try await store.createSummaryVersion(
            meetingID: meeting.id,
            kind: .manual,
            text: "Second draft",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let active = try await store.activeSummaryVersion(meetingID: meeting.id)
        let newestPage = try await store.summaryVersions(meetingID: meeting.id, limit: 1)
        let olderPage = try await store.summaryVersions(
            meetingID: meeting.id,
            limit: 10,
            before: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(active, second)
        XCTAssertEqual(newestPage.map(\.id), [second.id])
        XCTAssertEqual(olderPage.map(\.id), [first.id])
        XCTAssertEqual(first.text, "  First draft\n")
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createSummaryVersion(
                meetingID: meeting.id,
                kind: .manual,
                text: " \n "
            )
        }
    }

    func testGeneratedCandidateDoesNotReplaceActiveManualSummary() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Candidate")
        try await store.saveMeeting(meeting)
        let manual = try await store.createSummaryVersion(
            meetingID: meeting.id,
            kind: .manual,
            text: "My summary"
        )

        let saved = try await store.saveGeneratedInsights(
            meetingID: meeting.id,
            providerID: "local",
            output: output("Generated candidate")
        )

        XCTAssertFalse(saved.didActivate)
        XCTAssertEqual(saved.summaryVersion.kind, .generated)
        XCTAssertEqual(saved.summaryVersion.sourceInsightSnapshotID, saved.snapshotID)
        let active = try await store.activeSummaryVersion(meetingID: meeting.id)
        let snapshot = try await store.insightSnapshot(id: saved.snapshotID)
        XCTAssertEqual(active?.id, manual.id)
        XCTAssertEqual(active?.text, manual.text)
        XCTAssertNotNil(snapshot)
    }

    func testManualVersionCanInheritGeneratedStructuredSnapshot() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Inherited detail")
        try await store.saveMeeting(meeting)
        let generated = try await store.saveGeneratedInsights(
            meetingID: meeting.id,
            providerID: "local",
            output: output("Generated overview")
        )

        let manual = try await store.createSummaryVersion(
            meetingID: meeting.id,
            kind: .manual,
            text: "My edited overview",
            sourceInsightSnapshotID: generated.snapshotID
        )

        XCTAssertEqual(manual.sourceInsightSnapshotID, generated.snapshotID)
        let active = try await store.activeSummaryVersion(meetingID: meeting.id)
        XCTAssertEqual(active?.id, manual.id)
        XCTAssertEqual(active?.sourceInsightSnapshotID, generated.snapshotID)
    }

    func testFirstGeneratedSummaryBecomesActive() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "First generated")
        try await store.saveMeeting(meeting)

        let saved = try await store.saveGeneratedInsights(
            meetingID: meeting.id,
            providerID: "local",
            output: output("Generated")
        )

        XCTAssertTrue(saved.didActivate)
        let active = try await store.activeSummaryVersion(meetingID: meeting.id)
        XCTAssertEqual(active?.id, saved.summaryVersion.id)
    }

    func testSoftDeleteRestoreAndThirtyDayListing() async throws {
        let store = try MeetingStore(inMemory: ())
        let recent = Meeting(title: "Recent")
        let expired = Meeting(title: "Expired")
        try await store.saveMeeting(recent)
        try await store.saveMeeting(expired)
        let now = Date(timeIntervalSince1970: 4_000_000)
        try await store.softDeleteMeeting(id: recent.id, at: now.addingTimeInterval(-10))
        try await store.softDeleteMeeting(id: expired.id, at: now.addingTimeInterval(-31 * 24 * 60 * 60))

        let activeAfterDelete = try await store.meetings()
        let recentlyDeleted = try await store.recentlyDeleted(
            since: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        XCTAssertTrue(activeAfterDelete.isEmpty)
        XCTAssertEqual(recentlyDeleted.map(\.id), [recent.id])

        try await store.restoreMeeting(id: recent.id, at: now)
        let activeAfterRestore = try await store.meetings()
        let restored = try await store.meeting(id: recent.id)
        XCTAssertEqual(activeAfterRestore.map(\.id), [recent.id])
        XCTAssertNil(restored?.deletedAt)
    }

    func testPurgeDeletesExpiredMeetingGraphAndAudio() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Expired audio")
        try await store.saveMeeting(meeting)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "system.caf")
        try Data([1, 2, 3]).write(to: audio)
        try await store.saveAudioTrack(MeetingAudioTrack(
            meetingID: meeting.id,
            source: .system,
            fileURL: audio,
            sampleRate: 48_000,
            channelCount: 1
        ))
        try await store.softDeleteMeeting(id: meeting.id, at: Date(timeIntervalSince1970: 10))

        let purged = try await store.purgeDeletedMeetings(olderThan: Date(timeIntervalSince1970: 11))

        XCTAssertEqual(purged, [meeting.id])
        let fetched = try await store.meeting(id: meeting.id)
        XCTAssertNil(fetched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testMigrationBackfillsEverySnapshotAndSelectsNewest() throws {
        let queue = try DatabaseQueue()
        try HushnoteDatabaseMigrations.migrator.migrate(
            queue,
            upTo: Self.beforeSummaryVersions
        )
        let meetingID = UUID()
        let olderID = UUID()
        let newerID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings
                        (id, title, notes, createdAt, updatedAt, status, retainsAudio)
                    VALUES (?, 'Legacy', '', ?, ?, 'ready', 0)
                    """,
                arguments: [meetingID.uuidString, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0)]
            )
            for (id, text, createdAt) in [
                (olderID, "Older", Date(timeIntervalSince1970: 1)),
                (newerID, "Newer", Date(timeIntervalSince1970: 2)),
            ] {
                let payload = try JSONEncoder().encode(output(text))
                try db.execute(
                    sql: """
                        INSERT INTO insightSnapshots (id, meetingID, providerID, createdAt, payloadJSON)
                        VALUES (?, ?, 'local', ?, ?)
                        """,
                    arguments: [id.uuidString, meetingID.uuidString, createdAt, payload]
                )
            }
        }

        try HushnoteDatabaseMigrations.migrator.migrate(queue)

        let rows = try queue.read { db in
            try SummaryVersionRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.text), ["Older", "Newer"])
        XCTAssertEqual(rows.map(\.sourceInsightSnapshotID), [olderID.uuidString, newerID.uuidString])
        let activeID = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT activeSummaryVersionID FROM meetings WHERE id = ?",
                arguments: [meetingID.uuidString]
            )
        }
        XCTAssertEqual(activeID, rows.last?.id)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
