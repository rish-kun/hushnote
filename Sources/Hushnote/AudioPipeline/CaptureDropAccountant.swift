import Foundation
import os

/// Keeps score of the audio the IOProc could not hand on.
///
/// Both drop paths used to early-return with no log, no counter and no event,
/// which made the two failures they represent indistinguishable from a quiet
/// meeting: a disk stall that outlasts the queue's headroom, and a format
/// mismatch that is permanent for the session and produces a 0-frame CAF while
/// the UI still says "recording".
///
/// Counting happens on the HAL's real-time thread, so it is an unfair lock
/// around plain integers and nothing more. Reporting is pulled from a timer on
/// another thread — never pushed from the callback.
final class CaptureDropAccountant: @unchecked Sendable {
    /// How many `ownedCopy` failures in a row stop counting as a glitch. The
    /// format is fixed for the life of a session, so a genuine mismatch never
    /// recovers on its own.
    let consecutiveFailureLimit: Int

    private struct State {
        var backpressureBuffers = 0
        var formatMismatchBuffers = 0
        var droppedFrames: Int64 = 0
        var totalDroppedBuffers = 0
        var consecutiveCopyFailures = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(consecutiveFailureLimit: Int = 10) {
        self.consecutiveFailureLimit = consecutiveFailureLimit
    }

    var isPermanentlyFailing: Bool {
        state.withLock { $0.consecutiveCopyFailures >= consecutiveFailureLimit }
    }

    func noteBackpressureDrop(frames: Int64) {
        state.withLock {
            $0.backpressureBuffers += 1
            $0.totalDroppedBuffers += 1
            $0.droppedFrames += max(0, frames)
        }
    }

    func noteCopyFailure(frames: Int64) {
        state.withLock {
            $0.formatMismatchBuffers += 1
            $0.totalDroppedBuffers += 1
            $0.droppedFrames += max(0, frames)
            $0.consecutiveCopyFailures += 1
        }
    }

    func noteCopySuccess() {
        state.withLock {
            guard $0.consecutiveCopyFailures != 0 else { return }
            $0.consecutiveCopyFailures = 0
        }
    }

    /// Returns what was lost since the last call, or nil when nothing was.
    func flush() -> AudioDropReport? {
        state.withLock { state in
            guard state.backpressureBuffers > 0 || state.formatMismatchBuffers > 0 else {
                return nil
            }
            let report = AudioDropReport(
                backpressureBuffers: state.backpressureBuffers,
                formatMismatchBuffers: state.formatMismatchBuffers,
                droppedFrames: state.droppedFrames,
                totalDroppedBuffers: state.totalDroppedBuffers
            )
            state.backpressureBuffers = 0
            state.formatMismatchBuffers = 0
            state.droppedFrames = 0
            return report
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
