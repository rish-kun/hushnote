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
        return migrator
    }
}
