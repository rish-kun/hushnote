import Foundation
import Testing
@testable import Hushnote

/// `.onChange(of: state.searchText)` spawned an uncancelled Task per keystroke.
/// Typing "quarterly review" launched sixteen concurrent FTS5 queries, and
/// nothing sequenced the results -- whichever finished last won, so the user
/// could be left looking at results for a *prefix* of what they had typed.
/// Debouncing with `.task(id:)` cancels the previous run, but cancellation is
/// not instantaneous and a query already in flight can still return, so the
/// result also has to name the query it answers.
@Suite("Search sequencing")
struct SearchSequencingTests {
    @MainActor
    @Test("A result for what the user has typed is applied")
    func currentResultIsApplied() {
        let state = AppViewState()
        let match = UUID()
        state.searchText = "quarterly review"

        state.applySearchMatches([match], for: "quarterly review")

        #expect(state.searchMatchedMeetingIDs == [match])
    }

    /// The bug: a slow query for "quarter" landing after a fast one for
    /// "quarterly review" used to overwrite it.
    @MainActor
    @Test("A result for a query the user has moved past is discarded")
    func staleResultIsDiscarded() {
        let state = AppViewState()
        let current = UUID()
        state.searchText = "quarterly review"
        state.applySearchMatches([current], for: "quarterly review")

        state.applySearchMatches([UUID(), UUID()], for: "quarter")

        #expect(state.searchMatchedMeetingIDs == [current])
    }

    @MainActor
    @Test("Clearing the field clears the filter")
    func clearingIsApplied() {
        let state = AppViewState()
        state.searchText = "budget"
        state.applySearchMatches([UUID()], for: "budget")

        state.searchText = ""
        state.applySearchMatches(nil, for: "")

        #expect(state.searchMatchedMeetingIDs == nil)
    }

    /// The field's whitespace is not part of what the user meant, and the
    /// coordinator trims before querying -- so a trimmed answer still matches an
    /// untrimmed field.
    @MainActor
    @Test("Whitespace does not make a result look stale")
    func trimmingDoesNotOrphanAResult() {
        let state = AppViewState()
        let match = UUID()
        state.searchText = "  budget "

        state.applySearchMatches([match], for: "budget")

        #expect(state.searchMatchedMeetingIDs == [match])
    }
}
