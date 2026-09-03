import Foundation

/// The durable processing state a meeting shows after capture has handed its
/// audio to the background queue. This must not be inferred from
/// `RecordingPhase`: that phase belongs to the one active capture and returns
/// to idle as soon as Stop has registered the job safely.
struct MeetingFinalizationPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case queued
        case transcribing
        case diarizing
        case merging
        case failed

        var isWorking: Bool {
            self != .failed
        }
    }

    let jobID: UUID
    let kind: Kind
    let progress: Double?
    let title: String
    let detail: String
    let eta: FinalizationETARange?
    let errorMessage: String?
    let unresolvedSessionCount: Int

    var compactText: String {
        if let eta, kind.isWorking {
            return "\(title) · \(eta.userFacingText)"
        }
        return title
    }

    var isRetryable: Bool {
        kind == .failed
    }
}

/// Reduces session-level jobs to the one calm, actionable status a meeting
/// needs. A meeting can have several sessions after Continue recording, so the
/// policy deliberately does not use `MeetingStatus` as a proxy for a job stage.
enum MeetingFinalizationPresentationPolicy {
    nonisolated static func presentation(
        jobs: [FinalizationJob],
        eta: FinalizationETARange?,
        isBlockedByLiveCapture: Bool
    ) -> MeetingFinalizationPresentation? {
        let unresolved = jobs.filter { $0.state != .succeeded }
        guard let primary = unresolved.sorted(by: isHigherPriority).first else { return nil }

        let kind = kind(for: primary.state)
        let detail: String
        switch kind {
        case .queued:
            detail = isBlockedByLiveCapture
                ? "Recording is safe. It will start after the current recording stops."
                : "Recording is safe. It will start automatically."
        case .transcribing:
            detail = "Creating the final transcript from the saved audio."
        case .diarizing:
            detail = "Matching speakers in the final transcript."
        case .merging:
            detail = "Updating this meeting’s combined transcript."
        case .failed:
            detail = primary.errorMessage ?? "The original recording is safe. You can try finalization again."
        }

        return MeetingFinalizationPresentation(
            jobID: primary.id,
            kind: kind,
            progress: kind.isWorking && kind != .queued
                ? min(1, max(0, primary.progress))
                : nil,
            title: title(for: kind),
            detail: detail,
            eta: kind.isWorking ? eta : nil,
            errorMessage: primary.errorMessage,
            unresolvedSessionCount: unresolved.count
        )
    }

    private nonisolated static func kind(for state: FinalizationJobState) -> MeetingFinalizationPresentation.Kind {
        switch state {
        case .queued: .queued
        case .transcribing: .transcribing
        case .diarizing: .diarizing
        case .merging: .merging
        case .failed: .failed
        case .succeeded:
            // Succeeded jobs are filtered before this policy selects one.
            .queued
        }
    }

    private nonisolated static func title(for kind: MeetingFinalizationPresentation.Kind) -> String {
        switch kind {
        case .queued: "Final transcription queued"
        case .transcribing: "Transcribing recording"
        case .diarizing: "Identifying speakers"
        case .merging: "Updating combined transcript"
        case .failed: "Final transcription needs attention"
        }
    }

    /// Work in progress is most useful, then a failure requiring attention,
    /// then queued work. Within a class the newest session wins so continuing a
    /// meeting describes the session most recently appended to it.
    private nonisolated static func isHigherPriority(_ lhs: FinalizationJob, _ rhs: FinalizationJob) -> Bool {
        let left = priority(lhs.state)
        let right = priority(rhs.state)
        if left != right { return left < right }
        if lhs.queuedAt != rhs.queuedAt { return lhs.queuedAt > rhs.queuedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private nonisolated static func priority(_ state: FinalizationJobState) -> Int {
        switch state {
        case .transcribing, .diarizing, .merging: 0
        case .failed: 1
        case .queued: 2
        case .succeeded: 3
        }
    }
}
