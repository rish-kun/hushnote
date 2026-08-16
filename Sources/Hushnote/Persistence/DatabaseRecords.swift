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
            retainsAudio: retainsAudio
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
    case invalidSegment(String)
    case corruptRecord(String)
    case invalidSearchQuery
    case invalidProviderRun(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) does not exist."
        case .invalidSegment(let reason): "Invalid transcript segment: \(reason)"
        case .corruptRecord(let description): "The database contains a corrupt \(description)."
        case .invalidSearchQuery: "Enter at least one searchable word."
        case .invalidProviderRun(let reason): "Invalid provider run: \(reason)"
        }
    }
}
