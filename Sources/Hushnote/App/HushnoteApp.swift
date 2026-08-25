import SwiftUI

@main
struct HushnoteApp: App {
    @AppStorage(AppPreferences.appearanceUserDefaultsKey)
    private var appearanceRawValue = AppearanceMode.system.rawValue
    @State private var state: AppViewState
    @State private var coordinator: AppCoordinator
    @State private var recordingPanel: FloatingRecordingPanelController
    @NSApplicationDelegateAdaptor(HushnoteAppDelegate.self) private var appDelegate

    init() {
        let state = AppViewState()
        let coordinator = AppCoordinator(state: state)
        _state = State(initialValue: state)
        _coordinator = State(initialValue: coordinator)
        _recordingPanel = State(
            initialValue: FloatingRecordingPanelController(
                state: state,
                coordinator: coordinator
            )
        )
        // Published before any window exists so ⌘Q is guarded even when the app
        // is running from the menu bar alone.
        HushnoteAppDelegate.state = state
        HushnoteAppDelegate.coordinator = coordinator
    }

    var body: some Scene {
        WindowGroup("Hushnote") {
            AppShellView()
                .environment(state)
                .environment(coordinator)
                // The shell can intentionally collapse its detail canvas, but
                // never below a usable keyboard and sidebar target size.
                .frame(minWidth: 760, minHeight: 560)
                .preferredColorScheme(preferredColorScheme)
                .task { await coordinator.bootstrap() }
        }
        .defaultSize(width: 1_240, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            HushnoteAboutCommands()
            // The toggle itself lives in a titlebar accessory so it cannot
            // drift as the split view collapses, and a hosted titlebar view is
            // outside the menu responder chain. The shortcut belongs here.
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .hushnoteToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(after: .newItem) {
                if state.recordingPhase.isCapturing {
                    Button(state.recordingPhase == .paused ? "Resume recording" : "Pause recording") {
                        Task { await coordinator.togglePause() }
                    }
                    Button("Stop recording") { Task { await coordinator.stopMeeting() } }
                        .keyboardShortcut(".", modifiers: [.command, .shift])
                } else if !state.recordingPhase.isBusy {
                    Button("New Meeting Note") { Task { await coordinator.createMeetingNote() } }
                        .keyboardShortcut("n", modifiers: [.command])
                }
                Button("New Folder") {
                    NotificationCenter.default.post(name: .hushnoteNewFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Search Meetings") {
                    NotificationCenter.default.post(name: .hushnoteSearchMeetings, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                // Only while there is a clock to stamp from. Off a recording
                // the transcript's end is the end of the meeting, which is not
                // a moment anyone means.
                if state.recordingPhase.isCapturing {
                    Button("Stamp This Moment") {
                        NotificationCenter.default.post(name: .hushnoteStampMoment, object: nil)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }
        }

        MenuBarExtra {
            MenuBarMeetingView()
                .environment(state)
                .environment(coordinator)
        } label: {
            Label {
                Text(state.recordingPhase.isCapturing ? "Hushnote is recording" : "Hushnote")
            } icon: {
                Image(nsImage: HushnoteBrandImages.menuBarTemplate(
                    isRecording: state.recordingPhase.isCapturing
                ))
            }
        }
        .menuBarExtraStyle(.menu)

        Window("About Hushnote", id: AboutHushnoteView.windowID) {
            AboutHushnoteView()
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceRawValue) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct MenuBarMeetingView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.recordingPhase.isCapturing {
            Text("\(RecordingStatusText.label(for: state.recordingPhase)) · \(DurationText.clock(state.elapsed))")
            Divider()
            Button(state.recordingPhase == .paused ? "Resume" : "Pause") {
                Task { await coordinator.togglePause() }
            }
            Button("Stop and finalize") { Task { await coordinator.stopMeeting() } }
        } else if state.recordingPhase == .preparing {
            Text(RecordingStatusText.label(for: .preparing))
        } else if case .finalizing = state.recordingPhase {
            Text(state.finalizationLabel)
        } else {
            Button("New Meeting Note") { Task { await coordinator.createMeetingNote() } }
        }
        Divider()
        Button("Open Hushnote") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Hushnote") { NSApp.terminate(nil) }
    }
}
