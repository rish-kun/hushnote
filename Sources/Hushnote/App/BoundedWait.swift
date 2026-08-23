import Foundation

/// Awaits asynchronous work up to a deadline, abandoning it rather than
/// cancelling it when the deadline passes.
///
/// Structured concurrency cannot express this: a task group waits for every
/// child before it returns, so a hung child defeats the very deadline it was
/// meant to be held to. The two signals race through a one-shot instead, and the
/// loser is simply left to finish on its own.
///
/// The agent CLI runner has the same shape of race, but its version is bound to
/// terminating a `Process` and to `InsightProviderError`, so it is not reusable
/// here.
enum BoundedWait {
    enum Outcome: Equatable, Sendable {
        case finished
        case timedOut
    }

    @discardableResult
    static func finish(
        within limit: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        let gate = Gate()
        Task {
            await work()
            await gate.send(.finished)
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            await gate.send(.timedOut)
        }
        let outcome = await gate.value()
        timer.cancel()
        return outcome
    }

    private actor Gate {
        private var outcome: Outcome?
        private var waiter: CheckedContinuation<Outcome, Never>?

        func send(_ newOutcome: Outcome) {
            guard outcome == nil else { return }
            outcome = newOutcome
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: newOutcome)
            }
        }

        func value() async -> Outcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                } else {
                    waiter = continuation
                }
            }
        }
    }
}
