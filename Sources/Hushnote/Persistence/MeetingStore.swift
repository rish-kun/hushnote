import Foundation
import GRDB

/// The single persistence boundary for meeting metadata and revision-aware
/// transcript state. Writes are serialized by GRDB and grouped transactionally.
public actor MeetingStore {
    private let database: any DatabaseWriter

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let database = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try HushnoteDatabaseMigrations.migrator.migrate(database)
        self.database = database
    }

    public init(inMemory: Void = ()) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let database = try DatabaseQueue(configuration: configuration)
        try HushnoteDatabaseMigrations.migrator.migrate(database)
        self.database = database
    }

    public func saveMeeting(_ meeting: Meeting) throws {
        try database.write { db in
            if let folderID = meeting.folderID {
                try Self.requireActiveFolder(folderID, in: db)
            }
            try MeetingRecord(meeting).save(db)
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        try database.read { db in
            try MeetingRecord.fetchOne(db, key: id.uuidString)?.model()
        }
    }

    public func meetings(limit: Int? = nil) throws -> [Meeting] {
        try database.read { db in
            var request = MeetingRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("updatedAt").desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.model() }
        }
    }

    /// Active meetings in one folder. Passing no folder is intentionally not
    /// supported here: `meetings()` is the global list and `unfiledMeetings()`
    /// names the null-folder query at its call site.
    public func meetings(inFolder folderID: UUID, limit: Int? = nil) throws -> [Meeting] {
        try database.read { db in
            var request = MeetingRecord
                .filter(Column("deletedAt") == nil)
                .filter(Column("folderID") == folderID.uuidString)
                .order(Column("updatedAt").desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.model() }
        }
    }

    public func unfiledMeetings(limit: Int? = nil) throws -> [Meeting] {
        try database.read { db in
            var request = MeetingRecord
                .filter(Column("deletedAt") == nil)
                .filter(Column("folderID") == nil)
                .order(Column("updatedAt").desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.model() }
        }
    }

    /// Fetches several folder lists in one read transaction. Empty folders are
    /// represented with an empty array so callers can render every requested
    /// folder without joining their result back to the input themselves.
    public func meetings(inFolders folderIDs: Set<UUID>) throws -> [UUID: [Meeting]] {
        guard !folderIDs.isEmpty else { return [:] }
        return try database.read { db in
            let ids = folderIDs.map(\.uuidString)
            let records = try MeetingRecord
                .filter(Column("deletedAt") == nil)
                .filter(ids.contains(Column("folderID")))
                .order(Column("folderID"), Column("updatedAt").desc)
                .fetchAll(db)
            var grouped = Dictionary(uniqueKeysWithValues: folderIDs.map { ($0, [Meeting]()) })
            for record in records {
                let meeting = try record.model()
                if let folderID = meeting.folderID { grouped[folderID, default: []].append(meeting) }
            }
            return grouped
        }
    }

    // MARK: - Meeting folders

    public func meetingFolder(id: UUID, includeDeleted: Bool = false) throws -> MeetingFolder? {
        try database.read { db in
            var request = MeetingFolderRecord.filter(key: id.uuidString)
            if !includeDeleted { request = request.filter(Column("deletedAt") == nil) }
            return try request.fetchOne(db)?.model()
        }
    }

    /// Active folders in durable alphabetical order. The normal form is used
    /// for sorting too, so names with accents do not jump to a separate group.
    public func meetingFolders(includeDeleted: Bool = false) throws -> [MeetingFolder] {
        try database.read { db in
            var request = MeetingFolderRecord.order(Column("normalizedName"), Column("id"))
            if !includeDeleted { request = request.filter(Column("deletedAt") == nil) }
            return try request.fetchAll(db).map { try $0.model() }
        }
    }

    @discardableResult
    public func createMeetingFolder(
        name: String,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> MeetingFolder {
        let name = try Self.validatedFolderName(name)
        let normalizedName = Self.normalizedFolderName(name)
        let folder = MeetingFolder(id: id, name: name, createdAt: date, updatedAt: date)
        try database.write { db in
            guard try MeetingFolderRecord
                .filter(Column("normalizedName") == normalizedName)
                .fetchOne(db) == nil
            else {
                throw PersistenceError.duplicateFolderName(name)
            }
            try MeetingFolderRecord(folder, normalizedName: normalizedName).insert(db)
        }
        return folder
    }

    public func renameMeetingFolder(
        id: UUID,
        name: String,
        at date: Date = Date()
    ) throws {
        let name = try Self.validatedFolderName(name)
        let normalizedName = Self.normalizedFolderName(name)
        try database.write { db in
            guard try MeetingFolderRecord
                .filter(key: id.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db) != nil
            else { throw PersistenceError.folderNotFound(id) }
            guard try MeetingFolderRecord
                .filter(Column("normalizedName") == normalizedName)
                .filter(Column("id") != id.uuidString)
                .fetchOne(db) == nil
            else { throw PersistenceError.duplicateFolderName(name) }
            _ = try MeetingFolderRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("name").set(to: name),
                    Column("normalizedName").set(to: normalizedName),
                    Column("updatedAt").set(to: date)
                )
        }
    }

    /// Deletion is intentionally folder-only: every associated meeting remains
    /// in the database and becomes Unfiled, including meetings in the trash.
    public func deleteMeetingFolder(id: UUID, at date: Date = Date()) throws {
        try database.write { db in
            let changed = try MeetingFolderRecord
                .filter(key: id.uuidString)
                .filter(Column("deletedAt") == nil)
                .updateAll(
                    db,
                    Column("deletedAt").set(to: date),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.folderNotFound(id) }
            // Do not touch `updatedAt`: moving organizational metadata must not
            // reorder a meeting, and deletion is a bulk move to Unfiled.
            _ = try MeetingRecord
                .filter(Column("folderID") == id.uuidString)
                .updateAll(db, Column("folderID").set(to: nil))
        }
    }

    public func restoreMeetingFolder(id: UUID, at date: Date = Date()) throws {
        try database.write { db in
            let changed = try MeetingFolderRecord
                .filter(key: id.uuidString)
                .filter(Column("deletedAt") != nil)
                .updateAll(
                    db,
                    Column("deletedAt").set(to: nil),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.folderNotFound(id) }
        }
    }

    /// Updates exactly the association. It deliberately does not change a
    /// meeting's `updatedAt`, so this is safe while recording and stable in
    /// chronological lists.
    public func moveMeeting(id: UUID, toFolder folderID: UUID?) throws {
        try database.write { db in
            if let folderID { try Self.requireActiveFolder(folderID, in: db) }
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .updateAll(db, Column("folderID").set(to: folderID?.uuidString))
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    /// Counts only active meetings. Unlike a SQL join, this also produces a
    /// zero for each requested empty folder.
    public func meetingFolderCounts(folderIDs: Set<UUID>? = nil) throws -> [MeetingFolderCount] {
        try database.read { db in
            var requested = MeetingFolderRecord.filter(Column("deletedAt") == nil)
            if let folderIDs {
                guard !folderIDs.isEmpty else { return [] }
                requested = requested.filter(folderIDs.map(\.uuidString).contains(Column("id")))
            }
            let folders = try requested.order(Column("normalizedName"), Column("id")).fetchAll(db)
            guard !folders.isEmpty else { return [] }
            let ids = folders.map(\.id)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT folderID, COUNT(*) AS meetingCount
                    FROM meetings
                    WHERE deletedAt IS NULL AND folderID IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                    GROUP BY folderID
                    """,
                arguments: StatementArguments(ids)
            )
            let counts = Dictionary(uniqueKeysWithValues: rows.map {
                (($0["folderID"] as String), ($0["meetingCount"] as Int))
            })
            return try folders.map { record in
                guard let id = UUID(uuidString: record.id) else {
                    throw PersistenceError.corruptRecord("meeting folder \(record.id)")
                }
                return MeetingFolderCount(folderID: id, meetingCount: counts[record.id, default: 0])
            }
        }
    }

    public func unfiledMeetingCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM meetings WHERE deletedAt IS NULL AND folderID IS NULL"
            ) ?? 0
        }
    }

    public func recentlyDeleted(
        since date: Date = Date().addingTimeInterval(-30 * 24 * 60 * 60),
        limit: Int? = nil
    ) throws -> [Meeting] {
        try database.read { db in
            var request = MeetingRecord
                .filter(Column("deletedAt") != nil)
                .filter(Column("deletedAt") >= date)
                .order(Column("deletedAt").desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.model() }
        }
    }

    public func updateMeetingTitle(
        id: UUID,
        title: String,
        at date: Date = Date()
    ) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw PersistenceError.invalidMeetingTitle("Enter at least one non-whitespace character.")
        }
        guard cleaned.count <= 200 else {
            throw PersistenceError.invalidMeetingTitle("Use 200 characters or fewer.")
        }
        try database.write { db in
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("title").set(to: cleaned),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    public func updateMeetingStatus(
        id: UUID,
        status: MeetingStatus,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) throws {
        try database.write { db in
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("status").set(to: status.rawValue),
                    Column("errorMessage").set(to: errorMessage),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    /// Saves the user's free-form notes independently from transcript and
    /// insight generation. Whitespace is preserved because notes are authored
    /// content, including intentional indentation and blank lines.
    public func updateMeetingNotes(
        id: UUID,
        notes: String,
        at date: Date = Date()
    ) throws {
        try database.write { db in
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("notes").set(to: notes),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    func meetingShare(meetingID: UUID) throws -> MeetingShare? {
        try database.read { db in
            try MeetingShareRecord.fetchOne(db, key: meetingID.uuidString)?.model()
        }
    }

    /// Everything this Mac has ever published and not revoked, newest first.
    /// There is no web dashboard, so this list is the only place shares can be
    /// managed.
    func allMeetingShares() throws -> [MeetingShare] {
        try database.read { db in
            try MeetingShareRecord
                .order(Column("createdAt").desc, Column("shareID"))
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    /// Writes the share row and nothing else. It deliberately does not touch
    /// `meetings.updatedAt`: the library is ordered by it, and publishing or
    /// syncing a meeting is not a reason to move it to the top — the same rule
    /// `moveMeeting` and `deleteMeetingFolder` follow. Nothing here writes
    /// `transcriptSegments` either, so a sync cannot fire the v5 FTS trigger.
    func upsertMeetingShare(_ share: MeetingShare) throws {
        try database.write { db in
            guard try MeetingRecord.exists(db, key: share.meetingID.uuidString) else {
                throw PersistenceError.meetingNotFound(share.meetingID)
            }
            try MeetingShareRecord(share).save(db)
        }
    }

    /// Forgets the local record of a share. Revocation is a network act and
    /// happens first; this is what runs after it succeeds. Deleting a row that
    /// is not there is not an error — a revoke retried after a partial failure
    /// must be able to finish.
    func deleteMeetingShare(meetingID: UUID) throws {
        _ = try database.write { db in
            try MeetingShareRecord.deleteOne(db, key: meetingID.uuidString)
        }
    }

    public func saveAudioTrack(_ track: MeetingAudioTrack) throws {
        try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: track.meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(track.meetingID)
            }
            var record = AudioTrackRecord(track)
            if let existing = try AudioTrackRecord
                .filter(Column("meetingID") == track.meetingID.uuidString)
                .filter(Column("source") == track.source.rawValue)
                .fetchOne(db) {
                record.id = existing.id
            }
            try record.save(db)
        }
    }

    public func audioTracks(meetingID: UUID) throws -> [MeetingAudioTrack] {
        try database.read { db in
            try AudioTrackRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .order(Column("source"))
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func upsertSegments(_ segments: [TranscriptSegment]) throws {
        guard !segments.isEmpty else { return }
        let meetingID = segments[0].meetingID
        guard segments.allSatisfy({ $0.meetingID == meetingID }) else {
            throw PersistenceError.invalidSegment("one write cannot span multiple meetings")
        }
        try validate(segments)

        try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            for segment in segments {
                let existing = try SegmentRecord.fetchOne(db, key: segment.id)
                if let existing, existing.meetingID != meetingID.uuidString {
                    throw PersistenceError.invalidSegment(
                        "ID \(segment.id) already belongs to another meeting"
                    )
                }
                if let existing, segment.revision < existing.revision {
                    throw PersistenceError.invalidSegment(
                        "revision for \(segment.id) moved backwards"
                    )
                }
                var record = try SegmentRecord(
                    segment,
                    modelText: segment.text,
                    isUserEdited: existing?.isUserEdited ?? false
                )
                if existing?.isUserEdited == true { record.text = existing!.text }
                // `save` updates every column, and SQLite fires `UPDATE OF` on a
                // column's presence in the SET list rather than on its value
                // changing — so an unchanged row still ran the v5 trigger, whose
                // delete scans the whole FTS content table. `updateChanges`
                // compares against the row already fetched above and issues
                // nothing at all when the two agree.
                if let existing {
                    try record.updateChanges(db, from: existing)
                } else {
                    try record.insert(db)
                }
            }
        }
    }

    /// Atomically replaces one meeting's transcript after the final ASR pass.
    ///
    /// User corrections cannot be carried over by segment ID. The final pass
    /// mints its own identifiers and re-runs VAD, so neither the ID nor the
    /// segment boundaries match the live transcript the user was editing. Each
    /// correction is therefore re-keyed onto the incoming segment it overlaps
    /// most, and an edit that matches nothing is kept rather than deleted.
    @discardableResult
    public func replaceTranscript(_ snapshot: TranscriptSnapshot) throws -> TranscriptReplacementReport {
        try validate(snapshot.segments)
        guard snapshot.segments.allSatisfy({ $0.meetingID == snapshot.meetingID }) else {
            throw PersistenceError.invalidSegment("snapshot meeting IDs do not match")
        }
        return try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: snapshot.meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(snapshot.meetingID)
            }
            let existingRecords = try SegmentRecord
                .filter(Column("meetingID") == snapshot.meetingID.uuidString)
                .fetchAll(db)
            let edits = existingRecords.filter(\.isUserEdited)
            let matches = Self.matchEdits(edits, to: snapshot.segments)
            try SegmentRecord.filter(Column("meetingID") == snapshot.meetingID.uuidString).deleteAll(db)

            var preserved: [PreservedUserEdit] = []
            var usedIDs = Set(snapshot.segments.map(\.id))
            for segment in snapshot.segments {
                let edit = matches[segment.id]
                var record = try SegmentRecord(
                    segment,
                    modelText: segment.text,
                    isUserEdited: edit != nil
                )
                if let edit {
                    record.text = edit.text
                    preserved.append(PreservedUserEdit(
                        previousSegmentID: edit.id,
                        segmentID: segment.id,
                        text: edit.text
                    ))
                }
                try record.insert(db)
            }

            // An edit with nowhere to go is authored content, so the row stays.
            // Losing it silently is worse than a transcript that briefly holds
            // one segment the newest ASR pass no longer agrees with.
            let matchedEditIDs = Set(matches.values.map(\.id))
            var orphaned: [TranscriptSegment] = []
            for edit in edits where !matchedEditIDs.contains(edit.id) {
                var record = edit
                record.revision = max(record.revision, snapshot.revision)
                record.id = Self.availableID(basedOn: edit.id, taken: &usedIDs)
                try record.insert(db)
                orphaned.append(try record.model())
            }
            return TranscriptReplacementReport(preserved: preserved, orphaned: orphaned)
        }
    }

    /// Greedy one-to-one assignment of corrections to incoming segments, best
    /// overlap first, so a correction is never duplicated across a split.
    private static func matchEdits(
        _ edits: [SegmentRecord],
        to segments: [TranscriptSegment]
    ) -> [String: SegmentRecord] {
        struct Candidate {
            let editIndex: Int
            let segmentIndex: Int
            let ratio: Double
            let overlap: Int64
            let centerDistance: Int64
        }

        var candidates: [Candidate] = []
        for (editIndex, edit) in edits.enumerated() {
            for (segmentIndex, segment) in segments.enumerated()
            where edit.source == segment.source.rawValue {
                let overlap = max(
                    0,
                    min(edit.endMilliseconds, segment.endMilliseconds)
                        - max(edit.startMilliseconds, segment.startMilliseconds)
                )
                let editDuration = edit.endMilliseconds - edit.startMilliseconds
                let segmentDuration = segment.endMilliseconds - segment.startMilliseconds
                let shortest = min(editDuration, segmentDuration)
                let ratio: Double
                if shortest <= 0 {
                    // Zero-duration segments are legal, so fall back to
                    // containment: a point inside the range still matches.
                    let contained = edit.startMilliseconds >= segment.startMilliseconds
                        && edit.startMilliseconds <= segment.endMilliseconds
                    ratio = contained ? 1 : 0
                } else {
                    ratio = Double(overlap) / Double(shortest)
                }
                guard ratio >= minimumEditOverlapRatio else { continue }
                let editCenter = edit.startMilliseconds + editDuration / 2
                let segmentCenter = segment.startMilliseconds + segmentDuration / 2
                candidates.append(Candidate(
                    editIndex: editIndex,
                    segmentIndex: segmentIndex,
                    ratio: ratio,
                    overlap: overlap,
                    centerDistance: abs(editCenter - segmentCenter)
                ))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.ratio != rhs.ratio { return lhs.ratio > rhs.ratio }
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.centerDistance != rhs.centerDistance {
                return lhs.centerDistance < rhs.centerDistance
            }
            if lhs.segmentIndex != rhs.segmentIndex { return lhs.segmentIndex < rhs.segmentIndex }
            return lhs.editIndex < rhs.editIndex
        }

        var matches: [String: SegmentRecord] = [:]
        var claimedEdits = Set<Int>()
        for candidate in candidates {
            guard !claimedEdits.contains(candidate.editIndex) else { continue }
            let segment = segments[candidate.segmentIndex]
            guard matches[segment.id] == nil else { continue }
            matches[segment.id] = edits[candidate.editIndex]
            claimedEdits.insert(candidate.editIndex)
        }
        return matches
    }

    /// A retained edit must not collide with the incoming transcript, whose
    /// identifiers are deterministic and can repeat across finalization attempts.
    private static func availableID(basedOn id: String, taken: inout Set<String>) -> String {
        var candidate = id
        var suffix = 1
        while taken.contains(candidate) {
            candidate = "\(id)-kept-\(suffix)"
            suffix += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// A correction is re-keyed only when it covers at least half of the shorter
    /// of the two ranges. Below that the two segments are different utterances.
    private static let minimumEditOverlapRatio = 0.5

    /// Stores a canonical correction without discarding the latest ASR text.
    public func editSegmentText(id: String, text: String) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw PersistenceError.invalidSegment("edited text must not be empty")
        }
        try database.write { db in
            guard let existing = try SegmentRecord.fetchOne(db, key: id) else {
                throw PersistenceError.invalidSegment("segment \(id) does not exist")
            }
            try SegmentRecord
                .filter(key: id)
                .updateAll(
                    db,
                    Column("text").set(to: cleaned),
                    Column("modelText").set(to: existing.modelText ?? existing.text),
                    Column("isUserEdited").set(to: true)
                )
        }
    }

    public func segment(id: String) throws -> TranscriptSegment? {
        try database.read { db in
            try SegmentRecord.fetchOne(db, key: id)?.model()
        }
    }

    public func segments(meetingID: UUID) throws -> [TranscriptSegment] {
        try database.read { db in
            try SegmentRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .order(Column("startMilliseconds"), Column("source"), Column("id"))
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    @discardableResult
    public func renameSpeaker(
        meetingID: UUID,
        speakerID: String,
        to speakerName: String?
    ) throws -> Int {
        let cleanedName = speakerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.write { db in
            try SegmentRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .filter(Column("speakerID") == speakerID)
                .updateAll(db, Column("speakerName").set(to: cleanedName?.isEmpty == true ? nil : cleanedName))
        }
    }

    public func searchSegments(
        _ query: String,
        meetingID: UUID? = nil,
        limit: Int = 100
    ) throws -> [TranscriptSegment] {
        let matchQuery = try Self.ftsMatchQuery(query)
        return try database.read { db in
            var sql = """
                SELECT s.*
                FROM transcriptSegments AS s
                JOIN transcriptSegmentFTS AS fts ON fts.segmentID = s.id
                WHERE transcriptSegmentFTS MATCH ?
                """
            var arguments: StatementArguments = [matchQuery]
            if let meetingID {
                sql += " AND s.meetingID = ?"
                arguments += [meetingID.uuidString]
            }
            sql += " ORDER BY bm25(transcriptSegmentFTS), s.startMilliseconds LIMIT ?"
            arguments += [max(1, limit)]
            return try SegmentRecord.fetchAll(db, sql: sql, arguments: arguments).map { try $0.model() }
        }
    }

    @discardableResult
    public func saveInsightSnapshot(
        meetingID: UUID,
        providerID: String,
        output: ValidatedMeetingInsights,
        createdAt: Date = Date()
    ) throws -> UUID {
        try saveGeneratedInsights(
            meetingID: meetingID,
            providerID: providerID,
            output: output,
            createdAt: createdAt
        ).snapshotID
    }

    /// Saves provider output and its overview version in one transaction.
    ///
    /// A generated candidate becomes active only when the meeting has no active
    /// summary. Regeneration must never silently replace a version the user has
    /// selected or authored.
    @discardableResult
    public func saveGeneratedInsights(
        meetingID: UUID,
        providerID: String,
        output: ValidatedMeetingInsights,
        createdAt: Date = Date()
    ) throws -> SavedGeneratedInsights {
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.invalidProviderRun("provider ID must not be empty")
        }
        guard !output.insights.overview.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.invalidSummary("Generated overview text cannot be blank.")
        }
        let snapshot = StoredInsightSnapshot(
            id: UUID(),
            meetingID: meetingID,
            providerID: providerID,
            createdAt: createdAt,
            output: output
        )
        let version = SummaryVersion(
            meetingID: meetingID,
            kind: .generated,
            text: output.insights.overview.text,
            createdAt: createdAt,
            sourceInsightSnapshotID: snapshot.id
        )
        return try database.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID.uuidString) else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            try InsightSnapshotRecord(snapshot).insert(db)
            try SummaryVersionRecord(version).insert(db)
            let didActivate = meeting.activeSummaryVersionID == nil
            if didActivate {
                try MeetingRecord
                    .filter(key: meetingID.uuidString)
                    .updateAll(
                        db,
                        Column("activeSummaryVersionID").set(to: version.id.uuidString),
                        Column("updatedAt").set(to: createdAt)
                    )
            }
            return SavedGeneratedInsights(
                snapshotID: snapshot.id,
                summaryVersion: version,
                didActivate: didActivate
            )
        }
    }

    public func insightSnapshots(meetingID: UUID) throws -> [StoredInsightSnapshot] {
        try database.read { db in
            try InsightSnapshotRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func insightSnapshot(id: UUID) throws -> StoredInsightSnapshot? {
        try database.read { db in
            try InsightSnapshotRecord.fetchOne(db, key: id.uuidString)?.model()
        }
    }

    @discardableResult
    public func createSummaryVersion(
        meetingID: UUID,
        kind: SummaryVersionKind,
        text: String,
        sourceInsightSnapshotID: UUID? = nil,
        createdAt: Date = Date(),
        activate: Bool = true
    ) throws -> SummaryVersion {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.invalidSummary("Enter at least one non-whitespace character.")
        }
        guard kind == .manual || sourceInsightSnapshotID != nil else {
            throw PersistenceError.invalidSummary("A generated summary must reference its insight snapshot.")
        }
        let version = SummaryVersion(
            meetingID: meetingID,
            kind: kind,
            text: text,
            createdAt: createdAt,
            sourceInsightSnapshotID: sourceInsightSnapshotID
        )
        try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            if let sourceInsightSnapshotID {
                guard let snapshot = try InsightSnapshotRecord.fetchOne(
                    db,
                    key: sourceInsightSnapshotID.uuidString
                ), snapshot.meetingID == meetingID.uuidString else {
                    throw PersistenceError.invalidSummary("The source snapshot belongs to another meeting or is missing.")
                }
            }
            try SummaryVersionRecord(version).insert(db)
            if activate {
                try MeetingRecord
                    .filter(key: meetingID.uuidString)
                    .updateAll(
                        db,
                        Column("activeSummaryVersionID").set(to: version.id.uuidString),
                        Column("updatedAt").set(to: createdAt)
                    )
            }
        }
        return version
    }

    public func summaryVersions(
        meetingID: UUID,
        limit: Int = 50,
        before date: Date? = nil
    ) throws -> [SummaryVersion] {
        try database.read { db in
            var request = SummaryVersionRecord
                .filter(Column("meetingID") == meetingID.uuidString)
            if let date { request = request.filter(Column("createdAt") < date) }
            return try request
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(max(1, limit))
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func summaryVersion(id: UUID) throws -> SummaryVersion? {
        try database.read { db in
            try SummaryVersionRecord.fetchOne(db, key: id.uuidString)?.model()
        }
    }

    public func activeSummaryVersion(meetingID: UUID) throws -> SummaryVersion? {
        try database.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID.uuidString) else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            guard let id = meeting.activeSummaryVersionID else { return nil }
            return try SummaryVersionRecord.fetchOne(db, key: id)?.model()
        }
    }

    public func activateSummaryVersion(
        id: UUID,
        meetingID: UUID,
        at date: Date = Date()
    ) throws {
        try database.write { db in
            guard let version = try SummaryVersionRecord.fetchOne(db, key: id.uuidString),
                  version.meetingID == meetingID.uuidString else {
                throw PersistenceError.invalidSummary("The selected version does not belong to this meeting.")
            }
            let changed = try MeetingRecord
                .filter(key: meetingID.uuidString)
                .updateAll(
                    db,
                    Column("activeSummaryVersionID").set(to: id.uuidString),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(meetingID) }
        }
    }

    public func deleteSummaryVersion(id: UUID, meetingID: UUID, at date: Date = Date()) throws {
        try database.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID.uuidString) else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            guard let version = try SummaryVersionRecord.fetchOne(db, key: id.uuidString),
                  version.meetingID == meetingID.uuidString else {
                throw PersistenceError.invalidSummary("The selected version does not belong to this meeting.")
            }
            _ = try SummaryVersionRecord.deleteOne(db, key: id.uuidString)
            if meeting.activeSummaryVersionID == id.uuidString {
                let replacement = try SummaryVersionRecord
                    .filter(Column("meetingID") == meetingID.uuidString)
                    .order(Column("createdAt").desc, Column("id").desc)
                    .fetchOne(db)
                try MeetingRecord
                    .filter(key: meetingID.uuidString)
                    .updateAll(
                        db,
                        Column("activeSummaryVersionID").set(to: replacement?.id),
                        Column("updatedAt").set(to: date)
                    )
            }
        }
    }

    @discardableResult
    public func beginProviderRun(
        meetingID: UUID,
        providerID: String,
        purpose: String,
        at date: Date = Date()
    ) throws -> UUID {
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.invalidProviderRun("provider ID and purpose must not be empty")
        }
        let run = StoredProviderRun(
            id: UUID(),
            meetingID: meetingID,
            providerID: providerID,
            purpose: purpose,
            startedAt: date,
            finishedAt: nil,
            status: .running,
            errorMessage: nil
        )
        try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            try ProviderRunRecord(run).insert(db)
        }
        return run.id
    }

    public func finishProviderRun(
        id: UUID,
        status: ProviderRunStatus,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) throws {
        guard status != .running else {
            throw PersistenceError.invalidProviderRun("a finished run cannot remain running")
        }
        try database.write { db in
            let changed = try ProviderRunRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("finishedAt").set(to: date),
                    Column("status").set(to: status.rawValue),
                    Column("errorMessage").set(to: errorMessage)
                )
            guard changed == 1 else {
                throw PersistenceError.corruptRecord("missing provider run \(id)")
            }
        }
    }

    public func providerRuns(meetingID: UUID) throws -> [StoredProviderRun] {
        try database.read { db in
            try ProviderRunRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .order(Column("startedAt").desc)
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    /// Closes audit rows whose process disappeared with a previous app session.
    /// A provider run cannot legitimately survive process relaunch, so every
    /// remaining `running` row is stale regardless of its age.
    @discardableResult
    public func failInterruptedProviderRuns(
        at date: Date = Date(),
        message: String = "The app closed before the provider finished."
    ) throws -> Int {
        try database.write { db in
            try ProviderRunRecord
                .filter(Column("status") == ProviderRunStatus.running.rawValue)
                .updateAll(
                    db,
                    Column("finishedAt").set(to: date),
                    Column("status").set(to: ProviderRunStatus.failed.rawValue),
                    Column("errorMessage").set(to: message)
                )
        }
    }

    /// Marks sessions that could not have completed a clean shutdown. CAF
    /// tracks remain referenced so the finalization pipeline can resume.
    @discardableResult
    public func recoverInterruptedMeetings(at date: Date = Date()) throws -> [Meeting] {
        try database.write { db in
            let activeStatuses = [MeetingStatus.recording.rawValue, MeetingStatus.finalizing.rawValue]
            let active = try MeetingRecord
                .filter(activeStatuses.contains(Column("status")))
                .fetchAll(db)
            guard !active.isEmpty else { return [] }
            let ids = active.map(\.id)
            try MeetingRecord
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("status").set(to: MeetingStatus.interrupted.rawValue),
                    Column("errorMessage").set(to: "The app closed before this meeting was finalized."),
                    Column("updatedAt").set(to: date)
                )
            return try MeetingRecord.filter(ids.contains(Column("id"))).fetchAll(db).map { try $0.model() }
        }
    }

    /// Deletes the relational meeting graph in one transaction. Audio removal
    /// is explicit and happens first so a filesystem failure never loses the DB
    /// pointers required for a retry.
    public func deleteMeeting(id: UUID, deleteAudioFiles: Bool = true) throws {
        let tracks = try audioTracks(meetingID: id)
        if deleteAudioFiles {
            try Self.removeFiles(for: tracks)
        }
        try database.write { db in
            let deleted = try MeetingRecord.deleteOne(db, key: id.uuidString)
            guard deleted else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    public func softDeleteMeeting(id: UUID, at date: Date = Date()) throws {
        try database.write { db in
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .updateAll(
                    db,
                    Column("deletedAt").set(to: date),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    public func restoreMeeting(id: UUID, at date: Date = Date()) throws {
        try database.write { db in
            let changed = try MeetingRecord
                .filter(key: id.uuidString)
                .filter(Column("deletedAt") != nil)
                .updateAll(
                    db,
                    Column("deletedAt").set(to: nil),
                    Column("updatedAt").set(to: date)
                )
            guard changed == 1 else { throw PersistenceError.meetingNotFound(id) }
        }
    }

    /// Permanently removes soft-deleted meetings outside the retention window.
    /// Audio is removed before each relational graph so a filesystem failure
    /// leaves that meeting recoverable for the next purge attempt.
    @discardableResult
    public func purgeDeletedMeetings(
        olderThan date: Date = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    ) throws -> [UUID] {
        let ids = try database.read { db in
            try MeetingRecord
                .filter(Column("deletedAt") != nil)
                .filter(Column("deletedAt") < date)
                .order(Column("deletedAt"))
                .fetchAll(db)
                .compactMap { UUID(uuidString: $0.id) }
        }
        var purged: [UUID] = []
        for id in ids {
            try deleteMeeting(id: id, deleteAudioFiles: true)
            purged.append(id)
        }
        return purged
    }

    /// Removes retained/recovery audio and its metadata together. Call this
    /// after successful finalization when the meeting does not retain audio.
    public func deleteAudioFiles(meetingID: UUID) throws {
        let tracks = try audioTracks(meetingID: meetingID)
        try Self.removeFiles(for: tracks)
        _ = try database.write { db in
            try AudioTrackRecord
                .filter(Column("meetingID") == meetingID.uuidString)
                .deleteAll(db)
        }
    }

    private func validate(_ segments: [TranscriptSegment]) throws {
        var ids = Set<String>()
        for segment in segments {
            guard !segment.id.isEmpty else {
                throw PersistenceError.invalidSegment("IDs must not be empty")
            }
            guard ids.insert(segment.id).inserted else {
                throw PersistenceError.invalidSegment("duplicate ID \(segment.id)")
            }
            guard segment.startMilliseconds >= 0,
                  segment.endMilliseconds >= segment.startMilliseconds,
                  segment.revision >= 0
            else {
                throw PersistenceError.invalidSegment("invalid timing or revision for \(segment.id)")
            }
        }
    }

    private static func validatedFolderName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PersistenceError.invalidFolderName("Enter at least one non-whitespace character.")
        }
        guard name.count <= 80 else {
            throw PersistenceError.invalidFolderName("Use 80 characters or fewer.")
        }
        return name
    }

    /// This form is stored in SQLite and is therefore the source of truth for
    /// uniqueness. `localizedStandardCompare` is unsuitable here because it
    /// can change with the user's locale between two writes.
    private static func normalizedFolderName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func requireActiveFolder(_ id: UUID, in db: Database) throws {
        guard try MeetingFolderRecord
            .filter(key: id.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db) != nil
        else { throw PersistenceError.folderNotFound(id) }
    }

    private static func ftsMatchQuery(_ rawQuery: String) throws -> String {
        let tokens = rawQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw PersistenceError.invalidSearchQuery }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    private static func removeFiles(for tracks: [MeetingAudioTrack]) throws {
        let manager = FileManager.default
        for track in tracks where manager.fileExists(atPath: track.fileURL.path) {
            try manager.removeItem(at: track.fileURL)
        }
        let directories = Set(tracks.map { $0.fileURL.deletingLastPathComponent() })
        for directory in directories {
            if (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? manager.removeItem(at: directory)
            }
        }
    }
}
