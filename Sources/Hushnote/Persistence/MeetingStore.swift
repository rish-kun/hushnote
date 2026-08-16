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
            var request = MeetingRecord.order(Column("updatedAt").desc)
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.model() }
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
                try record.save(db)
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
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.invalidProviderRun("provider ID must not be empty")
        }
        let snapshot = StoredInsightSnapshot(
            id: UUID(),
            meetingID: meetingID,
            providerID: providerID,
            createdAt: createdAt,
            output: output
        )
        try database.write { db in
            guard try MeetingRecord.fetchOne(db, key: meetingID.uuidString) != nil else {
                throw PersistenceError.meetingNotFound(meetingID)
            }
            try InsightSnapshotRecord(snapshot).insert(db)
        }
        return snapshot.id
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
