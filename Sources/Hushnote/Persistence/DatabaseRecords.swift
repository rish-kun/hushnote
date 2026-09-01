import Foundation
import GRDB

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "meetings"

    var id: String
    var title: String
    var notes: String
    var createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var updatedAt: Date
    var status: String
    var errorMessage: String?
    var retainsAudio: Bool
    var activeSummaryVersionID: String?
    var deletedAt: Date?
    var folderID: String?

    init(_ meeting: Meeting) {
        id = meeting.id.uuidString
        title = meeting.title
        notes = meeting.notes
        createdAt = meeting.createdAt
        startedAt = meeting.startedAt
        endedAt = meeting.endedAt
        updatedAt = meeting.updatedAt
        status = meeting.status.rawValue
        errorMessage = meeting.errorMessage
        retainsAudio = meeting.retainsAudio
        activeSummaryVersionID = meeting.activeSummaryVersionID?.uuidString
        deletedAt = meeting.deletedAt
        folderID = meeting.folderID?.uuidString
    }

    func model() throws -> Meeting {
        guard let id = UUID(uuidString: id), let status = MeetingStatus(rawValue: status) else {
            throw PersistenceError.corruptRecord("meeting \(self.id)")
        }
        return Meeting(
            id: id,
            title: title,
            notes: notes,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            updatedAt: updatedAt,
            status: status,
            errorMessage: errorMessage,
            retainsAudio: retainsAudio,
            activeSummaryVersionID: activeSummaryVersionID.flatMap(UUID.init(uuidString:)),
            deletedAt: deletedAt,
            folderID: folderID.flatMap(UUID.init(uuidString:))
        )
    }
}

struct MeetingFolderRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "meetingFolders"

    var id: String
    var name: String
    /// A folded form of `name` that enforces case- and diacritic-insensitive
    /// uniqueness even if another process writes the SQLite database.
    var normalizedName: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ folder: MeetingFolder, normalizedName: String) {
        id = folder.id.uuidString
        name = folder.name
        self.normalizedName = normalizedName
        createdAt = folder.createdAt
        updatedAt = folder.updatedAt
        deletedAt = folder.deletedAt
    }

    func model() throws -> MeetingFolder {
        guard let id = UUID(uuidString: id) else {
            throw PersistenceError.corruptRecord("meeting folder \(self.id)")
        }
        return MeetingFolder(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

/// The local half of a share. The server holds the payload and a hash of the
/// device token; this row holds only what this Mac needs to keep the two in
/// step and to revoke.
struct MeetingShareRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "meetingShares"

    var meetingID: String
    var shareID: String
    var includesTranscript: Bool
    var includesNotes: Bool
    var includesSummary: Bool
    var hasPassword: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    var syncedChecksum: String?
    var lastError: String?

    init(_ share: MeetingShare) {
        meetingID = share.meetingID.uuidString
        shareID = share.shareID
        includesTranscript = share.includes.transcript
        includesNotes = share.includes.notes
        includesSummary = share.includes.summary
        hasPassword = share.hasPassword
        createdAt = share.createdAt
        lastSyncedAt = share.lastSyncedAt
        syncedChecksum = share.syncedChecksum
        lastError = share.lastError
    }

    func model() throws -> MeetingShare {
        guard let meetingID = UUID(uuidString: meetingID) else {
            throw PersistenceError.corruptRecord("meeting share \(shareID)")
        }
        return MeetingShare(
            meetingID: meetingID,
            shareID: shareID,
            includes: ShareIncludes(
                transcript: includesTranscript,
                notes: includesNotes,
                summary: includesSummary
            ),
            hasPassword: hasPassword,
            createdAt: createdAt,
            lastSyncedAt: lastSyncedAt,
            syncedChecksum: syncedChecksum,
            lastError: lastError
        )
    }
}

struct SummaryVersionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "summaryVersions"

    var id: String
    var meetingID: String
    var kind: String
    var text: String
    var createdAt: Date
    var sourceInsightSnapshotID: String?

    init(_ version: SummaryVersion) {
        id = version.id.uuidString
        meetingID = version.meetingID.uuidString
        kind = version.kind.rawValue
        text = version.text
        createdAt = version.createdAt
        sourceInsightSnapshotID = version.sourceInsightSnapshotID?.uuidString
    }

    func model() throws -> SummaryVersion {
        guard let id = UUID(uuidString: id),
              let meetingID = UUID(uuidString: meetingID),
              let kind = SummaryVersionKind(rawValue: kind)
        else {
            throw PersistenceError.corruptRecord("summary version \(self.id)")
        }
        let sourceID: UUID?
        if let sourceInsightSnapshotID {
            guard let parsed = UUID(uuidString: sourceInsightSnapshotID) else {
                throw PersistenceError.corruptRecord("summary version \(self.id)")
            }
            sourceID = parsed
        } else {
            sourceID = nil
        }
        return SummaryVersion(
            id: id,
            meetingID: meetingID,
            kind: kind,
            text: text,
            createdAt: createdAt,
            sourceInsightSnapshotID: sourceID
        )
    }
}

