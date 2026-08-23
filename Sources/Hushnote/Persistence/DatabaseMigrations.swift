import Foundation
import GRDB

enum HushnoteDatabaseMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_meetings_transcript") { db in
            try db.create(table: "meetings") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("startedAt", .datetime)
                table.column("endedAt", .datetime)
                table.column("updatedAt", .datetime).notNull().indexed()
                table.column("status", .text).notNull().indexed()
                table.column("errorMessage", .text)
                table.column("retainsAudio", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "audioTracks") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text)
                    .notNull()
                    .references("meetings", onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("filePath", .text).notNull()
                table.column("sampleRate", .double).notNull()
                table.column("channelCount", .integer).notNull()
                table.column("durationMilliseconds", .integer).notNull().defaults(to: 0)
                table.column("isComplete", .boolean).notNull().defaults(to: false)
                table.uniqueKey(["meetingID", "source"])
            }
            try db.create(index: "audioTracks_on_meetingID", on: "audioTracks", columns: ["meetingID"])

            try db.create(table: "transcriptSegments") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text)
                    .notNull()
                    .references("meetings", onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("startMilliseconds", .integer).notNull()
                table.column("endMilliseconds", .integer).notNull()
                table.column("text", .text).notNull()
                table.column("wordsJSON", .blob).notNull()
                table.column("speakerID", .text)
                table.column("speakerName", .text)
                table.column("confidence", .double)
                table.column("stability", .text).notNull()
            }
            try db.create(
                index: "transcriptSegments_timeline",
                on: "transcriptSegments",
                columns: ["meetingID", "startMilliseconds", "source"]
            )

            // A standalone FTS table keeps the text index independent of the
            // app's string primary keys. Triggers make every CRUD path atomic.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcriptSegmentFTS USING fts5(
                    segmentID UNINDEXED,
                    meetingID UNINDEXED,
                    text,
                    speakerName,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                CREATE TRIGGER transcriptSegments_fts_insert AFTER INSERT ON transcriptSegments BEGIN
                    INSERT INTO transcriptSegmentFTS(segmentID, meetingID, text, speakerName)
                    VALUES (new.id, new.meetingID, new.text, coalesce(new.speakerName, ''));
                END;

                CREATE TRIGGER transcriptSegments_fts_update AFTER UPDATE ON transcriptSegments BEGIN
                    DELETE FROM transcriptSegmentFTS WHERE segmentID = old.id;
                    INSERT INTO transcriptSegmentFTS(segmentID, meetingID, text, speakerName)
                    VALUES (new.id, new.meetingID, new.text, coalesce(new.speakerName, ''));
                END;

                CREATE TRIGGER transcriptSegments_fts_delete AFTER DELETE ON transcriptSegments BEGIN
                    DELETE FROM transcriptSegmentFTS WHERE segmentID = old.id;
                END;
                """)
        }
        migrator.registerMigration("v2_preserve_transcript_edits") { db in
            try db.alter(table: "transcriptSegments") { table in
                table.add(column: "modelText", .text)
                table.add(column: "isUserEdited", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE transcriptSegments SET modelText = text")
        }
        migrator.registerMigration("v3_insight_history") { db in
            try db.create(table: "insightSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text)
                    .notNull()
                    .references("meetings", onDelete: .cascade)
                table.column("providerID", .text).notNull()
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("payloadJSON", .blob).notNull()
            }
            try db.create(
                index: "insightSnapshots_on_meetingID_createdAt",
                on: "insightSnapshots",
                columns: ["meetingID", "createdAt"]
            )

            try db.create(table: "providerRuns") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text)
                    .notNull()
                    .references("meetings", onDelete: .cascade)
                table.column("providerID", .text).notNull()
                table.column("purpose", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("finishedAt", .datetime)
                table.column("status", .text).notNull().indexed()
                table.column("errorMessage", .text)
            }
            try db.create(
                index: "providerRuns_on_meetingID_startedAt",
                on: "providerRuns",
                columns: ["meetingID", "startedAt"]
            )
        }
        migrator.registerMigration("v4_meeting_notes") { db in
            try db.alter(table: "meetings") { table in
                table.add(column: "notes", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v5_scope_fts_update_trigger") { db in
            // The original trigger fired AFTER UPDATE on *any* column, including
            // modelText, isUserEdited, revision and confidence — none of which the
            // FTS index holds. Because `segmentID` is UNINDEXED, the trigger's
            // `DELETE ... WHERE segmentID = old.id` is a full scan of every segment
            // ever recorded, and each firing rewrites all four FTS5 shadow tables
            // (11 row writes for one logical update). The live loop re-upserts the
            // whole stable prefix roughly once per second, so this dominated write
            // cost during a meeting and made the v2 backfill quadratic.
            try db.execute(sql: """
                DROP TRIGGER IF EXISTS transcriptSegments_fts_update;

                CREATE TRIGGER transcriptSegments_fts_update
                AFTER UPDATE OF id, meetingID, text, speakerName ON transcriptSegments BEGIN
                    DELETE FROM transcriptSegmentFTS WHERE segmentID = old.id;
                    INSERT INTO transcriptSegmentFTS(segmentID, meetingID, text, speakerName)
                    VALUES (new.id, new.meetingID, new.text, coalesce(new.speakerName, ''));
                END;
                """)
        }
        migrator.registerMigration("v6_repair_transcript_pollution") { db in
            try repairTranscriptSegments(db)
        }
        migrator.registerMigration("v7_summary_versions_and_trash") { db in
            try db.alter(table: "meetings") { table in
                table.add(column: "deletedAt", .datetime)
            }
            try db.create(index: "meetings_on_deletedAt", on: "meetings", columns: ["deletedAt"])

            try db.create(table: "summaryVersions") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text)
                    .notNull()
                    .references("meetings", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("text", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("sourceInsightSnapshotID", .text)
                    .references("insightSnapshots", onDelete: .setNull)
            }
            try db.create(
                index: "summaryVersions_on_meetingID_createdAt",
                on: "summaryVersions",
                columns: ["meetingID", "createdAt"]
            )
            try db.alter(table: "meetings") { table in
                table.add(column: "activeSummaryVersionID", .text)
                    .references("summaryVersions", onDelete: .setNull)
            }

            // Existing generated summaries become immutable versions. The
            // newest snapshot remains what the app displays after migration.
            let snapshots = try InsightSnapshotRecord
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
            var latestByMeeting: [String: SummaryVersionRecord] = [:]
            for snapshot in snapshots {
                guard let stored = try? snapshot.model() else { continue }
                let version = SummaryVersion(
                    id: UUID(),
                    meetingID: stored.meetingID,
                    kind: .generated,
                    text: stored.output.insights.overview.text,
                    createdAt: stored.createdAt,
                    sourceInsightSnapshotID: stored.id
                )
                let record = SummaryVersionRecord(version)
                try record.insert(db)
                latestByMeeting[record.meetingID] = record
            }
            for (meetingID, version) in latestByMeeting {
                try MeetingRecord
                    .filter(key: meetingID)
                    .updateAll(db, Column("activeSummaryVersionID").set(to: version.id))
            }
        }
        return migrator
    }

    /// Whisper's control vocabulary leaked into stored transcripts until
    /// `skipSpecialTokens` was set on both `DecodingOptions`. The leak is closed
    /// at the source, but every meeting recorded before then still holds
    /// `<|startoftranscript|>` and the timestamp tokens in `text`, in the
    /// `modelText` the v2 migration backfilled from it, and in the word timings.
    ///
    /// Three things shape this repair.
    ///
    /// Cleaning runs through `WhisperSpecialToken`, never SQL `replace()`:
    /// legitimate speech and dictated code contain `<` and `|`, and only the
    /// real tokeniser rule — an unbroken run of `[A-Za-z0-9._-]` between the
    /// delimiters — tells `<|en|>` apart from "a <| b |> c".
    ///
    /// Rows are selected before they are written, and a row whose repair is a
    /// no-op is never written at all. The v5 FTS trigger's
    /// `DELETE ... WHERE segmentID = old.id` is a full scan of the shadow
    /// tables, so an UPDATE that sweeps the whole table would cost roughly
    /// n² row writes on a long history.
    ///
    /// Each UPDATE names only the columns that actually changed. The v5 trigger
    /// is `AFTER UPDATE OF id, meetingID, text, speakerName`, and SQLite fires
    /// on a column's presence in the SET list rather than on its value changing,
    /// so listing an unchanged `text` beside a repaired `modelText` would
    /// reindex for nothing. `transcriptSegmentFTS` is never touched by hand;
    /// the trigger is what keeps it in step.
    ///
    /// `insightSnapshots.payloadJSON` is deliberately left alone. A summary
    /// built from a polluted transcript is wrong in ways no string edit fixes;
    /// those should be regenerated.
    private static func repairTranscriptSegments(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, text, modelText, wordsJSON, speakerID, speakerName
                FROM transcriptSegments
                WHERE text LIKE '%<|%'
                    OR modelText LIKE '%<|%'
                    OR CAST(wordsJSON AS TEXT) LIKE '%<|%'
                    OR (speakerID IS NOT NULL AND speakerName = 'Speaker ' || speakerID)
                """
        )

        for row in rows {
            var assignments: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []

            let text: String = row["text"]
            let cleanedText = WhisperSpecialToken.cleanedSegmentText(text)
            if cleanedText != text {
                // A segment that was nothing but control tokens is emptied, not
                // deleted: a migration repairs a user's transcript, it does not
                // decide rows out of it.
                assignments.append("text = ?")
                arguments.append(cleanedText)
            }

            if let modelText: String = row["modelText"] {
                let cleanedModelText = WhisperSpecialToken.cleanedSegmentText(modelText)
                if cleanedModelText != modelText {
                    assignments.append("modelText = ?")
                    arguments.append(cleanedModelText)
                }
            }

            if let repairedWords = repairedWordTimings(row["wordsJSON"]) {
                assignments.append("wordsJSON = ?")
                arguments.append(repairedWords)
            }

            if let repairedName = repairedSpeakerName(
                speakerID: row["speakerID"],
                speakerName: row["speakerName"]
            ) {
                assignments.append("speakerName = ?")
                arguments.append(repairedName)
            }

            guard !assignments.isEmpty else { continue }
            arguments.append(row["id"] as String)
            try db.execute(
                sql: """
                    UPDATE transcriptSegments
                    SET \(assignments.joined(separator: ", "))
                    WHERE id = ?
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Word text keeps its leading space, which is how Whisper marks a word
    /// boundary. A word that was nothing but a control token is dropped, matching
    /// what the live and final passes do today — keeping it would leave an empty
    /// row that scrubbing can seek to.
    ///
    /// Returns nil when there is nothing to repair, and also when the payload
    /// cannot be decoded: a migration that throws leaves the app unable to open
    /// its own database, which is far worse than one stale word list.
    private static func repairedWordTimings(_ data: Data) -> Data? {
        guard let words = try? JSONDecoder().decode([TranscriptWord].self, from: data) else {
            return nil
        }

        var repaired: [TranscriptWord] = []
        repaired.reserveCapacity(words.count)
        var changed = false
        for word in words {
            let text = WhisperSpecialToken.cleanedWordText(word.text)
            guard text != word.text else {
                repaired.append(word)
                continue
            }
            changed = true
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var word = word
            word.text = text
            repaired.append(word)
        }

        guard changed else { return nil }
        return try? JSONEncoder().encode(repaired)
    }

    /// Diarization labels clusters, not people: FluidAudio emits "S1", "S2"…,
    /// and the display name interpolated that identifier raw until commit
    /// c7a9e23, so older rows read "Speaker S1".
    ///
    /// The repair is the very function the app applies today, and it only runs
    /// where the stored name is still exactly what the old code produced —
    /// `"Speaker " + speakerID`. Any other name is either the user's own or one
    /// this rule has nothing to say about, and both are left alone. An
    /// identifier that is not a cluster ("local-user") maps to itself, so those
    /// rows fall out on their own.
    private static func repairedSpeakerName(speakerID: String?, speakerName: String?) -> String? {
        guard let speakerID, let speakerName, speakerName == "Speaker \(speakerID)" else {
            return nil
        }
        let display = SpeakerAttributor.displayName(forSpeakerID: speakerID)
        return display == speakerName ? nil : display
    }
}
