import AppKit
import Foundation
import UserNotifications

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
    /// A note is inside `queueMeetingNotes`' 350 ms debounce and has not
    /// reached the database. Nothing to ask the user -- the write takes
    /// milliseconds and there is no decision to make -- so the reply is
    /// deferred just long enough to land it.
    case flushPendingNotes
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
        hasUnsavedSummaryChanges: Bool = false,
        hasUnflushedNotes: Bool = false
    ) -> TerminationDecision {
        switch phase {
        case .idle, .failed:
            if hasInsightWork { return .confirmFinalizing }
            // Ranked by what the user would have to answer for. A summary in
            // the editor is a decision they have not made; a note mid-debounce
            // is a write nobody needs to be asked about. The summary path
            // flushes notes on its way out, so nothing is lost by ordering the
            // question first.
            if hasUnsavedSummaryChanges { return .confirmUnsavedSummary }
            return hasUnflushedNotes ? .flushPendingNotes : .terminateNow
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
final class HushnoteAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set from `HushnoteApp.init` rather than injected, because the delegate is
    /// constructed by SwiftUI and must answer correctly even when no window has
    /// ever been opened — the `MenuBarExtra` keeps the app alive without one.
    static weak var state: AppViewState?
    static weak var coordinator: AppCoordinator?
    static weak var quickNoteShortcut: GlobalQuickNoteShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        UserNotificationFinalizationNotifier.registerCategories(on: center)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.quickNoteShortcut?.stop()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let rawID = userInfo[UserNotificationCategory.meetingIDKey] as? String
        let meetingID = rawID.flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        // Capture only Sendable values before hopping to the main actor. The
        // UNNotificationResponse and completion closure are task-isolated by
        // UserNotifications and must not cross that boundary.
        completionHandler()
        Task { @MainActor in
            if let meetingID,
               action == UserNotificationCategory.openSummary
                    || (action == UNNotificationDefaultActionIdentifier
                        && category == UserNotificationCategory.ready) {
                Self.coordinator?.openMeetingSummary(meetingID)
            } else if let meetingID,
                      action == UserNotificationCategory.reviewTranscript
                        || (action == UNNotificationDefaultActionIdentifier
                            && category == UserNotificationCategory.failed) {
                Self.coordinator?.openMeetingTranscript(meetingID)
            }
            if meetingID != nil { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state else { return .terminateNow }

        switch TerminationGuard.decision(
            for: state.recordingPhase,
            hasInsightWork: state.hasInsightWork,
            hasUnsavedSummaryChanges: state.hasUnsavedSummaryChanges,
            hasUnflushedNotes: !state.notesSaving.isEmpty
        ) {
        case .terminateNow:
            return .terminateNow

        case .flushPendingNotes:
            return flushNotesThenReply()

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
                await Self.coordinator?.flushPendingNotes()
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
            guard alert.runModal() != .alertFirstButtonReturn else { return .terminateCancel }
            return flushNotesThenReply()

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
                    if saved { await Self.coordinator?.flushPendingNotes() }
                    NSApp.reply(toApplicationShouldTerminate: saved)
                }
                return .terminateLater
            case .alertThirdButtonReturn:
                // Declining to save the *summary* says nothing about a note
                // typed a moment ago, which the user never chose to discard.
                return flushNotesThenReply()
            default:
                return .terminateCancel
            }
        }
    }

    /// Defers the reply only long enough for a debounced note to land.
    ///
    /// Every branch that ends in the process dying passes through here, because
    /// `queueMeetingNotes`' 350 ms window is open precisely when someone
    /// reaches for ⌘Q mid-sentence -- and unlike an unsaved summary, an
    /// unwritten note raises no question worth putting in front of anyone.
    private func flushNotesThenReply() -> NSApplication.TerminateReply {
        guard let coordinator = Self.coordinator,
              Self.state?.notesSaving.isEmpty == false
        else { return .terminateNow }

        Task { @MainActor in
            await coordinator.flushPendingNotes()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