struct AudioTrackRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "audioTracks"

    var id: String
    var meetingID: String
    var source: String
    var filePath: String
    var sampleRate: Double
    var channelCount: Int
    var durationMilliseconds: Int64
    var isComplete: Bool

    init(_ track: MeetingAudioTrack) {
        id = track.id.uuidString
        meetingID = track.meetingID.uuidString
        source = track.source.rawValue
        filePath = track.fileURL.path
        sampleRate = track.sampleRate
        channelCount = track.channelCount
        durationMilliseconds = track.durationMilliseconds
        isComplete = track.isComplete
    }

    func model() throws -> MeetingAudioTrack {
        guard let id = UUID(uuidString: id),
              let meetingID = UUID(uuidString: meetingID),
              let source = AudioSource(rawValue: source)
        else {
            throw PersistenceError.corruptRecord("audio track \(self.id)")
        }
        return MeetingAudioTrack(
            id: id,
            meetingID: meetingID,
            source: source,
            fileURL: URL(filePath: filePath),
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationMilliseconds: durationMilliseconds,
            isComplete: isComplete
        )
    }
}

struct RecordingSessionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "recordingSessions"

    var id: String
    var meetingID: String
    var ordinal: Int
    var origin: String
    var wallStartedAt: Date
    var wallEndedAt: Date?
    var timelineStartMilliseconds: Int64
    var capturedDurationMilliseconds: Int64
    var state: String

    init(_ session: RecordingSession) {
        id = session.id.uuidString
        meetingID = session.meetingID.uuidString
        ordinal = session.ordinal
        origin = session.origin.rawValue
        wallStartedAt = session.wallStartedAt
        wallEndedAt = session.wallEndedAt
        timelineStartMilliseconds = session.timelineStartMilliseconds
        capturedDurationMilliseconds = session.capturedDurationMilliseconds
        state = session.state.rawValue
    }

    func model() throws -> RecordingSession {
        guard let id = UUID(uuidString: id),
              let meetingID = UUID(uuidString: meetingID),
              let origin = RecordingSessionOrigin(rawValue: origin),
              let state = RecordingSessionState(rawValue: state)
        else {
            throw PersistenceError.corruptRecord("recording session \(self.id)")
        }
        return RecordingSession(
            id: id,
            meetingID: meetingID,
            ordinal: ordinal,
            origin: origin,
            wallStartedAt: wallStartedAt,
            wallEndedAt: wallEndedAt,
            timelineStartMilliseconds: timelineStartMilliseconds,
            capturedDurationMilliseconds: capturedDurationMilliseconds,
            state: state
        )
    }
}

struct SessionAudioSourceRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "sessionAudioSources"

    var id: String
    var sessionID: String
    var ordinal: Int
    var kind: String
    var label: String?
    var deviceUID: String?
    var isExpected: Bool

    init(_ source: SessionAudioSource) {
        id = source.id.uuidString
        sessionID = source.sessionID.uuidString
        ordinal = source.ordinal
        kind = source.kind.rawValue
        label = source.label
        deviceUID = source.deviceUID
        isExpected = source.isExpected
    }

    func model() throws -> SessionAudioSource {
        guard let id = UUID(uuidString: id),
              let sessionID = UUID(uuidString: sessionID),
              let kind = SessionAudioSourceKind(rawValue: kind)
        else {
            throw PersistenceError.corruptRecord("session audio source \(self.id)")
        }
        return SessionAudioSource(
            id: id,
            sessionID: sessionID,
            ordinal: ordinal,
            kind: kind,
            label: label,
            deviceUID: deviceUID,
            isExpected: isExpected
        )
    }
}

