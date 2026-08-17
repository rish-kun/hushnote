import Foundation
import GRDB
import XCTest

@testable import Hushnote

/// `skipSpecialTokens` now keeps Whisper's control vocabulary out of new
/// transcripts, but every meeting recorded before the fix still carries
/// `<|startoftranscript|>` and friends in `text`, in the `modelText` the v2
/// migration backfilled, and in the per-word timings. The v6 migration repairs
/// what is already on disk.
///
/// The repair has two hazards worth pinning down. It must not use SQL
/// `replace()`, because legitimate speech containing `<` or `|` would be
/// mangled, and it must not touch rows it has nothing to say about, because the
/// v5 FTS trigger's `DELETE ... WHERE segmentID = old.id` is a full scan of the
/// shadow tables — rewriting every row would be quadratic in a long history.
final class TranscriptRepairMigrationTests: XCTestCase {
    private static let lastMigrationBeforeRepair = "v5_scope_fts_update_trigger"

    /// A database migrated to the state a user upgrading into the repair is in.
    private func preRepairQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try HushnoteDatabaseMigrations.migrator.migrate(
            queue,
            upTo: Self.lastMigrationBeforeRepair
        )
        return queue
    }

    private func runRepair(_ queue: DatabaseQueue) throws {
        try HushnoteDatabaseMigrations.migrator.migrate(queue)
    }

    /// `sqlite3_total_changes` counts rows written by triggers too, and a
    /// `DatabaseQueue` serialises everything onto one connection, so the delta
    /// across a migration is the whole write cost of the repair.
    private func totalChanges(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { $0.totalChangesCount }
    }

    private func insertSegment(
        _ db: Database,
        id: String,
        text: String,
        modelText: String? = nil,
        words: [TranscriptWord] = [],
        speakerID: String? = nil,
        speakerName: String? = nil,
        isUserEdited: Bool = false
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO meetings (id, title, createdAt, startedAt, updatedAt, status, retainsAudio, notes)
                SELECT 'm1', 'Meeting', 0, 0, 0, 'idle', 0, ''
                WHERE NOT EXISTS (SELECT 1 FROM meetings WHERE id = 'm1');
                """
        )
        try db.execute(
            sql: """
                INSERT INTO transcriptSegments
                    (id, meetingID, source, revision, startMilliseconds, endMilliseconds,
                     text, wordsJSON, speakerID, speakerName, confidence, stability,
                     modelText, isUserEdited)
                VALUES (?, 'm1', 'system', 1, 0, 1000, ?, ?, ?, ?, 0.9, 'final', ?, ?);
                """,
            arguments: [
                id,
                text,
                try JSONEncoder().encode(words),
                speakerID,
                speakerName,
                modelText ?? text,
                isUserEdited,
            ]
        )
    }

    private func column(_ queue: DatabaseQueue, _ name: String, of id: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT \(name) FROM transcriptSegments WHERE id = ?",
                arguments: [id]
            )
        }
    }

    private func words(_ queue: DatabaseQueue, of id: String) throws -> [TranscriptWord] {
        let data = try queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT wordsJSON FROM transcriptSegments WHERE id = ?",
                arguments: [id]
            )
        }
        return try JSONDecoder().decode([TranscriptWord].self, from: XCTUnwrap(data))
    }

    private func word(_ id: String, _ text: String) -> TranscriptWord {
        TranscriptWord(id: id, text: text, startMilliseconds: 0, endMilliseconds: 500)
    }

    // MARK: - The pollution itself

    func testPollutedSegmentIsCleanedInTextAndModelText() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(db, id: "s1", text: SpecialTokenFixture.pollutedFirstSegment)
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "text", of: "s1"), "Also, do not touch the releases.")
        XCTAssertEqual(
            try column(queue, "modelText", of: "s1"),
            "Also, do not touch the releases.",
            "modelText holds the same pollution and is what reverting an edit restores"
        )
    }

    /// `modelText` is nullable, and a row written before v2 that was never
    /// backfilled must not crash or silently stop the repair of `text`.
    func testPollutionIsRepairedWhenModelTextIsNull() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(db, id: "s2", text: SpecialTokenFixture.pollutedSecondSegment)
            try db.execute(sql: "UPDATE transcriptSegments SET modelText = NULL WHERE id = 's2'")
        }

        try runRepair(queue)

        XCTAssertEqual(
            try column(queue, "text", of: "s2"),
            "I'll only increase the release patch after it has been merged to me."
        )
        XCTAssertNil(try column(queue, "modelText", of: "s2"))
    }

    /// The user's own text is repaired too. The tokens were never something the
    /// user typed — they are our bug rendered into the box the user was editing
    /// — and repairing `modelText` alone would leave the poison one undo away.
    /// The edit flag itself is untouched, so the row stays the user's.
    func testUserEditedSegmentIsRepairedAndStaysUserEdited() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(
                db,
                id: "s3",
                text: "<|0.00|> Ship the beta on Friday.<|6.88|>",
                modelText: SpecialTokenFixture.pollutedFirstSegment,
                isUserEdited: true
            )
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "text", of: "s3"), "Ship the beta on Friday.")
        XCTAssertEqual(try column(queue, "modelText", of: "s3"), "Also, do not touch the releases.")
        let stillEdited = try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT isUserEdited FROM transcriptSegments WHERE id = 's3'"
            )
        }
        XCTAssertEqual(stillEdited, true, "repairing our own leak must not disown the user's edit")
    }

    func testPollutedWordTimingsAreCleaned() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(
                db,
                id: "s4",
                text: "<|0.00|> Ship it.<|1.00|>",
                words: [
                    word("w0", "<|0.00|>"),
                    word("w1", " Ship"),
                    word("w2", " it.<|1.00|>"),
                ]
            )
        }

        try runRepair(queue)

        let repaired = try words(queue, of: "s4")
        XCTAssertEqual(
            repaired.map(\.text),
            [" Ship", " it."],
            "a word that was nothing but a control token carries no speech"
        )
        XCTAssertEqual(repaired.map(\.id), ["w1", "w2"])
    }

    /// Segment text that is nothing but control tokens is emptied, not deleted.
    /// A migration repairs rows; dropping them would change a user's transcript
    /// out from under them and take any edit history with it.
    func testSegmentOfPureControlTokensIsEmptiedNotDeleted() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(db, id: "s5", text: "<|startoftranscript|><|en|><|nospeech|>")
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "text", of: "s5"), "")
        let survives = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM transcriptSegments WHERE id = 's5'"
            )
        }
        XCTAssertEqual(survives, 1)
    }

    // MARK: - What the repair must not touch

    /// The reason the repair cleans in Swift instead of with SQL `replace()`:
    /// speech and dictated code legitimately contain `<` and `|`.
    func testLegitimateAngleBracketsAndPipesSurviveUntouched() throws {
        let legitimate = "guard x < y | z > 0 else { return } — and a <| b |> c"
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(db, id: "s6", text: legitimate)
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "text", of: "s6"), legitimate)
        XCTAssertEqual(try column(queue, "modelText", of: "s6"), legitimate)
    }

    /// The scope guard. A clean history must cost the migration nothing beyond
    /// its own bookkeeping row — every extra UPDATE drags the v5 trigger's full
    /// scan of the FTS shadow tables along with it.
    func testCleanSegmentsAreNotRewrittenAtAll() throws {
        let control = try preRepairQueue()
        let controlBefore = try totalChanges(control)
        try runRepair(control)
        let bookkeeping = try totalChanges(control) - controlBefore

        let queue = try preRepairQueue()
        try queue.write { db in
            for index in 0..<8 {
                try insertSegment(
                    db,
                    id: "clean\(index)",
                    text: "a perfectly ordinary sentence number \(index)",
                    speakerID: "S1",
                    speakerName: "Speaker 1"
                )
            }
        }
        let before = try totalChanges(queue)
        try runRepair(queue)
        let written = try totalChanges(queue) - before

        XCTAssertEqual(
            written,
            bookkeeping,
            "the repair must write nothing for rows that have nothing wrong with them"
        )
    }

    // MARK: - Search

    func testRepairedTextIsWhatSearchFinds() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(db, id: "s7", text: SpecialTokenFixture.pollutedFirstSegment)
        }

        let leakedBefore = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM transcriptSegmentFTS
                    WHERE transcriptSegmentFTS MATCH 'startoftranscript'
                    """
            )
        }
        XCTAssertEqual(leakedBefore, 1, "the fixture must actually be polluted in the index")

        try runRepair(queue)

        let hits = try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT text FROM transcriptSegmentFTS
                    WHERE transcriptSegmentFTS MATCH 'releases'
                    """
            )
        }
        XCTAssertEqual(hits, ["Also, do not touch the releases."])

        let leakedAfter = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM transcriptSegmentFTS
                    WHERE transcriptSegmentFTS MATCH 'startoftranscript'
                    """
            )
        }
        XCTAssertEqual(leakedAfter, 0, "the v5 trigger must have reindexed the repaired row")
    }

    // MARK: - Stale diarization labels

    /// Diarization labels clusters "S1", "S2"…, and the display name used to
    /// interpolate that identifier raw, so rows written before commit c7a9e23
    /// read "Speaker S1". The repair is the same function the app applies today,
    /// gated on the name still being exactly what the old code produced.
    func testStaleClusterSpeakerLabelIsRepaired() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(
                db,
                id: "s8",
                text: "agenda item one",
                speakerID: "S2",
                speakerName: "Speaker S2"
            )
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "speakerName", of: "s8"), "Speaker 2")
        let indexed = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT speakerName FROM transcriptSegmentFTS WHERE segmentID = 's8'"
            )
        }
        XCTAssertEqual(indexed, ["Speaker 2"], "the label the index holds must be repaired too")
    }

    /// A name the user chose, or one the old code produced for an identifier
    /// that is not a cluster, is not ours to rewrite.
    func testNamedSpeakersAreLeftAlone() throws {
        let queue = try preRepairQueue()
        try queue.write { db in
            try insertSegment(
                db,
                id: "s9",
                text: "agenda item two",
                speakerID: "S3",
                speakerName: "Rhea"
            )
            try insertSegment(
                db,
                id: "s10",
                text: "agenda item three",
                speakerID: "local-user",
                speakerName: "You"
            )
            // The name a rule matching on the "Speaker S" prefix would mangle.
            try insertSegment(
                db,
                id: "s11",
                text: "agenda item four",
                speakerID: "S4",
                speakerName: "Speaker Sarah"
            )
        }

        try runRepair(queue)

        XCTAssertEqual(try column(queue, "speakerName", of: "s9"), "Rhea")
        XCTAssertEqual(try column(queue, "speakerName", of: "s10"), "You")
        XCTAssertEqual(try column(queue, "speakerName", of: "s11"), "Speaker Sarah")
    }
}
