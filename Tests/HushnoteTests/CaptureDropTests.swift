import Foundation
import Testing
@testable import Hushnote

/// Both drop paths in the IOProc used to early-return with no log, no counter
/// and no event. Because the recovery CAF is bare continuous PCM with no
/// timestamps, a dropped buffer *shortens* the file rather than leaving a gap,
/// so everything after it shifts earlier relative to the live transcript and
/// the diarization.
@Suite("Dropped capture buffers")
struct CaptureDropTests {
    @Test("Backpressure drops are counted and reported")
    func countsBackpressureDrops() {
        let accountant = CaptureDropAccountant(consecutiveFailureLimit: 10)

        accountant.noteBackpressureDrop(frames: 1_024)
        accountant.noteBackpressureDrop(frames: 1_024)
        accountant.noteBackpressureDrop(frames: 512)

        let report = accountant.flush()
        #expect(report?.backpressureBuffers == 3)
        #expect(report?.droppedFrames == 2_560)
        #expect(report?.totalDroppedBuffers == 3)
    }

    @Test("A quiet window reports nothing")
    func silentWindowReportsNothing() {
        let accountant = CaptureDropAccountant(consecutiveFailureLimit: 10)
        #expect(accountant.flush() == nil)

        accountant.noteBackpressureDrop(frames: 1_024)
        #expect(accountant.flush() != nil)
        #expect(accountant.flush() == nil, "a report must not repeat itself every tick")
    }

    @Test("Session totals survive across reports")
    func totalsAccumulate() {
        let accountant = CaptureDropAccountant(consecutiveFailureLimit: 10)

        accountant.noteBackpressureDrop(frames: 1_024)
        _ = accountant.flush()
        accountant.noteCopyFailure(frames: 1_024)

        let report = accountant.flush()
        #expect(report?.formatMismatchBuffers == 1)
        #expect(report?.backpressureBuffers == 0)
        #expect(report?.totalDroppedBuffers == 2)
    }

    /// `ownedCopy` returns nil on a format mismatch, which is permanent for the
    /// session: every subsequent buffer fails the same way, leaving a 0-frame
    /// CAF behind a UI that still says "recording". That is a failure, not a
    /// drop.
    @Test("A run of copy failures is a hard failure, not a drop")
    func consecutiveCopyFailuresAreFatal() {
        let accountant = CaptureDropAccountant(consecutiveFailureLimit: 10)

        for _ in 0..<9 {
            accountant.noteCopyFailure(frames: 1_024)
        }
        #expect(!accountant.isPermanentlyFailing, "nine failures could still be a glitch")

        accountant.noteCopyFailure(frames: 1_024)
        #expect(accountant.isPermanentlyFailing)
    }

    @Test("A buffer that copies cleanly clears the run")
    func successResetsTheRun() {
        let accountant = CaptureDropAccountant(consecutiveFailureLimit: 10)

        for _ in 0..<9 {
            accountant.noteCopyFailure(frames: 1_024)
        }
        accountant.noteCopySuccess()
        for _ in 0..<9 {
            accountant.noteCopyFailure(frames: 1_024)
        }

        #expect(!accountant.isPermanentlyFailing, "the run was broken by a good buffer")
    }
}
