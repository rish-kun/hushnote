import SwiftUI

struct AppShellView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            List(selection: $state.selection) {
                Section {
                    Label("Meetings", systemImage: "text.book.closed")
                        .tag(SidebarDestination.meetings)
                    Label("Models", systemImage: "cpu")
                        .tag(SidebarDestination.models)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .tag(SidebarDestination.settings)
                }

                if !state.filteredMeetings.isEmpty {
                    Section("Recent") {
                        ForEach(state.filteredMeetings.prefix(8)) { meeting in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title)
                                    .lineLimit(1)
                                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarDestination.meeting(meeting.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: HushnoteTheme.sidebarWidth, max: 300)
            .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search meetings")
            .onChange(of: state.searchText) { _, query in
                Task { await coordinator.searchMeetings(query) }
            }
            .safeAreaInset(edge: .bottom) {
                recordingSidebarFooter
            }
        } detail: {
            VStack(spacing: 0) {
                if case .failed(let failure) = state.recordingPhase {
                    recordingErrorBanner(failure)
                }
                detail
                    .paperBackground()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await coordinator.createMeetingNote() }
                } label: {
                    Label("New Meeting Note", systemImage: "square.and.pencil")
                }
                .disabled(state.recordingPhase.isBusy)
            }
        }
        // The one place a saving or exporting failure is surfaced. These happen
        // behind the user's attention, so they cannot be left on whichever tab
        // raised them.
        .alert(
            state.alert?.title ?? "",
            isPresented: Binding(
                get: { state.alert != nil },
                set: { if !$0 { state.dismissAlert() } }
            ),
            presenting: state.alert
        ) { _ in
            Button("OK", role: .cancel) { state.dismissAlert() }
        } message: { alert in
            Text(alert.message)
        }
    }

    private func recordingErrorBanner(_ failure: RecordingFailure) -> some View {
        @Bindable var state = state

        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HushnoteTheme.vermilionInk)
            Text(failure.message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            ForEach(Array(failure.remedies.enumerated()), id: \.offset) { _, remedy in
                remedyButton(remedy)
            }
            Button {
                state.dismissFailure()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss this message")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(HushnoteTheme.vermilion.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hushnote ran into a problem. \(failure.message)")
    }

    @ViewBuilder
    private func remedyButton(_ remedy: FailureRemedy) -> some View {
        @Bindable var state = state

        switch remedy {
        case .openPrivacySettings:
            Button("System Audio Settings") { coordinator.openPrivacySettings() }
                .buttonStyle(.bordered)
        case .retryRecording(let id):
            Button("Try Again") { Task { await coordinator.startMeeting(meetingID: id) } }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.vermilion)
        case .retryFinalization(let id):
            Button("Finalize Again") { Task { await coordinator.recoverMeeting(id) } }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.vermilion)
        case .openModels:
            Button("Open Models") { state.selection = .models }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.inkFill)
        case .openSettings:
            Button("Open Settings") { state.selection = .settings }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.inkFill)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .meetings, nil:
            MeetingsHomeView()
        case .models:
            ModelManagerView()
        case .settings:
            SettingsView()
        case .meeting(let id):
            MeetingWorkspaceView(meetingID: id)
        }
    }

    @ViewBuilder
    private var recordingSidebarFooter: some View {
        if state.recordingPhase.isCapturing {
            Button {
                if let id = state.activeMeetingID { state.selection = .meeting(id) }
            } label: {
                HStack(spacing: 10) {
                    RecordingPulse(isActive: state.recordingPhase == .recording)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.recordingPhase == .paused ? "Recording paused" : "Recording")
                            .font(.callout.weight(.semibold))
                        Text(DurationText.clock(state.elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        } else if state.recordingPhase == .preparing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting recording…").font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        } else if case .finalizing = state.recordingPhase {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(state.finalizationLabel).font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

struct MeetingsHomeView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meeting notebook")
                        .font(.system(size: 32, weight: .semibold, design: .serif))
                    Text("Private recordings, accurate transcripts, useful follow-through.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Meeting Note") { Task { await coordinator.createMeetingNote() } }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.inkFill)
                    .disabled(state.recordingPhase.isBusy)
            }
            .padding(.horizontal, 38)
            .padding(.top, 34)
            .padding(.bottom, 26)

            Divider().opacity(0.55)

            if state.filteredMeetings.isEmpty {
                emptyState
            } else {
                meetingList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        HStack(spacing: 44) {
            EmptyMeetingIllustration()
            VStack(alignment: .leading, spacing: 14) {
                Text(state.searchText.isEmpty ? "Nothing recorded yet" : "No matching notes")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                Text(state.searchText.isEmpty
                     ? "Start with your next call. Hushnote captures system audio locally, then turns the conversation into a cited working note."
                     : "Try a title, speaker, decision, or phrase from the transcript.")
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 390, alignment: .leading)
                if state.searchText.isEmpty {
                    Button("Create your first note") { Task { await coordinator.createMeetingNote() } }
                        .buttonStyle(.borderedProminent)
                        .tint(HushnoteTheme.inkFill)
                        .disabled(state.recordingPhase.isBusy)
                }
            }
        }
        .padding(54)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.filteredMeetings) { meeting in
                    Button {
                        state.selection = .meeting(meeting.id)
                    } label: {
                        HStack(alignment: .top, spacing: 22) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption.weight(.semibold))
                                Text(meeting.startedAt, format: .dateTime.hour().minute())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 62, alignment: .leading)

                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(meeting.title)
                                        .font(.headline)
                                    if meeting.isRecoverable {
                                        Text("RECOVER")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(HushnoteTheme.vermilionInk)
                                    }
                                }
                                Text(meeting.excerpt)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Text(meeting.template.rawValue)
                                    Text("·")
                                    Text(DurationText.clock(meeting.duration))
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.5)
                }
            }
            .padding(.horizontal, 38)
        }
    }
}
