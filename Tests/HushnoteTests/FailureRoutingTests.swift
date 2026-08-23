import Foundation
import Testing
@testable import Hushnote

/// Six failure paths all wrote to `state.insights.error`, which is rendered in
/// exactly one place: the summary workspace. A note save that failed while the
/// user was on the Notes tab was completely invisible, and they kept typing
/// into an editor that no longer persisted. A failed export put its error on a
/// tab the user was not on, so the file simply never appeared.
@Suite("Failure routing")
struct FailureRoutingTests {
    @Test("A failure the user cannot see from where they are goes to the app")
    func persistenceAndExportFailuresReachTheApp() {
        #expect(
            FailureRoute.route(for: .noteSave)
                == .appAlert(title: "Your notes are not being saved")
        )
        #expect(
            FailureRoute.route(for: .transcriptEditSave)
                == .appAlert(title: "Your transcript correction was not saved")
        )
        #expect(
            FailureRoute.route(for: .export)
                == .appAlert(title: "The export did not finish")
        )
        #expect(
            FailureRoute.route(for: .meetingLoad)
                == .appAlert(title: "This meeting could not be opened")
        )
        #expect(
            FailureRoute.route(for: .summarySave)
                == .appAlert(title: "Your summary was not saved")
        )
        #expect(
            FailureRoute.route(for: .meetingRename)
                == .appAlert(title: "The meeting name was not saved")
        )
    }

    /// An insight failure belongs where the request was made and where the
    /// result would have appeared. Sending it to a modal instead would be worse,
    /// not better.
    @Test("An insight failure stays in the workspace that asked for it")
    func insightFailuresStayInTheWorkspace() {
        #expect(FailureRoute.route(for: .insightGeneration) == .insightWorkspace)
        #expect(FailureRoute.route(for: .questionAnswering) == .insightWorkspace)
    }

    @MainActor
    @Test("Reporting a failure fills the channel that failure belongs to")
    func reportingUsesTheRoutedChannel() {
        let state = AppViewState()

        state.report(.noteSave, "The database is locked.")
        #expect(state.alert?.title == "Your notes are not being saved")
        #expect(state.alert?.message == "The database is locked.")
        #expect(state.insights.error == nil)

        state.dismissAlert()
        #expect(state.alert == nil)

        state.report(.insightGeneration, "The selected provider is not ready.")
        #expect(state.insights.error == "The selected provider is not ready.")
        #expect(state.alert == nil)
    }

    /// A summary that failed to regenerate must not also raise a modal, and a
    /// note that failed to save must not overwrite the summary's own error.
    @MainActor
    @Test("The two channels do not overwrite each other")
    func channelsAreIndependent() {
        let state = AppViewState()

        state.report(.insightGeneration, "The provider timed out.")
        state.report(.export, "The destination is read-only.")

        #expect(state.insights.error == "The provider timed out.")
        #expect(state.alert?.message == "The destination is read-only.")
    }
}