struct AudioTakeRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "audioTakes"

    var id: String
    var sourceID: String
    var ordinal: Int
    var filePath: String
    var timelineStartMilliseconds: Int64
    var sampleRate: Double
    var channelCount: Int
    var durationMilliseconds: Int64
    var isComplete: Bool

    init(_ take: AudioTake) {
        id = take.id.uuidString
        sourceID = take.sourceID.uuidString
        ordinal = take.ordinal
        filePath = take.fileURL.path
        timelineStartMilliseconds = take.timelineStartMilliseconds
        sampleRate = take.sampleRate
        channelCount = take.channelCount
        durationMilliseconds = take.durationMilliseconds
        isComplete = take.isComplete
    }

    func model() throws -> AudioTake {
        guard let id = UUID(uuidString: id), let sourceID = UUID(uuidString: sourceID) else {
            throw PersistenceError.corruptRecord("audio take \(self.id)")
        }
        return AudioTake(
            id: id,
            sourceID: sourceID,
            ordinal: ordinal,
            fileURL: URL(filePath: filePath),
            timelineStartMilliseconds: timelineStartMilliseconds,
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationMilliseconds: durationMilliseconds,
            isComplete: isComplete
        )
    }
}

struct RecordingEventRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "recordingEvents"

    var id: String
    var sessionID: String
    var sourceID: String?
    var kind: String
    var timelineMilliseconds: Int64
    var wallClockAt: Date
    var durationMilliseconds: Int64?
    var metadataJSON: Data

    init(_ event: RecordingEvent) throws {
        id = event.id.uuidString
        sessionID = event.sessionID.uuidString
        sourceID = event.sourceID?.uuidString
        kind = event.kind.rawValue
        timelineMilliseconds = event.timelineMilliseconds
        wallClockAt = event.wallClockAt
        durationMilliseconds = event.durationMilliseconds
        metadataJSON = try JSONEncoder().encode(event.metadata)
    }

    func model() throws -> RecordingEvent {
        guard let id = UUID(uuidString: id),
              let sessionID = UUID(uuidString: sessionID),
              let kind = RecordingEventKind(rawValue: kind)
        else {
            throw PersistenceError.corruptRecord("recording event \(self.id)")
        }
        let resolvedSourceID: UUID?
        if let sourceID {
            guard let parsed = UUID(uuidString: sourceID) else {
                throw PersistenceError.corruptRecord("recording event \(self.id)")
            }
            resolvedSourceID = parsed
        } else {
            resolvedSourceID = nil
        }
        return RecordingEvent(
            id: id,
            sessionID: sessionID,
            sourceID: resolvedSourceID,
            kind: kind,
            timelineMilliseconds: timelineMilliseconds,
            wallClockAt: wallClockAt,
            durationMilliseconds: durationMilliseconds,
            metadata: try JSONDecoder().decode([String: String].self, from: metadataJSON)
        )
    }
}

struct RecordingMarkerRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "recordingMarkers"

    var id: String
    var meetingID: String
    var sessionID: String
    var type: String
    var timelineMilliseconds: Int64
    var wallClockAt: Date

    init(_ marker: RecordingMarker) {
        id = marker.id.uuidString
        meetingID = marker.meetingID.uuidString
        sessionID = marker.sessionID.uuidString
        type = marker.type.rawValue
        timelineMilliseconds = marker.timelineMilliseconds
        wallClockAt = marker.wallClockAt
    }

    func model() throws -> RecordingMarker {
        guard let id = UUID(uuidString: id),
              let meetingID = UUID(uuidString: meetingID),
              let sessionID = UUID(uuidString: sessionID),
              let type = RecordingMarkerType(rawValue: type) else {
            throw PersistenceError.corruptRecord("recording marker \(self.id)")
        }
        return RecordingMarker(
            id: id,
            meetingID: meetingID,
            sessionID: sessionID,
            type: type,
            timelineMilliseconds: timelineMilliseconds,
            wallClockAt: wallClockAt
        )
    }
}

