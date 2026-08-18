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
                        .font(HushnoteTheme.Font.workspaceTitle)
                    Text(RecordingStatusText.detail(for: state.recordingPhase))
                        .font(.caption)
                        .foregroundStyle(state.recordingPhase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(HushnoteTheme.vermilionInk))
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
                if state.liveTranscriptionEnabled {
                    Label("Live text is provisional", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                // With live transcription off nothing is listening for text, so
                // the pane says what will actually happen instead. See
                // `LiveTranscriptionPolicy.emptyTranscript`.
                let empty = LiveTranscriptionPolicy.emptyTranscript(isEnabled: state.liveTranscriptionEnabled)
                VStack(spacing: 13) {
                    Image(systemName: empty.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(
                            state.liveTranscriptionEnabled
                                ? AnyShapeStyle(HushnoteTheme.vermilionInk)
                                : AnyShapeStyle(.secondary)
                        )
                    Text(empty.title)
                        .font(HushnoteTheme.Font.emptyStateTitle)
                    Text(empty.detail)
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
                        .font(HushnoteTheme.Font.pageTitle)
                    HStack(spacing: 8) {
                        if let meeting {
                            Text(meeting.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                            Text("·")
                            Text(DurationText.clock(meeting.duration))
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
                    Divider()
                    Button(MeetingAudioExport.menuTitle(isAvailable: canExportAudio)) {
                        coordinator.exportAudio(meetingID: meetingID)
                    }
                    .disabled(!canExportAudio)
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
                        let isSelected = state.selectedWorkspaceTab == tab
                        Button(tab) { state.selectedWorkspaceTab = tab }
                            .buttonStyle(.plain)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? AnyShapeStyle(HushnoteTheme.ink) : AnyShapeStyle(.secondary))
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) {
                                if isSelected {
                                    Rectangle().fill(HushnoteTheme.vermilion).frame(height: 2)
                                }
                            }
                            // Weight, colour and a 2pt underline are all
                            // invisible to VoiceOver, which otherwise announces
                            // four identical buttons.
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

    /// Answered from the loaded meeting rather than from disk: this is read
    /// every time the menu is built. See `MeetingAudioExport`.
    private var canExportAudio: Bool {
        guard let meeting else { return false }
        return MeetingAudioExport.isAvailable(retainsAudio: meeting.retainsAudio, status: meeting.status)
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
                        .font(HushnoteTheme.Font.sectionTitle)
                    Spacer()
                    ProviderDisclosure(isLocal: state.selectedProvider.isLocal)
                    Button(state.insights.isGenerating ? "Generating…" : (state.insights.summary.isEmpty ? "Generate summary" : "Regenerate")) {
                        Task { await coordinator.generateInsights(meetingID: meetingID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HushnoteTheme.inkFill)
                    .disabled(state.insights.isGenerating || state.transcript.isEmpty)
                }

                // The error sits beside the summary rather than replacing it: a
                // regenerate that failed must not take away the summary the
                // user already had.
                if let error = state.insights.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HushnoteTheme.vermilionInk)
                }

                if state.insights.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary will appear here")
                            .font(.headline)
                        Text("Stop transcribing to finalize the transcript and generate structured follow-through with your configured provider.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 28)
                } else {
                    Text(state.insights.summary)
                        .font(HushnoteTheme.Font.readingLarge)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                    summaryList("Decisions", items: state.insights.decisions, symbol: "checkmark.seal")
                    summaryList("Action items", items: state.insights.actions, symbol: "square")
                    summaryList("Open questions", items: state.insights.openQuestions, symbol: "questionmark.circle")
                }
            }
            .pageChrome()
        }
    }

    @ViewBuilder
    private func summaryList(_ title: String, items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                Text(title)
                    .font(HushnoteTheme.Font.subsectionTitle)
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
        .font(HushnoteTheme.Font.reading)
        .lineSpacing(6)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 38)
        .padding(.vertical, 28)
        .overlay(alignment: .topLeading) {
            if state.meetingNotes[meetingID, default: ""].isEmpty {
                Text("Write notes while the meeting runs…")
                    .font(HushnoteTheme.Font.reading)
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

/// What a transcript row puts on screen, and how its editable draft keeps up
/// with the model without taking the text away from whoever is typing.
enum TranscriptRowText {
    /// Whisper's control vocabulary must never reach the screen.
    ///
    /// `skipSpecialTokens`, the engines' own sanitizing and the `v6` migration
    /// all sit upstream of here, and the user still saw
    /// `<|startoftranscript|><|en|><|transcribe|>` in the transcript pane: a
    /// meeting captured before those landed is read back from a database this
    /// launch may not have migrated. The view is the only place that can be
    /// certain, and it costs one scan of a string that almost never contains
    /// `<|`.
    nonisolated static func display(_ text: String) -> String {
        WhisperSpecialToken.cleanedSegmentText(text)
    }

    /// The draft to adopt when the line changes underneath an existing row, or
    /// `nil` to leave the row alone.
    ///
    /// Two refusals matter. A focused row belongs to the user: re-seeding it
    /// would drop their insertion point at the end of a sentence they did not
    /// write. And an unchanged value is not a change: assigning it would
    /// invalidate the row on every transcript revision for nothing.
    ///
    /// Because a re-seed only ever happens while the row is unfocused, and
    /// `TranscriptEditPolicy.isHumanEdit` requires focus, a model-driven
    /// replacement -- including one that only differs by the tokens `display`
    /// removed -- can never be written back as the user's correction.
    nonisolated static func reseededDraft(
        incoming: String,
        draft: String,
        isFocused: Bool
    ) -> String? {
        guard !isFocused else { return nil }
        let next = display(incoming)
        return next == draft ? nil : next
    }
}

struct TranscriptView: View {
    let isEditable: Bool
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isFollowing = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(state.transcript) { line in
                    TranscriptRow(line: line, isEditable: isEditable) { text in
                        commit(line: line, text: text)
                    }
                    Divider().opacity(0.42)
                }
            }
            .frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 38)
            .padding(.vertical, 20)
            }
            // A live transcript is a live region: VoiceOver should not treat a
            // new line as a layout change to re-announce from the top.
            .accessibilityAddTraits(.updatesFrequently)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                TranscriptFollow.isFollowing(
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height
                )
            } action: { _, following in
                isFollowing = following
            }
            .onChange(of: state.transcript.last?.id) { _, last in
                guard isFollowing, let last else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Only offered once the user has actually left the bottom, so
                // it never competes with the transcript it would scroll.
                if !isFollowing, let last = state.transcript.last?.id {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                        isFollowing = true
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
            }
        }
        .overlay {
            if state.transcript.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote", description: Text("The final transcript has not been produced yet."))
            }
        }
    }

    /// Records the correction against the line's identity, resolved at the
    /// moment of the edit. The transcript may have been replaced since the row
    /// was built; a position captured earlier would address a different line,
    /// or none at all.
    private func commit(line: TranscriptLineItem, text: String) {
        if let index = state.transcript.firstIndex(where: { $0.id == line.id }) {
            state.transcript[index].isUserEdited = true
        }
        coordinator.queueTranscriptEdit(id: line.segmentID, text: text)
    }
}

