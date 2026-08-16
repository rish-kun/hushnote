import Foundation
import GRDB
import XCTest
@testable import Hushnote

/// `transcriptSegmentFTS` is a standalone FTS5 table whose `segmentID` column is
/// UNINDEXED, so the update trigger's `DELETE ... WHERE segmentID = old.id` is a
/// full scan of every segment ever recorded. Firing that on writes which cannot
/// change the indexed text is pure write amplification — and the live loop
/// re-upserts the whole stable prefix roughly once per second.
final class FTSTriggerScopeTests: XCTestCase {
    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try HushnoteDatabaseMigrations.migrator.migrate(queue)
        return queue
    }

    private func insertSegment(_ db: Database, id: String, text: String, speaker: String) throws {
        try db.execute(
            sql: """
                INSERT INTO meetings (id, title, createdAt, startedAt, updatedAt, status, retainsAudio, notes)
                SELECT 'm1', 'Meeting', 0, 0, 0, 'idle', 0, ''
                WHERE NOT EXISTS (SELECT 1 FROM meetings WHERE id = 'm1');

                INSERT INTO transcriptSegments
                    (id, meetingID, source, startMilliseconds, endMilliseconds,
                     text, wordsJSON, speakerName, stability, revision, modelText, isUserEdited)
                VALUES (?, 'm1', 'system', 0, 1000, ?, CAST('[]' AS BLOB), ?, 'final', 1, ?, 0);
                """,
            arguments: [id, text, speaker, text]
        )
    }

    /// `totalChangesCount` includes rows touched by triggers, so the delta over a
    /// single UPDATE tells us exactly whether the FTS delete+reinsert ran:
    /// 1 change means the trigger stayed out of it, 3 means it fired.
    private func changes(_ db: Database, during work: () throws -> Void) rethrows -> Int {
        let before = db.totalChangesCount
        try work()
        return db.totalChangesCount - before
    }

    func testUpdatingOnlyIsUserEditedDoesNotRewriteTheFTSRow() throws {
        let queue = try migratedQueue()

        try queue.write { db in
            try insertSegment(db, id: "s1", text: "quarterly budget review", speaker: "Ari")

            let touched = try changes(db) {
                try db.execute(sql: "UPDATE transcriptSegments SET isUserEdited = 1 WHERE id = 's1'")
            }

            XCTAssertEqual(
                touched, 1,
                "a write that cannot change indexed text must not churn the FTS index"
            )
        }
    }

    func testUpdatingOnlyRevisionDoesNotRewriteTheFTSRow() throws {
        let queue = try migratedQueue()

        try queue.write { db in
            try insertSegment(db, id: "s2", text: "shipping the beta", speaker: "Rhea")

            let touched = try changes(db) {
                try db.execute(sql: "UPDATE transcriptSegments SET revision = 9 WHERE id = 's2'")
            }

            XCTAssertEqual(touched, 1)
        }
    }

    // The scoped trigger must still fire for every column the index actually
    // holds. Omitting one from the OF list would silently leave search stale.

    func testEditingTextStaysSearchable() throws {
        let queue = try migratedQueue()

        try queue.write { db in
            try insertSegment(db, id: "s3", text: "original wording", speaker: "Ari")
            try db.execute(sql: "UPDATE transcriptSegments SET text = 'corrected wording' WHERE id = 's3'")

            let hits = try String.fetchAll(
                db,
                sql: "SELECT text FROM transcriptSegmentFTS WHERE transcriptSegmentFTS MATCH 'corrected'"
            )
            XCTAssertEqual(hits, ["corrected wording"])
        }
    }

    func testRenamingSpeakerStaysSearchable() throws {
        let queue = try migratedQueue()

        try queue.write { db in
            try insertSegment(db, id: "s4", text: "agenda item one", speaker: "Ari")
            try db.execute(sql: "UPDATE transcriptSegments SET speakerName = 'Rhea' WHERE id = 's4'")

            let hits = try String.fetchAll(
                db,
                sql: "SELECT speakerName FROM transcriptSegmentFTS WHERE transcriptSegmentFTS MATCH 'Rhea'"
            )
            XCTAssertEqual(hits, ["Rhea"])
        }
    }
}
