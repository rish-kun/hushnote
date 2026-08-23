import AppKit
import Foundation

/// Whether the process may be allowed to die right now.
enum TerminationDecision: Equatable {
    /// Nothing is in flight; quitting loses nothing.
    case terminateNow
    /// Audio is being captured. The CAF converter tail is unflushed and no
    /// `MeetingAudioTrack` row has been written yet.
    case confirmCapture
    /// ASR, diarization, or summary work is running and would be discarded.
    case confirmFinalizing
    /// Authored summary text exists only in the editor buffer.
    case confirmUnsavedSummary
}

/// `NSApp.terminate` tears the process down immediately: `IncrementalCAFWriter.finish()`
/// never runs, `AudioPipeline.stop()` never writes the audio-track row, and a
/// meeting caught mid-finalization loses every minute of model work already spent.
/// Both ⌘Q and the menu-bar Quit item reach it, and the menu-bar item sits one
/// click away while the recording pill is on screen.
enum TerminationGuard {
    static func decision(
        for phase: RecordingPhase,
        hasInsightWork: Bool = false,
        hasUnsavedSummaryChanges: Bool = false
    ) -> TerminationDecision {
        switch phase {
        case .idle, .failed:
            if hasInsightWork { return .confirmFinalizing }
            return hasUnsavedSummaryChanges ? .confirmUnsavedSummary : .terminateNow
        case .preparing, .recording, .paused:
            // `.preparing` counts as live capture: the pipeline may already hold
            // an open take by the time the user reaches for ⌘Q.
            return .confirmCapture
        case .finalizing:
            return .confirmFinalizing
        }
    }
}

/// Intercepts termination so a recording is never lost to a reflexive ⌘Q.
@MainActor
final class HushnoteAppDelegate: NSObject, NSApplicationDelegate {
    /// Set from `HushnoteApp.init` rather than injected, because the delegate is
    /// constructed by SwiftUI and must answer correctly even when no window has
    /// ever been opened — the `MenuBarExtra` keeps the app alive without one.
    static weak var state: AppViewState?
    static weak var coordinator: AppCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state else { return .terminateNow }

        switch TerminationGuard.decision(
            for: state.recordingPhase,
            hasInsightWork: state.hasInsightWork,
            hasUnsavedSummaryChanges: state.hasUnsavedSummaryChanges
        ) {
        case .terminateNow:
            return .terminateNow

        case .confirmCapture:
            let alert = NSAlert()
            alert.messageText = "Hushnote is still recording."
            alert.informativeText = """
                Stopping finalizes this meeting so the audio and transcript are saved. \
                Quitting now would leave the last few seconds of audio unwritten.
                """
            alert.addButton(withTitle: "Stop and Finalize")
            alert.addButton(withTitle: "Keep Recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

            Task { @MainActor in
                await Self.coordinator?.stopMeeting()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater

        case .confirmFinalizing:
            let alert = NSAlert()
            alert.messageText = "Hushnote is still finalizing this meeting."
            alert.informativeText = """
                Quitting now discards the transcription and summary work already completed. \
                The recorded audio is safe, and the meeting can be finalized again from the sidebar.
                """
            alert.addButton(withTitle: "Keep Finalizing")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow

        case .confirmUnsavedSummary:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save summary changes before quitting?"
            alert.informativeText = "Your edited meeting summary has not been saved."
            alert.addButton(withTitle: "Save and Quit")
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit Without Saving")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let meetingID = state.unsavedSummaryMeetingID else { return .terminateCancel }
                Task { @MainActor in
                    let saved = await Self.coordinator?.saveSummary(meetingID: meetingID) == true
                    NSApp.reply(toApplicationShouldTerminate: saved)
                }
                return .terminateLater
            case .alertThirdButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }
}
