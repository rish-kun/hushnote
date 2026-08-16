import Foundation
import os

/// Raises a failure when the tap stops delivering audio.
///
/// Sleep/wake tears the aggregate device down, a revoked permission stops the
/// HAL, and a mid-meeting device change can leave the IOProc installed but
/// permanently silent. From here all three look identical: the callback stops
/// firing while `running` still reads true and the UI still says "recording".
/// One deadline covers all of them.
///
/// The deadline is decided by `check(at:)`, a pure function of the times it is
/// given, so the rule is testable without waiting on a real clock. Production
/// drives it from a timer.
final class CaptureStallWatchdog: @unchecked Sendable {
    /// Reports how long the tap had been silent, in seconds.
    var onStall: (@Sendable (TimeInterval) -> Void)? {
        get { state.withLock { $0.onStall } }
        set { state.withLock { $0.onStall = newValue } }
    }

    let threshold: TimeInterval

    private struct State {
        var lastActivity: TimeInterval?
        var isArmed = false
        var hasReported = false
        var onStall: (@Sendable (TimeInterval) -> Void)?
    }

    // An unfair lock, because `noteActivity` is called from the HAL's
    // real-time thread on every buffer.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timerQueue = DispatchQueue(label: "com.hushnote.capture-watchdog")
    private var timer: DispatchSourceTimer?
    private let clock: @Sendable () -> TimeInterval

    init(
        threshold: TimeInterval = 3,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.threshold = threshold
        self.clock = clock
    }

    deinit {
        timer?.cancel()
    }

    /// Arms the deadline. The device is given the same grace as any later gap,
    /// which also covers a start that never produces a first buffer at all.
    func begin(at now: TimeInterval) {
        state.withLock {
            $0.lastActivity = now
            $0.isArmed = true
            $0.hasReported = false
        }
    }

    func noteActivity(at now: TimeInterval) {
        state.withLock {
            $0.lastActivity = now
            $0.hasReported = false
        }
    }

    /// A paused meeting is silent on purpose.
    func suspend() {
        state.withLock { $0.isArmed = false }
    }

    func resume(at now: TimeInterval) {
        begin(at: now)
    }

    func stop() {
        state.withLock {
            $0.isArmed = false
            $0.lastActivity = nil
        }
    }

    func check(at now: TimeInterval) {
        let report: (handler: @Sendable (TimeInterval) -> Void, silence: TimeInterval)? = state.withLock {
            guard $0.isArmed, !$0.hasReported, let lastActivity = $0.lastActivity else { return nil }
            let silence = now - lastActivity
            guard silence > threshold else { return nil }
            $0.hasReported = true
            guard let handler = $0.onStall else { return nil }
            return (handler, silence)
        }
        guard let report else { return }
        report.handler(report.silence)
    }

    // MARK: - Production driving

    func startTimer() {
        timerQueue.sync {
            timer?.cancel()
            let created = DispatchSource.makeTimerSource(queue: timerQueue)
            // Checking four times per threshold bounds the reporting delay to
            // well under a second past the deadline.
            let interval = max(0.1, threshold / 4)
            created.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            created.setEventHandler { [weak self] in
                guard let self else { return }
                self.check(at: self.clock())
            }
            created.resume()
            timer = created
        }
    }

    func stopTimer() {
        timerQueue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// The clock this watchdog measures against, so callers can stamp events
    /// with the same time base.
    func now() -> TimeInterval { clock() }
}
