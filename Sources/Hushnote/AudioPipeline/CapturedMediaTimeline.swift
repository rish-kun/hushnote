import Foundation

/// Why a capture session deliberately stopped advancing its media clock.
///
/// Both cases omit wall time from the captured-media timeline. They remain
/// distinct because the workspace describes a user-requested pause and a Mac
/// sleep differently.
enum CapturedMediaSuspensionReason: Equatable, Sendable {
    case pause
    case sleep
}

/// One buffer's address in the meeting-wide captured-media timeline.
///
/// Ranges from every source use the same coordinate space. Separate sources
/// may overlap, as they should when both sides of a conversation were captured
/// at once, while ranges for any one source never move backwards.
struct CapturedMediaRange: Equatable, Sendable {
    var source: AudioSource
    var startMilliseconds: Int64
    var endMilliseconds: Int64
}

/// Wall time intentionally omitted from the media timeline.
struct CapturedMediaOmission: Equatable, Sendable {
    var reason: CapturedMediaSuspensionReason
    /// The stable media position at which capture stopped and later resumed.
    var atMilliseconds: Int64
    /// Nil when either supplied monotonic timestamp was unusable. Reporting an
    /// unknown duration honestly is preferable to inventing a zero-length gap.
    var wallDurationMilliseconds: Int64?
}

/// Maps independently delivered source buffers onto one captured-media clock.
///
/// Presentation timestamps are expected to share a monotonic host-time basis.
/// The first valid timestamp anchors that basis to the session's meeting
/// offset. Invalid timestamps fall back to the latest durably represented
/// position, so a malformed callback cannot poison later arithmetic.
///
/// Suspension freezes `positionMilliseconds`. The first valid buffer after a
/// resume establishes a fresh host-time anchor at that frozen position, which
/// excludes both the requested wall-time gap and any device start-up delay
/// during which no audio was captured.
struct CapturedMediaTimeline: Sendable {
    private(set) var positionMilliseconds: Int64
    private(set) var isSuspended = false

    private let meetingStartMilliseconds: Int64
    private var anchorPresentationSeconds: Double?
    private var anchorTimelineMilliseconds: Int64
    private var needsResumeAnchor = false
    private var sourceEnds: [AudioSource: Int64] = [:]
    private var suspension: Suspension?

    init(meetingStartMilliseconds: Int64 = 0) {
        let start = max(0, meetingStartMilliseconds)
        self.meetingStartMilliseconds = start
        positionMilliseconds = start
        anchorTimelineMilliseconds = start
    }

    mutating func beginTake(for source: AudioSource) -> Int64 {
        sourceEnds[source] = max(sourceEnds[source] ?? meetingStartMilliseconds, positionMilliseconds)
        return positionMilliseconds
    }

    /// Addresses a buffer in meeting time. A suspended timeline refuses the
    /// buffer rather than representing the omitted interval as recorded audio.
    mutating func append(
        source: AudioSource,
        presentationSeconds: Double,
        durationMilliseconds: Int64
    ) -> CapturedMediaRange? {
        guard !isSuspended else { return nil }

        let duration = max(0, durationMilliseconds)
        let proposedStart: Int64
        if presentationSeconds.isFinite {
            if anchorPresentationSeconds == nil || needsResumeAnchor {
                anchorPresentationSeconds = presentationSeconds
                anchorTimelineMilliseconds = positionMilliseconds
                needsResumeAnchor = false
            }
            proposedStart = mappedMilliseconds(for: presentationSeconds)
                ?? positionMilliseconds
        } else {
            // There is no defensible cross-source alignment without a usable
            // timestamp. Append after everything represented so far, then let
            // the next valid callback establish or restore the shared anchor.
            proposedStart = positionMilliseconds
            if anchorPresentationSeconds == nil || needsResumeAnchor {
                anchorTimelineMilliseconds = positionMilliseconds
                needsResumeAnchor = true
            }
        }

        // Presentation clocks align independently delivered sources, but they
        // must not manufacture media for a period in which no source wrote a
        // frame. A callback that jumps ahead of the current captured position
        // (device restart, clock reset, or a synthetic test clock) therefore
        // resumes at the durable frontier. Sources may still overlap behind
        // that frontier, which is what preserves cross-source alignment.
        let alignedStart = min(proposedStart, positionMilliseconds)
        let start = max(
            meetingStartMilliseconds,
            sourceEnds[source] ?? meetingStartMilliseconds,
            alignedStart
        )
        let end = Self.addingWithoutOverflow(start, duration)
        sourceEnds[source] = end
        positionMilliseconds = max(positionMilliseconds, end)
        if needsResumeAnchor {
            // Any malformed post-resume buffers are real captured media. A
            // later valid timestamp must resume after them, not at the older
            // position that existed when Resume was pressed.
            anchorTimelineMilliseconds = positionMilliseconds
        }
        return CapturedMediaRange(
            source: source,
            startMilliseconds: start,
            endMilliseconds: end
        )
    }

    /// Freezes the media clock. Repeated suspension notifications are
    /// idempotent; the first reason and wall-time boundary own the interval.
    mutating func suspend(
        reason: CapturedMediaSuspensionReason,
        at monotonicSeconds: Double
    ) {
        guard !isSuspended else { return }
        isSuspended = true
        suspension = Suspension(
            reason: reason,
            monotonicSeconds: monotonicSeconds.isFinite ? monotonicSeconds : nil,
            timelineMilliseconds: positionMilliseconds
        )
    }

