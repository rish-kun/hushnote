import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
}

public enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case finalizing
    case ready
    case interrupted
    case failed
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var updatedAt: Date
    public var status: MeetingStatus
    public var errorMessage: String?
    public var retainsAudio: Bool
    public var activeSummaryVersionID: UUID?
    public var deletedAt: Date?
    /// The optional flat collection this meeting belongs to. `nil` is Unfiled.
    public var folderID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        updatedAt: Date = Date(),
        status: MeetingStatus = .idle,
        errorMessage: String? = nil,
        retainsAudio: Bool = false,
        activeSummaryVersionID: UUID? = nil,
        deletedAt: Date? = nil,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.status = status
        self.errorMessage = errorMessage
        self.retainsAudio = retainsAudio
        self.activeSummaryVersionID = activeSummaryVersionID
        self.deletedAt = deletedAt
        self.folderID = folderID
    }
}

/// A named, flat collection of meetings. Folder removal is recoverable: the
/// row is soft-deleted while every assigned meeting becomes Unfiled.
public struct MeetingFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Counts are deliberately separate from a folder so a folder query does not
/// have to materialize every meeting just to render a sidebar badge.
public struct MeetingFolderCount: Equatable, Sendable, Identifiable {
    public let folderID: UUID
    public let meetingCount: Int

    public var id: UUID { folderID }

    public init(folderID: UUID, meetingCount: Int) {
        self.folderID = folderID
        self.meetingCount = meetingCount
    }
}

public enum SummaryVersionKind: String, Codable, CaseIterable, Sendable {
    case generated
    case manual
}

/// One immutable revision of the meeting overview.
///
/// Generated revisions point back to the insight snapshot that supplied their
/// text. Manual revisions deliberately keep authored whitespace verbatim.
public struct SummaryVersion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var kind: SummaryVersionKind
    public var text: String
    public var createdAt: Date
    public var sourceInsightSnapshotID: UUID?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        kind: SummaryVersionKind,
        text: String,
        createdAt: Date = Date(),
        sourceInsightSnapshotID: UUID? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.sourceInsightSnapshotID = sourceInsightSnapshotID
    }
}

public struct SavedGeneratedInsights: Equatable, Sendable {
    public var snapshotID: UUID
    public var summaryVersion: SummaryVersion
    public var didActivate: Bool

    public init(snapshotID: UUID, summaryVersion: SummaryVersion, didActivate: Bool) {
        self.snapshotID = snapshotID
        self.summaryVersion = summaryVersion
        self.didActivate = didActivate
    }
}

public struct MeetingAudioTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var source: AudioSource
    public var fileURL: URL
    public var sampleRate: Double
    public var channelCount: Int
    /// Meeting-time position represented by frame zero of this file.
    public var timelineStartMilliseconds: Int64
    public var durationMilliseconds: Int64
    public var isComplete: Bool

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        source: AudioSource,
        fileURL: URL,
        sampleRate: Double,
        channelCount: Int,
        timelineStartMilliseconds: Int64 = 0,
        durationMilliseconds: Int64 = 0,
        isComplete: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.timelineStartMilliseconds = timelineStartMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.isComplete = isComplete
    }
}

public enum RecordingSessionOrigin: String, Codable, CaseIterable, Sendable {
    case live
    case continued
    case imported
    case legacy
}

public enum RecordingSessionState: String, Codable, CaseIterable, Sendable {
    case capturing
    case captured
    case processing
    case ready
    case interrupted
    case failed
}

/// One capture or import interval on a meeting's continuous media timeline.
///
/// The wall clock can advance while the captured-media clock is frozen by a
/// pause or sleep gap. `timelineStartMilliseconds` and
/// `capturedDurationMilliseconds` therefore remain explicit rather than being
/// derived from the two dates.
public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var ordinal: Int
    public var origin: RecordingSessionOrigin
    public var wallStartedAt: Date
    public var wallEndedAt: Date?
    public var timelineStartMilliseconds: Int64
    public var capturedDurationMilliseconds: Int64
    public var state: RecordingSessionState

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        ordinal: Int,
        origin: RecordingSessionOrigin,
        wallStartedAt: Date,
        wallEndedAt: Date? = nil,
        timelineStartMilliseconds: Int64,
        capturedDurationMilliseconds: Int64 = 0,
        state: RecordingSessionState
    ) {
        self.id = id
        self.meetingID = meetingID
        self.ordinal = ordinal
        self.origin = origin
        self.wallStartedAt = wallStartedAt
        self.wallEndedAt = wallEndedAt
        self.timelineStartMilliseconds = timelineStartMilliseconds
        self.capturedDurationMilliseconds = capturedDurationMilliseconds
        self.state = state
    }
}

public enum SessionAudioSourceKind: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
    case importedMix
    case importedParticipant
}

/// A stable logical source whose physical capture can rotate through many
/// immutable takes.
public struct SessionAudioSource: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var ordinal: Int
    public var kind: SessionAudioSourceKind
    public var label: String?
    public var deviceUID: String?
    public var isExpected: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        ordinal: Int,
        kind: SessionAudioSourceKind,
        label: String? = nil,
        deviceUID: String? = nil,
        isExpected: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.kind = kind
        self.label = label
        self.deviceUID = deviceUID
        self.isExpected = isExpected
    }
}

