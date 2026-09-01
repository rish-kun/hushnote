import AppKit
import Foundation

enum RecordingPowerEvent: Equatable, Sendable {
    case willSleep
    case didWake
}

@MainActor
protocol RecordingPowerEventProviding: AnyObject {
    var events: AsyncStream<RecordingPowerEvent> { get }
    func start()
    func stop()
}

/// Converts NSWorkspace power notifications into a small, injectable stream.
/// Notification payloads never cross isolation; only the semantic event does.
@MainActor
final class WorkspaceRecordingPowerEvents: RecordingPowerEventProviding {
    let events: AsyncStream<RecordingPowerEvent>

    private let notificationCenter: NotificationCenter
    private let continuation: AsyncStream<RecordingPowerEvent>.Continuation
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
        let pair = AsyncStream<RecordingPowerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [continuation] _ in
                continuation.yield(.willSleep)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [continuation] _ in
                continuation.yield(.didWake)
            },
        ]
    }

    func stop() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers = []
    }
}

@MainActor
protocol RecordingSystemActivityManaging: AnyObject {
    func beginRecordingActivity()
    func endRecordingActivity()
}

/// Prevents idle sleep while capture is active. Explicit Sleep and closing a
/// MacBook are intentionally still allowed and handled by the power observer.
@MainActor
final class ProcessRecordingSystemActivity: RecordingSystemActivityManaging {
    private var activity: NSObjectProtocol?

    func beginRecordingActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Recording a Hushnote meeting"
        )
    }

    func endRecordingActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

struct RecordingWakeRetryPolicy: Equatable, Sendable {
    var delaysSeconds: [Double]

    static let standard = RecordingWakeRetryPolicy(
        delaysSeconds: [0.25, 0.5, 1, 2, 4]
    )
}

struct RecordingSleepGap: Equatable, Sendable {
    var timelineMilliseconds: Int64
    var durationMilliseconds: Int64?
    var wallStartedAt: Date
    var wallEndedAt: Date
}

/// Owns recording-only power lifecycle. It intentionally knows nothing about
/// SwiftUI or persistence: the coordinator supplies small callbacks, while
/// tests supply fake power events and clocks.
@MainActor
final class RecordingSleepResilience {
    typealias Prepare = @MainActor @Sendable (_ monotonicSeconds: Double) async throws -> Int64
    typealias Resume = @MainActor @Sendable (_ monotonicSeconds: Double) async throws -> CapturedMediaOmission?
    typealias GapHandler = @MainActor @Sendable (RecordingSleepGap) async -> Void
    typealias FailureHandler = @MainActor @Sendable (Error) -> Void
    typealias Sleep = @Sendable (Double) async -> Void

    private let powerEvents: any RecordingPowerEventProviding
    private let activity: any RecordingSystemActivityManaging
    private let retryPolicy: RecordingWakeRetryPolicy
    private let monotonicClock: @Sendable () -> Double
    private let wallClock: @Sendable () -> Date
    private let sleep: Sleep
    private let prepare: Prepare
    private let resume: Resume
    private let onGap: GapHandler
    private let onRecoveryFailure: FailureHandler

    private var eventTask: Task<Void, Never>?
    private var sleepBoundary: SleepBoundary?

    init(
        powerEvents: any RecordingPowerEventProviding = WorkspaceRecordingPowerEvents(),
        activity: any RecordingSystemActivityManaging = ProcessRecordingSystemActivity(),
        retryPolicy: RecordingWakeRetryPolicy = .standard,
        monotonicClock: @escaping @Sendable () -> Double = {
            ProcessInfo.processInfo.systemUptime
        },
        wallClock: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
        },
        prepare: @escaping Prepare,
        resume: @escaping Resume,
        onGap: @escaping GapHandler,
        onRecoveryFailure: @escaping FailureHandler
    ) {
        self.powerEvents = powerEvents
        self.activity = activity
        self.retryPolicy = retryPolicy
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.sleep = sleep
        self.prepare = prepare
        self.resume = resume
        self.onGap = onGap
        self.onRecoveryFailure = onRecoveryFailure
    }

    func start() {
        guard eventTask == nil else { return }
        activity.beginRecordingActivity()
        powerEvents.start()
        let events = powerEvents.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        powerEvents.stop()
        activity.endRecordingActivity()
        sleepBoundary = nil
    }

    private func handle(_ event: RecordingPowerEvent) async {
        switch event {
        case .willSleep:
            guard sleepBoundary == nil else { return }
            let monotonic = monotonicClock()
            let wall = wallClock()
            do {
                let timeline = try await prepare(monotonic)
                sleepBoundary = SleepBoundary(
                    monotonicSeconds: monotonic,
                    wallClockAt: wall,
                    timelineMilliseconds: timeline
                )
            } catch {
                onRecoveryFailure(error)
            }

        case .didWake:
            guard let boundary = sleepBoundary else { return }
            let wakeMonotonic = monotonicClock()
            let wakeWall = wallClock()
            var finalError: Error?

            for attempt in 0...retryPolicy.delaysSeconds.count {
                if attempt > 0 {
                    await sleep(retryPolicy.delaysSeconds[attempt - 1])
                    guard !Task.isCancelled else { return }
                }
                do {
                    let omission = try await resume(wakeMonotonic)
                    let monotonicDuration = omission?.wallDurationMilliseconds
                        ?? Self.durationMilliseconds(
                            from: boundary.monotonicSeconds,
                            to: wakeMonotonic
                        )
                    let wallDuration = Self.durationMilliseconds(
                        from: boundary.wallClockAt,
                        to: wakeWall
                    )
                    await onGap(RecordingSleepGap(
                        timelineMilliseconds: omission?.atMilliseconds
                            ?? boundary.timelineMilliseconds,
                        durationMilliseconds: monotonicDuration ?? wallDuration,
                        wallStartedAt: boundary.wallClockAt,
                        wallEndedAt: wakeWall
                    ))
                    sleepBoundary = nil
                    return
                } catch {
                    finalError = error
                }
            }
            if let finalError { onRecoveryFailure(finalError) }
        }
    }

    private static func durationMilliseconds(from start: Double, to end: Double) -> Int64? {
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        let milliseconds = (end - start) * 1_000
        guard milliseconds.isFinite else { return nil }
        return Int64(min(milliseconds.rounded(), Double(Int64.max)))
    }

    private static func durationMilliseconds(from start: Date, to end: Date) -> Int64? {
        durationMilliseconds(
            from: start.timeIntervalSinceReferenceDate,
            to: end.timeIntervalSinceReferenceDate
        )
    }

    private struct SleepBoundary {
        var monotonicSeconds: Double
        var wallClockAt: Date
        var timelineMilliseconds: Int64
    }
}