    /// Unfreezes the clock and reports the omitted wall interval. The next
    /// valid source timestamp is re-anchored to the frozen media position.
    @discardableResult
    mutating func resume(at monotonicSeconds: Double) -> CapturedMediaOmission? {
        guard isSuspended, let suspension else { return nil }
        isSuspended = false
        self.suspension = nil
        needsResumeAnchor = true
        anchorTimelineMilliseconds = positionMilliseconds

        let wallDuration: Int64?
        if let start = suspension.monotonicSeconds,
           monotonicSeconds.isFinite,
           monotonicSeconds >= start {
            wallDuration = Self.milliseconds(monotonicSeconds - start)
        } else {
            wallDuration = nil
        }
        return CapturedMediaOmission(
            reason: suspension.reason,
            atMilliseconds: suspension.timelineMilliseconds,
            wallDurationMilliseconds: wallDuration
        )
    }

    private func mappedMilliseconds(for presentationSeconds: Double) -> Int64? {
        guard let anchorPresentationSeconds else { return nil }
        let delta = presentationSeconds - anchorPresentationSeconds
        guard delta.isFinite, let deltaMilliseconds = Self.signedMilliseconds(delta) else {
            return nil
        }
        return Self.addingWithoutOverflow(anchorTimelineMilliseconds, deltaMilliseconds)
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let value = seconds * 1_000
        guard value.isFinite else { return nil }
        if value >= Double(Int64.max) { return Int64.max }
        return Int64(value.rounded())
    }

    private static func signedMilliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite else { return nil }
        let value = seconds * 1_000
        guard value.isFinite else { return nil }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded())
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? Int64.max : Int64.min
    }

    private struct Suspension: Sendable {
        var reason: CapturedMediaSuspensionReason
        var monotonicSeconds: Double?
        var timelineMilliseconds: Int64
    }
}

/// Serializes independently delivered source buffers onto one media timeline.
///
/// A system tap and an input-device tap run on different capture queues. This
/// coordinator is the narrow shared owner that makes a pause atomic with the
/// durable write and timeline assignment: once suspension wins the lock, no
/// source can write audio that has no honest address in meeting time.
final class CapturedMediaTimelineCoordinator: @unchecked Sendable {
    private let condition = NSCondition()
    private var timeline: CapturedMediaTimeline
    private var state = State.active
    private var inFlightRecords = 0

    init(meetingStartMilliseconds: Int64 = 0) {
        timeline = CapturedMediaTimeline(
            meetingStartMilliseconds: meetingStartMilliseconds
        )
    }

    var positionMilliseconds: Int64 {
        condition.withLock { timeline.positionMilliseconds }
    }

    var isSuspended: Bool {
        condition.withLock { state != .active }
    }

    func beginTake(for source: AudioSource) -> Int64 {
        condition.withLock { timeline.beginTake(for: source) }
    }

    /// Admits a write while capture is active, performs it without holding the
    /// timeline lock, then commits its successfully written frames to meeting
    /// time. The operation is never invoked once suspension has begun.
    func record<Value>(
        source: AudioSource,
        presentationSeconds: Double,
        operation: () throws -> (value: Value, durationMilliseconds: Int64)
    ) throws -> (value: Value, range: CapturedMediaRange)? {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            return nil
        }
        inFlightRecords += 1
        condition.unlock()

        let result: (value: Value, durationMilliseconds: Int64)
        do {
            // Source writers are deliberately independent. A slow microphone
            // disk write must not hold the timeline lock or stall system audio.
            result = try operation()
        } catch {
            completeInFlightRecord()
            throw error
        }

        condition.lock()
        let range = timeline.append(
            source: source,
            presentationSeconds: presentationSeconds,
            durationMilliseconds: result.durationMilliseconds
        )
        inFlightRecords -= 1
        if inFlightRecords == 0 { condition.broadcast() }
        condition.unlock()

        guard let range else { return nil }
        return (result.value, range)
    }

    private func completeInFlightRecord() {
        condition.lock()
        inFlightRecords -= 1
        if inFlightRecords == 0 { condition.broadcast() }
        condition.unlock()
    }

    private func waitForSuspensionToFinish() {
        while state == .suspending {
            condition.wait()
        }
    }

    func suspend(
        reason: CapturedMediaSuspensionReason,
        at monotonicSeconds: Double
    ) {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            return
        }
        // Close admission before waiting. Already-admitted writes commit to
        // the timeline; callbacks arriving after this boundary write nothing.
        state = .suspending
        while inFlightRecords > 0 { condition.wait() }
        timeline.suspend(reason: reason, at: monotonicSeconds)
        state = .suspended
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func resume(at monotonicSeconds: Double) -> CapturedMediaOmission? {
        condition.lock()
        waitForSuspensionToFinish()
        guard state == .suspended else {
            condition.unlock()
            return nil
        }
        let omission = timeline.resume(at: monotonicSeconds)
        state = .active
        condition.broadcast()
        condition.unlock()
        return omission
    }

    private enum State {
        case active
        case suspending
        case suspended
    }
}