struct FinalizationJobRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "finalizationJobs"

    var id: String
    var sessionID: String
    var state: String
    var modelID: String
    var languageCode: String?
    var attemptCount: Int
    var progress: Double
    var queuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
    var audioDurationMilliseconds: Int64
    var realtimeFactor: Double?
    var completionNotifiedAt: Date?

    init(_ job: FinalizationJob) {
        id = job.id.uuidString
        sessionID = job.sessionID.uuidString
        state = job.state.rawValue
        modelID = job.modelID
        languageCode = job.languageCode
        attemptCount = job.attemptCount
        progress = job.progress
        queuedAt = job.queuedAt
        startedAt = job.startedAt
        finishedAt = job.finishedAt
        errorMessage = job.errorMessage
        audioDurationMilliseconds = job.audioDurationMilliseconds
        realtimeFactor = job.realtimeFactor
        completionNotifiedAt = job.completionNotifiedAt
    }

    func model() throws -> FinalizationJob {
        guard let id = UUID(uuidString: id),
              let sessionID = UUID(uuidString: sessionID),
              let state = FinalizationJobState(rawValue: state)
        else {
            throw PersistenceError.corruptRecord("finalization job \(self.id)")
        }
        return FinalizationJob(
            id: id,
            sessionID: sessionID,
            state: state,
            modelID: modelID,
            languageCode: languageCode,
            attemptCount: attemptCount,
            progress: progress,
            queuedAt: queuedAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            errorMessage: errorMessage,
            audioDurationMilliseconds: audioDurationMilliseconds,
            realtimeFactor: realtimeFactor,
            completionNotifiedAt: completionNotifiedAt
        )
    }
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "transcriptSegments"

    var id: String
    var meetingID: String
    var source: String
    var revision: Int
    var startMilliseconds: Int64
    var endMilliseconds: Int64
    var text: String
    /// Latest text produced by ASR, retained even when `text` is user-edited.
    var modelText: String?
    var isUserEdited: Bool
    var wordsJSON: Data
    var speakerID: String?
    var speakerName: String?
    var confidence: Float?
    var stability: String

    init(
        _ segment: TranscriptSegment,
        modelText: String? = nil,
        isUserEdited: Bool = false
    ) throws {
        id = segment.id
        meetingID = segment.meetingID.uuidString
        source = segment.source.rawValue
        revision = segment.revision
        startMilliseconds = segment.startMilliseconds
        endMilliseconds = segment.endMilliseconds
        text = segment.text
        self.modelText = modelText ?? segment.text
        self.isUserEdited = isUserEdited
        wordsJSON = try JSONEncoder().encode(segment.words)
        speakerID = segment.speakerID
        speakerName = segment.speakerName
        confidence = segment.confidence
        stability = segment.stability.rawValue
    }

    func model() throws -> TranscriptSegment {
        guard let meetingID = UUID(uuidString: meetingID),
              let source = AudioSource(rawValue: source),
              let stability = TranscriptStability(rawValue: stability)
        else {
            throw PersistenceError.corruptRecord("transcript segment \(id)")
        }
        return TranscriptSegment(
            id: id,
            meetingID: meetingID,
            source: source,
            revision: revision,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            text: text,
            words: try JSONDecoder().decode([TranscriptWord].self, from: wordsJSON),
            speakerID: speakerID,
            speakerName: speakerName,
            confidence: confidence,
            stability: stability
        )
    }
}

public struct StoredInsightSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let providerID: String
    public let createdAt: Date
    public let output: ValidatedMeetingInsights
}

struct InsightSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "insightSnapshots"

    var id: String
    var meetingID: String
    var providerID: String
    var createdAt: Date
    var payloadJSON: Data

    init(_ snapshot: StoredInsightSnapshot) throws {
        id = snapshot.id.uuidString
        meetingID = snapshot.meetingID.uuidString
        providerID = snapshot.providerID
        createdAt = snapshot.createdAt
        payloadJSON = try JSONEncoder().encode(snapshot.output)
    }

    func model() throws -> StoredInsightSnapshot {
        guard let id = UUID(uuidString: id), let meetingID = UUID(uuidString: meetingID) else {
            throw PersistenceError.corruptRecord("insight snapshot \(self.id)")
        }
        return StoredInsightSnapshot(
            id: id,
            meetingID: meetingID,
            providerID: providerID,
            createdAt: createdAt,
            output: try JSONDecoder().decode(ValidatedMeetingInsights.self, from: payloadJSON)
        )
    }
}

public enum ProviderRunStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
}

public struct StoredProviderRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let providerID: String
    public let purpose: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: ProviderRunStatus
    public let errorMessage: String?
}

