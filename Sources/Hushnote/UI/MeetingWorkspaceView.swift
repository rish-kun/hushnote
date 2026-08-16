import SwiftUI

/// Which face of a meeting workspace belongs on screen.
///
/// The window has to follow the recording rather than the database: a meeting
/// being captured owns the live controls, the level meter and the
/// "live transcription is unavailable" notice, none of which exist anywhere
/// else in the app.
enum MeetingWorkspaceRoute: Equatable {
    case active
    case finalizing
    case completed

    /// - Parameter activeMeetingID: the meeting currently being captured, if any.
    ///   A different meeting's recording must never take over this window; its
    ///   Stop button would end a session the user is not looking at.
    nonisolated static func route(
        phase: RecordingPhase,
        activeMeetingID: UUID?,
        meetingID: UUID
    ) -> MeetingWorkspaceRoute {
        guard activeMeetingID == meetingID else { return .completed }
        switch phase {
        case .preparing, .recording, .paused: return .active
        case .finalizing: return .finalizing
        case .idle, .failed: return .completed
        }
    }
}

struct MeetingWorkspaceView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state

    var body: some View {
        switch MeetingWorkspaceRoute.route(
            phase: state.recordingPhase,
            activeMeetingID: state.activeMeetingID,
            meetingID: meetingID
        ) {
        case .active:
            ActiveMeetingView(meetingID: meetingID)
        case .finalizing:
            VStack(spacing: 0) {
                FinalizationBanner()
                CompletedMeetingView(meetingID: meetingID)
            }
        case .completed:
            CompletedMeetingView(meetingID: meetingID)
        }
    }
}

struct ActiveMeetingView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                RecordingPulse(isActive: state.recordingPhase == .recording)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.activeMeeting?.title ?? "Untitled meeting")
                        .font(.system(size: 21, weight: .semibold, design: .serif))
                    Text(state.recordingPhase == .paused ? "Capture paused" : "Recording locally")
                        .font(.caption)
                        .foregroundStyle(state.recordingPhase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(HushnoteTheme.vermilion))
                }
                Spacer()
                // A leaf view: `elapsed` ticks every second and must not
                // invalidate the live transcript below.
                ElapsedTimeLabel(font: .title3.monospacedDigit().weight(.medium))
                Button(state.recordingPhase == .paused ? "Resume" : "Pause") {
                    Task { await coordinator.togglePause() }
                }
                .buttonStyle(.bordered)
                Button("Stop") {
                    Task { await coordinator.stopMeeting() }
                }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.vermilion)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
            .background(.bar)

            HStack {
                // Also a leaf view. `systemLevel` is written once per Core Audio
                // buffer — reading it here would re-render the whole transcript
                // tens of times a second.
                SystemLevelMeter()
                Spacer()
                Label("Live text is provisional", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 11)
            .background(Color.secondary.opacity(0.045))

            Divider()

            if let notice = state.recordingNotice {
                Label(notice, systemImage: "waveform.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }

            if state.transcript.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(HushnoteTheme.vermilion)
                    Text("Listening for the conversation…")
                        .font(.system(size: 20, weight: .medium, design: .serif))
                    Text("The source tracks are already being written to disk.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(isEditable: false)
            }
        }
    }
}

struct CompletedMeetingView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    private let tabs = ["Notes", "Transcript", "Summary", "Ask"]

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meeting?.title ?? "Meeting")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                    HStack(spacing: 8) {
                        if let meeting {
                            Text(meeting.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                            Text("·")
                            Text(TimestampButton.format(meeting.duration))
                            Text("·")
                            Text(meeting.template.rawValue)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if canStartTranscribing {
                    Button("Start Transcribing") {
                        Task { await coordinator.startMeeting(meetingID: meetingID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.vermilion)
                }
                if meeting?.isRecoverable == true {
                    Button("Finalize recovery") {
                        Task { await coordinator.recoverMeeting(meetingID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.vermilion)
                }
                Menu {
                    Button("Markdown") { coordinator.export(meetingID: meetingID, format: .markdown) }
                    Button("SubRip (.srt)") { coordinator.export(meetingID: meetingID, format: .srt) }
                    Button("JSON") { coordinator.export(meetingID: meetingID, format: .json) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 38)
            .padding(.top, 31)
            .padding(.bottom, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(tabs, id: \.self) { tab in
                        Button(tab) { state.selectedWorkspaceTab = tab }
                            .buttonStyle(.plain)
                            .font(.callout.weight(state.selectedWorkspaceTab == tab ? .semibold : .regular))
                            .foregroundStyle(state.selectedWorkspaceTab == tab ? HushnoteTheme.ink : .secondary)
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) {
                                if state.selectedWorkspaceTab == tab {
                                    Rectangle().fill(HushnoteTheme.vermilion).frame(height: 2)
                                }
                            }
                    }
                }
                .padding(.horizontal, 38)
            }
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }

            workspaceTab
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: meetingID) { await coordinator.loadMeeting(meetingID) }
    }

    private var meeting: MeetingListItem? {
        state.meetings.first { $0.id == meetingID }
    }

    private var canStartTranscribing: Bool {
        guard !state.recordingPhase.isBusy else { return false }
        return meeting?.status == .idle || meeting?.status == .failed
    }

    @ViewBuilder
    private var workspaceTab: some View {
        switch state.selectedWorkspaceTab {
        case "Notes": MeetingNotesView(meetingID: meetingID)
        case "Summary": summaryWorkspace
        case "Transcript":
            TranscriptView(isEditable: TranscriptEditPolicy.allowsEditing(phase: state.recordingPhase))
        case "Ask": AskMeetingView()
        default: EmptyView()
        }
    }

    private var summaryWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Meeting summary")
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                    Spacer()
                    ProviderDisclosure(isLocal: state.selectedProvider.isLocal)
                    Button(state.insights.isGenerating ? "Generating…" : (state.insights.summary.isEmpty ? "Generate summary" : "Regenerate")) {
                        Task { await coordinator.generateInsights(meetingID: meetingID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.ink)
                    .disabled(state.insights.isGenerating || state.transcript.isEmpty)
                }

                if let error = state.insights.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HushnoteTheme.vermilion)
                } else if state.insights.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary will appear here")
                            .font(.headline)
                        Text("Stop transcribing to finalize the transcript and generate structured follow-through with your configured provider.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 28)
                } else {
                    Text(state.insights.summary)
                        .font(.system(size: 18, design: .serif))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                    summaryList("Decisions", items: state.insights.decisions, symbol: "checkmark.seal")
                    summaryList("Action items", items: state.insights.actions, symbol: "square")
                    summaryList("Open questions", items: state.insights.openQuestions, symbol: "questionmark.circle")
                }
            }
            .frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(38)
        }
    }

    @ViewBuilder
    private func summaryList(_ title: String, items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item).textSelection(.enabled)
                    } icon: {
                        Image(systemName: symbol).foregroundStyle(HushnoteTheme.moss)
                    }
                }
            }
        }
    }

}