/// One transcript line.
///
/// The row is handed its line by value and keeps its own draft, so it never
/// reads back through the array it came from. The editor used to take a
/// per-element binding out of `ForEach($state.transcript)`, and those resolve by
/// position: when the final pass replaced the transcript with a shorter list of
/// freshly identified segments, a focused field's `controlTextDidEndEditing`
/// read the old position and `Array._checkSubscript` trapped. The row's
/// identity is the line's, so a replacement tears the row down and builds a new
/// one instead of re-reading a position that has moved.
private struct TranscriptRow: View {
    let line: TranscriptLineItem
    let isEditable: Bool
    let onEdit: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(line: TranscriptLineItem, isEditable: Bool, onEdit: @escaping (String) -> Void) {
        self.line = line
        self.isEditable = isEditable
        self.onEdit = onEdit
        _draft = State(initialValue: TranscriptRowText.display(line.text))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            TimestampButton(seconds: line.start)
                .frame(width: 58, alignment: .leading)
            Text(line.speaker)
                .font(.callout.weight(.semibold))
                .foregroundStyle(line.speaker == "You" ? HushnoteTheme.moss : HushnoteTheme.secondaryInk)
                .frame(width: 86, alignment: .leading)
            if isEditable {
                TextField("Transcript", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onChange(of: line.text) { _, incoming in
                        guard let next = TranscriptRowText.reseededDraft(
                            incoming: incoming,
                            draft: draft,
                            isFocused: isFocused
                        ) else { return }
                        draft = next
                    }
                    .onChange(of: draft) { previous, text in
                        guard TranscriptEditPolicy.isHumanEdit(
                            isFocused: isFocused,
                            from: previous,
                            to: text
                        ) else { return }
                        onEdit(text)
                    }
            } else {
                Text(TranscriptRowText.display(line.text))
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
    }
}

/// Whether the transcript is still following the newest line.
///
/// Auto-scrolling unconditionally fights anyone who has scrolled up to read, so
/// following is a state the user can leave by scrolling and return to
/// deliberately.
enum TranscriptFollow {
    /// - Parameter tolerance: slack so a partly-scrolled line, or a bounce past
    ///   the end, does not read as the user taking over.
    nonisolated static func isFollowing(
        contentOffsetY: Double,
        containerHeight: Double,
        contentHeight: Double,
        tolerance: Double = 24
    ) -> Bool {
        contentOffsetY + containerHeight >= contentHeight - tolerance
    }
}

struct AskMeetingView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 24) {
            Text("Ask the meeting")
                .font(HushnoteTheme.Font.sectionTitle)
            ProviderDisclosure(isLocal: state.selectedProvider.isLocal)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("What did we agree to ship?", text: $state.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    .onSubmit { Task { await coordinator.answerQuestion() } }
                Button(state.insights.isGenerating ? "Asking…" : "Ask") {
                    Task { await coordinator.answerQuestion() }
                }
                .buttonStyle(.borderedProminent)
                .tint(HushnoteTheme.inkFill)
                .disabled(
                    state.insights.isGenerating
                        || state.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                if state.insights.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }

            // Answering writes to `insights.error`, which only the summary
            // workspace used to render — so a question that failed looked
            // exactly like one that was never asked.
            if let error = state.insights.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.vermilionInk)
            }

            if !state.insights.answer.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(state.insights.answer)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    HStack {
                        ForEach(state.insights.answerTimestamps, id: \.self) { time in
                            TimestampButton(seconds: time)
                        }
                    }
                }
                .padding(.top, 12)
            }

            Spacer()
        }
        .pageChrome()
    }
}