struct ProviderRunRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "providerRuns"

    var id: String
    var meetingID: String
    var providerID: String
    var purpose: String
    var startedAt: Date
    var finishedAt: Date?
    var status: String
    var errorMessage: String?

    init(_ run: StoredProviderRun) {
        id = run.id.uuidString
        meetingID = run.meetingID.uuidString
        providerID = run.providerID
        purpose = run.purpose
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        status = run.status.rawValue
        errorMessage = run.errorMessage
    }

    func model() throws -> StoredProviderRun {
        guard let id = UUID(uuidString: id),
              let meetingID = UUID(uuidString: meetingID),
              let status = ProviderRunStatus(rawValue: status)
        else {
            throw PersistenceError.corruptRecord("provider run \(self.id)")
        }
        return StoredProviderRun(
            id: id,
            meetingID: meetingID,
            providerID: providerID,
            purpose: purpose,
            startedAt: startedAt,
            finishedAt: finishedAt,
            status: status,
            errorMessage: errorMessage
        )
    }
}

/// One correction carried from the previous transcript onto the new one.
public struct PreservedUserEdit: Equatable, Sendable {
    /// The segment the user actually edited, which no longer exists.
    public var previousSegmentID: String
    /// The segment in the new transcript that inherited the correction.
    public var segmentID: String
    public var text: String

    public init(previousSegmentID: String, segmentID: String, text: String) {
        self.previousSegmentID = previousSegmentID
        self.segmentID = segmentID
        self.text = text
    }
}

/// What `MeetingStore.replaceTranscript` did with the user's corrections.
public struct TranscriptReplacementReport: Equatable, Sendable {
    public var preserved: [PreservedUserEdit]
    /// Corrections that overlap nothing in the new transcript. Their rows are
    /// kept verbatim instead of being deleted, and are reported here so a caller
    /// can tell the user the newest ASR pass disagrees with them.
    public var orphaned: [TranscriptSegment]

    public init(preserved: [PreservedUserEdit] = [], orphaned: [TranscriptSegment] = []) {
        self.preserved = preserved
        self.orphaned = orphaned
    }
}

public enum PersistenceError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound(UUID)
    case recordingSessionNotFound(UUID)
    case audioSourceNotFound(UUID)
    case finalizationJobNotFound(UUID)
    case invalidSegment(String)
    case invalidRecordingSession(String)
    case invalidAudioSource(String)
    case invalidAudioTake(String)
    case invalidRecordingEvent(String)
    case invalidRecordingMarker(String)
    case invalidFinalizationJob(String)
    case corruptRecord(String)
    case invalidSearchQuery
    case invalidProviderRun(String)
    case invalidSummary(String)
    case invalidMeetingTitle(String)
    case folderNotFound(UUID)
    case invalidFolderName(String)
    case duplicateFolderName(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) does not exist."
        case .recordingSessionNotFound(let id): "Recording session \(id) does not exist."
        case .audioSourceNotFound(let id): "Recording source \(id) does not exist."
        case .finalizationJobNotFound(let id): "Finalization job \(id) does not exist."
        case .invalidSegment(let reason): "Invalid transcript segment: \(reason)"
        case .invalidRecordingSession(let reason): "Invalid recording session: \(reason)"
        case .invalidAudioSource(let reason): "Invalid recording source: \(reason)"
        case .invalidAudioTake(let reason): "Invalid audio take: \(reason)"
        case .invalidRecordingEvent(let reason): "Invalid recording event: \(reason)"
        case .invalidRecordingMarker(let reason): "Invalid recording marker: \(reason)"
        case .invalidFinalizationJob(let reason): "Invalid finalization job: \(reason)"
        case .corruptRecord(let description): "The database contains a corrupt \(description)."
        case .invalidSearchQuery: "Enter at least one searchable word."
        case .invalidProviderRun(let reason): "Invalid provider run: \(reason)"
        case .invalidSummary(let reason): "Invalid summary: \(reason)"
        case .invalidMeetingTitle(let reason): "Invalid meeting title: \(reason)"
        case .folderNotFound(let id): "Folder \(id) does not exist."
        case .invalidFolderName(let reason): "Invalid folder name: \(reason)"
        case .duplicateFolderName(let name): "A folder named “\(name)” already exists."
        }
    }
}