struct MeetingNotesView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state
        TextEditor(text: Binding(
            get: { state.meetingNotes[meetingID, default: ""] },
            set: { coordinator.queueMeetingNotes(meetingID: meetingID, text: $0) }
        ))
        .font(.system(size: 17, design: .serif))
        .lineSpacing(6)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 38)
        .padding(.vertical, 28)
        .overlay(alignment: .topLeading) {
            if state.meetingNotes[meetingID, default: ""].isEmpty {
                Text("Write notes while the meeting runs…")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 43)
                    .padding(.vertical, 36)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Meeting notes")
    }
}

/// When a transcript line may be edited, and when a change to one is the user's
/// rather than the model's.
enum TranscriptEditPolicy {
    /// A transcript that is still being produced is not the user's to correct.
    /// While capturing, every live delta replaces `state.transcript` wholesale;
    /// while finalizing, the final pass mints new segment identifiers and
    /// re-keys corrections by overlap. An edit made in either window is racing
    /// a writer it cannot see.
    nonisolated static func allowsEditing(phase: RecordingPhase) -> Bool {
        !phase.isBusy
    }

    /// `.onChange(of:)` cannot distinguish a keystroke from a model-driven
    /// rewrite of the same binding, so focus decides. A field the user is not
    /// typing in did not produce the change, and an unchanged value is not an
    /// edit at all.
    nonisolated static func isHumanEdit(
        isFocused: Bool,
        from oldText: String,
        to newText: String
    ) -> Bool {
        isFocused && oldText != newText
    }
}

struct TranscriptView: View {
    let isEditable: Bool
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @FocusState private var focusedLine: UUID?

    var body: some View {
        @Bindable var state = state

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach($state.transcript) { $line in
                    HStack(alignment: .top, spacing: 15) {
                        TimestampButton(seconds: line.start) {}
                            .frame(width: 58, alignment: .leading)
                        Text(line.speaker)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(line.speaker == "You" ? HushnoteTheme.moss : HushnoteTheme.secondaryInk)
                            .frame(width: 86, alignment: .leading)
                        if isEditable {
                            TextField("Transcript", text: $line.text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...8)
                                .focused($focusedLine, equals: line.id)
                                .onChange(of: line.text) { previous, text in
                                    guard TranscriptEditPolicy.isHumanEdit(
                                        isFocused: focusedLine == line.id,
                                        from: previous,
                                        to: text
                                    ) else { return }
                                    line.isUserEdited = true
                                    coordinator.queueTranscriptEdit(id: line.segmentID, text: text)
                                }
                        } else {
                            Text(line.text)
                                .foregroundStyle(line.isProvisional ? .secondary : .primary)
                                .italic(line.isProvisional)
                                .textSelection(.enabled)
                        }
                        if line.possibleLeakage {
                            Image(systemName: "waveform.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .help("This may duplicate audio leaking between tracks")
                        }
                    }
                    .padding(.vertical, 15)
                    Divider().opacity(0.42)
                }
            }
            .frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 38)
            .padding(.vertical, 20)
        }
        .overlay {
            if state.transcript.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote", description: Text("The final transcript has not been produced yet."))
            }
        }
    }
}

struct AskMeetingView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 24) {
            Text("Ask the meeting")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            ProviderDisclosure(isLocal: state.selectedProvider.isLocal)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("What did we agree to ship?", text: $state.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    .onSubmit { Task { await coordinator.answerQuestion() } }
                Button("Ask") { Task { await coordinator.answerQuestion() } }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.ink)
                    .disabled(state.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Answering writes to `insights.error`, which only the summary
            // workspace used to render — so a question that failed looked
            // exactly like one that was never asked.
            if let error = state.insights.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.vermilion)
            }

            if !state.insights.answer.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(state.insights.answer)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    HStack {
                        ForEach(state.insights.answerTimestamps, id: \.self) { time in
                            TimestampButton(seconds: time) {}
                        }
                    }
                }
                .padding(.top, 12)
            }

            Spacer()
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(38)
    }
}
