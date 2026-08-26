import Foundation

/// When a push is owed, and what survives one that fails.
///
/// Pure, so the two rules that matter can be asserted without a network: a
/// share is republished exactly when its content changed, and a failure never
/// costs the reader the version already published.
enum ShareSyncPolicy {
    /// Long enough that a sentence is one round trip rather than forty, as
    /// `queueMeetingNotes` does for local writes — and longer than its 350ms,
    /// because this crosses a network.
    static let debounce: Duration = .milliseconds(2_000)

    enum Decision: Equatable, Sendable {
        /// Push, then record this checksum as what the server holds.
        case push(checksum: String)
        /// The server already holds this content.
        case upToDate
        /// Do not push at all.
        case refuse(ShareError)
    }

    /// The comparison is between the checksum of the payload built right now
    /// and the checksum of the payload the server is known to hold. Observing
    /// every source of shared content — transcript corrections, notes, the
    /// summary and its versions, the title — and hoping none was missed is the
    /// alternative, and one missed source is a page that silently stops
    /// updating.
    nonisolated static func decide(
        share: MeetingShare,
        payloadChecksum: String
    ) -> Decision {
        // Nothing selected is not a share. Publishing an empty page under a
        // real link is worse than refusing.
        guard !share.includes.isEmpty else { return .refuse(.nothingSelected) }
        guard share.syncedChecksum != payloadChecksum else { return .upToDate }
        return .push(checksum: payloadChecksum)
    }

    /// The server now holds this checksum, and whatever went wrong last time no
    /// longer has anything to say.
    nonisolated static func succeeded(
        _ share: MeetingShare,
        checksum: String,
        at date: Date = Date()
    ) -> MeetingShare {
        var share = share
        share.syncedChecksum = checksum
        share.lastSyncedAt = date
        share.lastError = nil
        return share
    }

    /// A failed push leaves the previously published version intact: it never
    /// blanks the page. `syncedChecksum` and `lastSyncedAt` therefore keep
    /// describing what the server actually holds, which is also what makes the
    /// next attempt retry — the stale checksum still differs from the current
    /// payload's. Recording the new checksum here would mark unsent content as
    /// published and the edit would never leave the machine.
    ///
    /// `lastSyncedAt` is when the server was last brought up to date, not when
    /// it was last spoken to, so a failed attempt does not move it either.
    nonisolated static func failed(
        _ share: MeetingShare,
        error: any Error
    ) -> MeetingShare {
        var share = share
        share.lastError = message(for: error)
        return share
    }

    /// What the share sheet and the `Shared` list print beside a share that did
    /// not sync. Failure is shown, never silent.
    nonisolated static func message(for error: any Error) -> String {
        if let described = (error as? any LocalizedError)?.errorDescription {
            return described
        }
        return error.localizedDescription
    }
}
