import Foundation
import Testing
@testable import Hushnote

/// Finalization waits for the live Whisper engine to release its decoder before
/// the final pass loads a second 600 MB model, so the wait has to actually
/// return — both when the teardown finishes and when a Core ML decode wedges it.
@Suite("A bounded wait gives up rather than hanging")
struct BoundedWaitTests {
    @Test("Work that finishes is awaited, not merely started")
    func finishedWorkIsAwaited() async {
        let done = Flag()
        let outcome = await BoundedWait.finish(within: .seconds(10)) {
            try? await Task.sleep(for: .milliseconds(10))
            await done.raise()
        }

        #expect(outcome == .finished)
        #expect(await done.isRaised)
    }

    @Test("Work that never returns costs the deadline and nothing more")
    func hungWorkIsAbandoned() async {
        let started = ContinuousClock.now
        let outcome = await BoundedWait.finish(within: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(60))
        }
        let elapsed = ContinuousClock.now - started

        #expect(outcome == .timedOut)
        #expect(elapsed < .seconds(5))
    }

    @Test("The first signal wins and the timer cannot overturn it")
    func theOutcomeIsDecidedOnce() async {
        for _ in 0..<20 {
            let outcome = await BoundedWait.finish(within: .seconds(30)) {}
            #expect(outcome == .finished)
        }
    }
}

private actor Flag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}
