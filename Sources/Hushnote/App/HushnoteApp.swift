import SwiftUI

@main
struct HushnoteApp: App {
    @State private var state: AppViewState
    @State private var coordinator: AppCoordinator
    @State private var recordingPanel: FloatingRecordingPanelController

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
    }

    var body: some Scene {
        WindowGroup("Hushnote") {
            AppShellView()
                .environment(state)
                .environment(coordinator)
                .frame(minWidth: 940, minHeight: 650)
                .task { await coordinator.bootstrap() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
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
            }
        }

        MenuBarExtra {
            MenuBarMeetingView()
                .environment(state)
                .environment(coordinator)
        } label: {
            Label(
                state.recordingPhase.isCapturing ? "Hushnote is recording" : "Hushnote",
                systemImage: state.recordingPhase.isCapturing ? "record.circle.fill" : "waveform"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarMeetingView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.recordingPhase.isCapturing {
            Text(state.recordingPhase == .paused ? "Paused · \(TimestampButton.format(state.elapsed))" : "Recording · \(TimestampButton.format(state.elapsed))")
            Divider()
            Button(state.recordingPhase == .paused ? "Resume" : "Pause") {
                Task { await coordinator.togglePause() }
            }
            Button("Stop and finalize") { Task { await coordinator.stopMeeting() } }
        } else if state.recordingPhase == .preparing {
            Text("Starting recording…")
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
