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

    /// `queueMeetingNotes` waits 350 ms before writing, so a sentence being
    /// typed is one write rather than forty. Quitting is exactly when that
    /// window is open: a reflexive ⌘Q lands mid-sentence far more often than
    /// it lands in a lull, and the note went with the process.
    @Test("A note still inside its debounce defers the quit long enough to land")
    func unflushedNotesDeferTermination() {
        #expect(
            TerminationGuard.decision(for: .idle, hasUnflushedNotes: true) == .flushPendingNotes
        )
        #expect(
            TerminationGuard.decision(for: .failed("stopped"), hasUnflushedNotes: true)
                == .flushPendingNotes
        )
    }

    /// Flushing raises no question, so it must never displace one. The summary
    /// path flushes notes on its way out, which is why ordering it first loses
    /// nothing.
    @Test("A question the user must answer outranks a write nobody need be asked about")
    func questionsOutrankTheFlush() {
        #expect(
            TerminationGuard.decision(
                for: .idle,
                hasUnsavedSummaryChanges: true,
                hasUnflushedNotes: true
            ) == .confirmUnsavedSummary
        )
        #expect(
            TerminationGuard.decision(
                for: .idle,
                hasInsightWork: true,
                hasUnflushedNotes: true
            ) == .confirmFinalizing
        )
        #expect(
            TerminationGuard.decision(for: .recording, hasUnflushedNotes: true) == .confirmCapture
        )
    }
}
