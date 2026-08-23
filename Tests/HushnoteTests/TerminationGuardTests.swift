import Testing
@testable import Hushnote

/// Quitting must never silently discard live audio or in-flight model work.
/// ⌘Q and the menu-bar Quit item both reach `NSApp.terminate`, which tears the
/// process down without flushing the CAF converter tail or writing the audio
/// track row, so the guard has to refuse before that happens.
@Suite("Termination guard")
struct TerminationGuardTests {
    @Test(
        "Quitting is unguarded only when nothing is in flight",
        arguments: [RecordingPhase.idle, RecordingPhase.failed("capture stopped")]
    )
    func quitsImmediatelyWhenNothingIsInFlight(phase: RecordingPhase) {
        #expect(TerminationGuard.decision(for: phase) == .terminateNow)
    }

    @Test(
        "Live audio is confirmed before the process dies",
        arguments: [RecordingPhase.recording, RecordingPhase.paused, RecordingPhase.preparing]
    )
    func confirmsWhileAudioIsLive(phase: RecordingPhase) {
        #expect(TerminationGuard.decision(for: phase) == .confirmCapture)
    }

    @Test("Finalizing warns that completed model work would be discarded")
    func confirmsWhileFinalizing() {
        #expect(TerminationGuard.decision(for: .finalizing(0.45)) == .confirmFinalizing)
    }

    @Test("A paused recording is still unflushed audio, not a safe quit point")
    func pausedIsNotASafeQuitPoint() {
        #expect(TerminationGuard.decision(for: .paused) != .terminateNow)
    }

    @Test("Unsaved authored summary text blocks an otherwise safe quit")
    func unsavedSummaryIsGuarded() {
        #expect(
            TerminationGuard.decision(
                for: .idle,
                hasUnsavedSummaryChanges: true
            ) == .confirmUnsavedSummary
        )
    }
}