/// One crash-recoverable source file. Takes are append-only; a device or format
/// transition closes one take and allocates the next ordinal.
public struct AudioTake: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var ordinal: Int
    public var fileURL: URL
    public var timelineStartMilliseconds: Int64
    public var sampleRate: Double
    public var channelCount: Int
    public var durationMilliseconds: Int64
    public var isComplete: Bool

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        ordinal: Int,
        fileURL: URL,
        timelineStartMilliseconds: Int64,
        sampleRate: Double,
        channelCount: Int,
        durationMilliseconds: Int64 = 0,
        isComplete: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.fileURL = fileURL
        self.timelineStartMilliseconds = timelineStartMilliseconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationMilliseconds = durationMilliseconds
        self.isComplete = isComplete
    }
}

public enum RecordingEventKind: String, Codable, CaseIterable, Sendable {
    case continued
    case pause
    case sleepGap
    case deviceChanged
    case formatChanged
    case sourceUnavailable
    case sourceRecovered
    case microphoneEnabled
    case microphoneDisabled
    case droppedAudio
}

/// A sparse durable boundary or diagnostic. Continuous levels and health
/// samples deliberately remain transient.
public struct RecordingEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var sourceID: UUID?
    public var kind: RecordingEventKind
    public var timelineMilliseconds: Int64
    public var wallClockAt: Date
    public var durationMilliseconds: Int64?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sourceID: UUID? = nil,
        kind: RecordingEventKind,
        timelineMilliseconds: Int64,
        wallClockAt: Date,
        durationMilliseconds: Int64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.kind = kind
        self.timelineMilliseconds = timelineMilliseconds
        self.wallClockAt = wallClockAt
        self.durationMilliseconds = durationMilliseconds
        self.metadata = metadata
    }
}

public enum FinalizationJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case transcribing
    case diarizing
    case merging
    case succeeded
    case failed
}

/// Durable processing state for one session. A retry updates the same row and
/// increments `attemptCount`, so a session cannot accidentally run two final
/// passes at once.
public struct FinalizationJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var state: FinalizationJobState
    public var modelID: String
    public var languageCode: String?
    public var attemptCount: Int
    public var progress: Double
    public var queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?
    public var audioDurationMilliseconds: Int64
    public var realtimeFactor: Double?
    public var completionNotifiedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        state: FinalizationJobState = .queued,
        modelID: String,
        languageCode: String? = nil,
        attemptCount: Int = 0,
        progress: Double = 0,
        queuedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        audioDurationMilliseconds: Int64,
        realtimeFactor: Double? = nil,
        completionNotifiedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.state = state
        self.modelID = modelID
        self.languageCode = languageCode
        self.attemptCount = attemptCount
        self.progress = progress
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.audioDurationMilliseconds = audioDurationMilliseconds
        self.realtimeFactor = realtimeFactor
        self.completionNotifiedAt = completionNotifiedAt
    }
}

public enum TranscriptStability: String, Codable, CaseIterable, Comparable, Sendable {
    case partial
    case stable
    case final

    public static func < (lhs: Self, rhs: Self) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: Self) -> Int {
        switch value {
        case .partial: 0
        case .stable: 1
        case .final: 2
        }
    }
}

public struct TranscriptWord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public var confidence: Float?

    public init(
        id: String,
        text: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        confidence: Float? = nil
    ) {
        self.id = id
        self.text = text
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var meetingID: UUID
    public var source: AudioSource
    public var revision: Int
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public var text: String
    public var words: [TranscriptWord]
    public var speakerID: String?
    public var speakerName: String?
    public var confidence: Float?
    public var stability: TranscriptStability

    public init(
        id: String,
        meetingID: UUID,
        source: AudioSource,
        revision: Int = 0,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String,
        words: [TranscriptWord] = [],
        speakerID: String? = nil,
        speakerName: String? = nil,
        confidence: Float? = nil,
        stability: TranscriptStability = .partial
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.revision = revision
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.words = words
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.confidence = confidence
        self.stability = stability
    }
}

/// A complete, ordered hypothesis for one audio source at a point in time.
///
/// `stablePrefixCount` is the number of leading segments the engine considers
/// committed. Once accepted by `TranscriptAssembler`, that prefix is immutable.
public struct TranscriptDelta: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var source: AudioSource
    public var revision: Int
    public var segments: [TranscriptSegment]
    public var stablePrefixCount: Int
    public var isFinal: Bool

    public init(
        meetingID: UUID,
        source: AudioSource,
        revision: Int,
        segments: [TranscriptSegment],
        stablePrefixCount: Int = 0,
        isFinal: Bool = false
    ) {
        self.meetingID = meetingID
        self.source = source
        self.revision = revision
        self.segments = segments
        self.stablePrefixCount = stablePrefixCount
        self.isFinal = isFinal
    }
}

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var revision: Int
    public var segments: [TranscriptSegment]

    public init(meetingID: UUID, revision: Int, segments: [TranscriptSegment]) {
        self.meetingID = meetingID
        self.revision = revision
        self.segments = segments
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }
}

public struct SpeakerTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var speakerID: String
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public var confidence: Float?

    public init(
        id: String,
        speakerID: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        confidence: Float? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
    }
}

public struct AudioFrame: Equatable, Sendable {
    public var meetingID: UUID
    public var source: AudioSource
    public var sequenceNumber: Int64
    public var startMilliseconds: Int64
    public var sampleRate: Int
    public var samples: [Float]

    public init(
        meetingID: UUID,
        source: AudioSource,
        sequenceNumber: Int64,
        startMilliseconds: Int64,
        sampleRate: Int = 16_000,
        samples: [Float]
    ) {
        self.meetingID = meetingID
        self.source = source
        self.sequenceNumber = sequenceNumber
        self.startMilliseconds = startMilliseconds
        self.sampleRate = sampleRate
        self.samples = samples
    }
}
