import Foundation

/// Which parts of a meeting a share carries.
///
/// The load-bearing control of the whole feature. A share is republished from
/// the current meeting whenever its content changes, so content *not* included
/// here is the only content guaranteed never to leave the machine, whatever is
/// typed into the meeting afterwards. Sharing a meeting and then continuing to
/// take candid notes on it is only safe because `notes` can be false.
struct ShareIncludes: Codable, Equatable, Sendable {
    var transcript: Bool
    var notes: Bool
    var summary: Bool

    static let transcriptOnly = ShareIncludes(transcript: true, notes: false, summary: false)

    /// Nothing selected is not a share. Callers refuse rather than publishing an
    /// empty page under a real link.
    var isEmpty: Bool { !transcript && !notes && !summary }
}

/// What actually gets uploaded.
///
/// Deliberately a flat value with no identifiers from the local database: a
/// share is a publication, not a replica. Segment ids in particular must not
/// travel -- the final pass re-mints them, and an id that means something on
/// one Mac means nothing anywhere else.
struct SharePayload: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var speaker: String?
        var text: String
    }

    struct Summary: Codable, Equatable, Sendable {
        var text: String
        var topics: [String]
        var decisions: [String]
        var actions: [String]
        var openQuestions: [String]
    }

    var title: String
    var startedAt: Date
    var durationSeconds: Double
    var includes: ShareIncludes
    var transcript: [Segment]?
    var notes: String?
    var summary: Summary?
}

/// A share as this Mac knows it. The server knows only `shareID`, the payload,
/// and a hash of the device token.
struct MeetingShare: Codable, Equatable, Sendable, Identifiable {
    var meetingID: UUID
    var shareID: String
    var includes: ShareIncludes
    var hasPassword: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    /// The checksum of the payload the server currently holds. Comparing it to
    /// the checksum of the payload built right now is what decides whether a
    /// push is owed -- cheaper and far more robust than observing every source
    /// of shared content and hoping none was missed.
    var syncedChecksum: String?
    var lastError: String?

    var id: UUID { meetingID }
}

/// The network boundary, behind a protocol so no test ever performs a request.
/// Same seam as `AgentProcessRunner` and `SpeechModelDownloading`.
protocol SharePublishing: Sendable {
    /// - Returns: the new share's id.
    func create(payload: SharePayload, password: String?) async throws -> String
    func update(shareID: String, payload: SharePayload) async throws
    /// `nil` removes the password.
    func setPassword(shareID: String, password: String?) async throws
    func revoke(shareID: String) async throws
}

enum ShareError: Error, Equatable, LocalizedError, Sendable {
    case nothingSelected
    case notFound
    case revoked
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected:
            "Choose at least one of transcript, notes or summary to share."
        case .notFound:
            "That share no longer exists."
        case .revoked:
            "That link was withdrawn."
        case .unauthorized:
            "This Mac is not the owner of that link. Its device token has changed."
        case .rateLimited(let retryAfter):
            retryAfter.map { "Too many requests. Try again in \(Int($0)) seconds." }
                ?? "Too many requests. Try again shortly."
        case .server(let status, let message):
            message ?? "The share service returned an error (\(status))."
        case .transport(let detail):
            detail
        }
    }
}
