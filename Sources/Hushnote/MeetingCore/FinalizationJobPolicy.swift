import Foundation

/// Guards the durable job lifecycle against impossible or stale writes.
///
/// Progress updates may remain in one state. A recoverable failure or a job
/// found running after relaunch returns to `.queued`; a succeeded job is
/// immutable apart from notification bookkeeping.
enum FinalizationJobTransitionPolicy {
    nonisolated static func allows(
        from current: FinalizationJobState,
        to proposed: FinalizationJobState
    ) -> Bool {
        if current == proposed { return true }

        return switch (current, proposed) {
        case (.queued, .transcribing),
             (.transcribing, .diarizing),
             (.transcribing, .failed),
             (.transcribing, .queued),
             (.diarizing, .merging),
             (.diarizing, .succeeded),
             (.diarizing, .failed),
             (.diarizing, .queued),
             (.merging, .succeeded),
             (.merging, .failed),
             (.merging, .queued),
             (.failed, .queued):
            true
        default:
            false
        }
    }

    nonisolated static func sessionState(for jobState: FinalizationJobState) -> RecordingSessionState {
        switch jobState {
        case .queued:
            .captured
        case .transcribing, .diarizing, .merging:
            .processing
        case .succeeded:
            .ready
        case .failed:
            .failed
        }
    }

    nonisolated static func isRunning(_ state: FinalizationJobState) -> Bool {
        switch state {
        case .transcribing, .diarizing, .merging: true
        case .queued, .succeeded, .failed: false
        }
    }
}

public struct RecordingWorkRecoveryReport: Equatable, Sendable {
    public var interruptedSessionIDs: [UUID]
    public var resetProcessingSessionIDs: [UUID]
    public var requeuedJobIDs: [UUID]

    public init(
        interruptedSessionIDs: [UUID] = [],
        resetProcessingSessionIDs: [UUID] = [],
        requeuedJobIDs: [UUID] = []
    ) {
        self.interruptedSessionIDs = interruptedSessionIDs
        self.resetProcessingSessionIDs = resetProcessingSessionIDs
        self.requeuedJobIDs = requeuedJobIDs
    }
}
