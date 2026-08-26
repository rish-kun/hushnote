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
        GeometryReader { proxy in
            let policy = AdaptiveLayoutPolicy.tier(for: proxy.size.width)
            let tabs = WorkspaceTabAvailability.available(during: state.recordingPhase)
            let selected = WorkspaceTabAvailability.resolved(
                state.workspaceTab(for: meetingID),
                during: state.recordingPhase
            )

            VStack(spacing: 0) {
                recordingHeader(policy)

                HStack {
                    // Also a leaf view. `systemLevel` is written once per Core Audio
                    // buffer — reading it here would re-render the whole transcript
                    // tens of times a second.
                    SystemLevelMeter()
                    Spacer()
                    if state.liveTranscriptionEnabled {
                        Label("Live text is provisional", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                }
                .padding(.horizontal, policy.gutter)
                .padding(.vertical, 11)
                .background(HushnoteTheme.vermilion.opacity(0.045))

                HushnoteRule()

                if let notice = state.recordingNotice {
                    Label(notice, systemImage: "waveform.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .padding(.horizontal, policy.gutter)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HushnoteTheme.vermilion.opacity(0.08))
                }

                // Everything above is session-wide: it belongs to the capture,
                // not to whichever tab is open over it.
                MeetingWorkspaceTabBar(
                    tabs: tabs,
                    selected: selected,
                    select: { coordinator.setWorkspaceTab($0, for: meetingID) },
                    horizontalInset: policy.gutter
                )

                // Deliberately a switch over two leaves rather than the two
                // bodies inline. `state.transcript` is written on every live
                // ASR delta, so a body that reads it is rebuilt at speaking
                // cadence -- and this one would then hold the notes editor.
                // `ActiveTranscriptTab` owns that read the way `SystemLevelMeter`
                // owns `systemLevel`.
                switch selected {
                case .notes:
                    MeetingNotesView(meetingID: meetingID)
                default:
                    ActiveTranscriptTab(horizontalInset: policy.gutter)
                }
            }
        }
    }

    @ViewBuilder
    private func recordingHeader(_ policy: AdaptiveLayoutPolicy) -> some View {
        Group {
            if policy == .compact {
                VStack(alignment: .leading, spacing: 15) {
                    recordingIdentity
                    HStack(spacing: 10) {
                        ElapsedTimeLabel(font: .title3.monospacedDigit().weight(.medium))
                        Spacer()
                        recordingControls
                    }
                }
            } else {
                HStack(spacing: 16) {
                    recordingIdentity
                    Spacer(minLength: 20)
                    ElapsedTimeLabel(font: .title3.monospacedDigit().weight(.medium))
                    recordingControls
                }
            }
        }
        .padding(.horizontal, policy.gutter)
        .padding(.vertical, policy == .compact ? 16 : 20)
        // The recording identity belongs to the same paper as the transcript.
        // Its vermilion controls already carry the active-state emphasis; a
        // second full-width surface makes it read as a detached toolbar.
        .overlay(alignment: .bottom) {
            HushnoteRule(opacity: 0.72)
        }
    }

    private var recordingIdentity: some View {
        HStack(spacing: 13) {
            RecordingPulse(isActive: state.recordingPhase == .recording)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.activeMeeting?.title ?? "Untitled meeting")
                    .font(HushnoteTheme.Font.workspaceTitle)
                    .lineLimit(2)
                Text(RecordingStatusText.detail(for: state.recordingPhase))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.recordingPhase == .paused ? AnyShapeStyle(HushnoteTheme.secondaryInk) : AnyShapeStyle(HushnoteTheme.vermilionInk))
            }
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button(state.recordingPhase == .paused ? "Resume" : "Pause") {
                Task { await coordinator.togglePause() }
            }
            .hushnoteButton(.secondary)
            Button("Stop") {
                Task { await coordinator.stopMeeting() }
            }
            .hushnoteButton(.recording)
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        .fixedSize()
    }
}

/// The live transcript, and what stands in for it before there is one.
///
/// A leaf for the same reason `SystemLevelMeter` and `ElapsedTimeLabel` are:
/// `state.transcript` is replaced wholesale on every arriving delta, and
/// SwiftUI attributes that dependency to whichever `body` actually reads it.
/// Read from `ActiveMeetingView.body` -- as it was until the recording screen
/// gained tabs -- it rebuilt the header, the level strip and now the notes
/// editor every time somebody spoke.
private struct ActiveTranscriptTab: View {
    let horizontalInset: CGFloat
    @Environment(AppViewState.self) private var state

    var body: some View {
        if state.transcript.isEmpty {
            // With live transcription off nothing is listening for text, so
            // the pane says what will actually happen instead. See
            // `LiveTranscriptionPolicy.emptyTranscript`. It is scoped to this
            // tab rather than the whole screen now: someone recording with
            // live transcription off still has notes to write.
            let empty = LiveTranscriptionPolicy.emptyTranscript(isEnabled: state.liveTranscriptionEnabled)
            VStack(spacing: 13) {
                Image(systemName: empty.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(
                        state.liveTranscriptionEnabled
                            ? AnyShapeStyle(HushnoteTheme.vermilionInk)
                            : AnyShapeStyle(HushnoteTheme.secondaryInk)
                    )
                Text(empty.title)
                    .font(HushnoteTheme.Font.emptyStateTitle)
                Text(empty.detail)
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TranscriptView(
                // One source of truth rather than a hardcoded `false` that
                // happens to agree with it.
                isEditable: TranscriptEditPolicy.allowsEditing(phase: state.recordingPhase),
                horizontalInset: horizontalInset,
                isRecording: true
            )
        }
    }
}

struct CompletedMeetingView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    /// Not `state.recordingPhase`: this workspace also renders for meetings
    /// that are merely *not* the one recording. See `governingPhase`.
    private var phase: RecordingPhase {
        WorkspaceTabAvailability.governingPhase(
            state.recordingPhase,
            activeMeetingID: state.activeMeetingID,
            meetingID: meetingID
        )
    }

    private var tabs: [WorkspaceTab] {
        WorkspaceTabAvailability.available(during: phase)
    }

    private var selectedTab: WorkspaceTab {
        WorkspaceTabAvailability.resolved(state.workspaceTab(for: meetingID), during: phase)
    }

    var body: some View {
        @Bindable var state = state

        GeometryReader { proxy in
            let policy = AdaptiveLayoutPolicy.tier(for: proxy.size.width)

            VStack(spacing: 0) {
                meetingHeader(policy)

                if let exportState = state.audioExports[meetingID], exportState != .idle {
                    audioExportStatus(exportState, policy: policy)
                        .padding(.horizontal, policy.gutter)
                        .padding(.bottom, 12)
                }

                MeetingWorkspaceTabBar(
                    tabs: tabs,
                    selected: selectedTab,
                    select: { coordinator.setWorkspaceTab($0, for: meetingID) },
                    horizontalInset: policy.gutter
                )

                workspaceTab(policy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: meetingID) { await coordinator.loadMeeting(meetingID) }
        .sheet(
            isPresented: Binding(
                get: { state.shareSheetMeetingID == meetingID },
                set: { if !$0 { state.shareSheetMeetingID = nil } }
            )
        ) {
            MeetingShareSheet(meetingID: meetingID)
        }
    }

    private func meetingHeader(_ policy: AdaptiveLayoutPolicy) -> some View {
        ViewThatFits(in: .horizontal) {
            if policy != .compact {
                HStack(alignment: .top, spacing: 18) {
                    meetingHeading
                        .layoutPriority(1)
                    Spacer(minLength: 24)
                    meetingActions
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                meetingHeading
                meetingActions
            }
        }
        .padding(.horizontal, policy.gutter)
        .padding(.top, policy == .compact ? 22 : 31)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            HushnoteRule(opacity: 0.72)
        }
    }

    /// A meeting that is published says so, permanently, wherever it is read.
    ///
    /// A share is republished from the current meeting whenever what it
    /// includes changes, so this is not decoration: nobody should be correcting
    /// a transcript or typing a note into a document that is on the internet
    /// without being able to see that it is. It names what is actually
    /// published, because a share of the transcript alone and a share that also
    /// carries your notes are very different things to be typing into.
    @ViewBuilder
    private var shareBadge: some View {
        if let share = state.meetingShares[meetingID] {
            Button { state.shareSheetMeetingID = meetingID } label: {
                HStack(spacing: 6) {
                    HushnoteBadge(
                        title: share.hasPassword ? "Shared · Password" : "Shared",
                        tone: .alert
                    )
                    Text(sharedContentSummary(share.includes))
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("This meeting is published. Open the share settings.")
        }
    }

    private func sharedContentSummary(_ includes: ShareIncludes) -> String {
        var parts: [String] = []
        if includes.transcript { parts.append("transcript") }
        if includes.notes { parts.append("notes") }
        if includes.summary { parts.append("summary") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " · ")
    }

    private var meetingHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditableMeetingTitle(
                title: meeting?.title ?? "Meeting",
                save: { await coordinator.renameMeeting(meetingID: meetingID, title: $0) }
            )
            .layoutPriority(1)
            meetingMetadata
            shareBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var meetingMetadata: some View {
        if let meeting {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    meetingDateAndDuration(for: meeting)
                    Text("·")
                    Text(meeting.template.rawValue)
                    folderMenu
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 5) {
                    meetingDateAndDuration(for: meeting)
                    HStack(spacing: 7) {
                        Text(meeting.template.rawValue)
                        folderMenu
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(HushnoteTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func meetingDateAndDuration(for meeting: MeetingListItem) -> some View {
        Text(meeting.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
        Text("·")
        Text(DurationText.clock(meeting.duration))
    }

    @ViewBuilder
    private var folderMenu: some View {
        if let meeting {
            Menu {
                Button("Unfiled") { Task { await coordinator.moveMeeting(meetingID, toFolder: nil) } }
                if !state.folders.isEmpty { Divider() }
                ForEach(state.folders) { folder in
                    Button(folder.name) { Task { await coordinator.moveMeeting(meetingID, toFolder: folder.id) } }
                }
            } label: {
                Label(folderName(for: meeting), systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HushnoteTheme.moss)
            }
            .menuStyle(.borderlessButton)
            .help("Move meeting to a folder")
            .accessibilityLabel("Folder: \(folderName(for: meeting)). Move meeting")
        }
    }

    private func folderName(for meeting: MeetingListItem) -> String {
        guard let folderID = meeting.folderID else { return "Unfiled" }
        return state.folders.first(where: { $0.id == folderID })?.name ?? "Unfiled"
    }

    @ViewBuilder
    private var meetingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { meetingActionControls }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 10) { meetingActionControls }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var meetingActionControls: some View {
        shareControl
        if canStartTranscribing {
            Button("Start Transcribing") {
                Task { await coordinator.startMeeting(meetingID: meetingID) }
            }
            .hushnoteButton(.recording)
        }
        if meeting?.isRecoverable == true {
            Button("Finalize recovery") {
                Task { await coordinator.recoverMeeting(meetingID) }
            }
            .hushnoteButton(.recording)
        }
        Menu {
            Button("Markdown") { coordinator.export(meetingID: meetingID, format: .markdown) }
            Button("SubRip (.srt)") { coordinator.export(meetingID: meetingID, format: .srt) }
            Button("JSON") { coordinator.export(meetingID: meetingID, format: .json) }
            Divider()
            Button(MeetingAudioFileFormat.m4a.title) {
                coordinator.exportAudio(meetingID: meetingID, format: .m4a)
            }
            .disabled(!canExportAudio)
            Button(MeetingAudioFileFormat.originalCAF.title) {
                coordinator.exportAudio(meetingID: meetingID, format: .originalCAF)
            }
            .disabled(!canExportAudio)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
    }

    /// Deliberately its own control rather than an item in the Export menu.
    /// Export writes a file the user already controls; this publishes to the
    /// internet. Filing them together would make the difference a submenu.
    private var shareControl: some View {
        Button(state.meetingShares[meetingID] == nil ? "Share…" : "Sharing…") {
            state.shareSheetMeetingID = meetingID
        }
        .hushnoteButton(.secondary)
        .disabled(state.transcript.isEmpty && state.meetingShares[meetingID] == nil)
    }

    /// Answered from the loaded meeting rather than from disk: this is read
    /// every time the menu is built. See `MeetingAudioExport`.
    private var canExportAudio: Bool {
        coordinator.audioAvailable(meetingID: meetingID)
    }

    private var meeting: MeetingListItem? {
        state.meetings.first { $0.id == meetingID }
    }

    private var canStartTranscribing: Bool {
        guard !state.recordingPhase.isBusy else { return false }
        return meeting?.status == .idle || meeting?.status == .failed
    }

    @ViewBuilder
    private func audioExportStatus(_ exportState: AudioExportState, policy: AdaptiveLayoutPolicy) -> some View {
        switch exportState {
        case .idle:
            EmptyView()
        case .exporting(let format, let progress):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ProgressView(value: progress).frame(width: 180)
                    Text("Exporting \(format.title)…").font(.caption)
                    Button("Cancel") { coordinator.cancelAudioExport(meetingID: meetingID) }
                        .buttonStyle(.borderless)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Exporting \(format.title)…").font(.caption)
                    ProgressView(value: progress)
                        .frame(maxWidth: policy == .compact ? .infinity : 240)
                    Button("Cancel") { coordinator.cancelAudioExport(meetingID: meetingID) }
                        .buttonStyle(.borderless)
                }
            }
        case .succeeded(let destination):
            Label("Exported \(destination.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.moss)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.vermilionInk)
        }
    }

    @ViewBuilder
    private func workspaceTab(_ policy: AdaptiveLayoutPolicy) -> some View {
        switch selectedTab {
        case .notes: MeetingNotesView(meetingID: meetingID)
        case .summary: summaryWorkspace(policy)
        case .transcript:
            TranscriptView(
                isEditable: TranscriptEditPolicy.allowsEditing(phase: state.recordingPhase),
                horizontalInset: policy.gutter
            )
        case .ask: AskMeetingView(horizontalInset: policy.gutter, policy: policy)
        }
    }

    private func summaryWorkspace(_ policy: AdaptiveLayoutPolicy) -> some View {
        ScrollView {
            Group {
                if policy.showsRightRail {
                    HStack(alignment: .top, spacing: 44) {
                        summaryBody(showsActions: false)
                            .frame(maxWidth: HushnoteTheme.transcriptMeasure, alignment: .leading)
                        summaryRail(showsActions: true)
                            .frame(width: 232, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        summaryBody(showsActions: true)
                            .frame(maxWidth: HushnoteTheme.transcriptMeasure, alignment: .leading)
                        summaryRail(showsActions: false)
                            .frame(maxWidth: HushnoteTheme.transcriptMeasure, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: policy.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, policy.gutter)
            .padding(.vertical, 30)
        }
        .scrollIndicators(.never)
    }

    private func summaryBody(showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    summaryTitle
                    Spacer(minLength: 16)
                    if showsActions { summaryActions }
                }
                VStack(alignment: .leading, spacing: 14) {
                    summaryTitle
                    if showsActions { summaryActions }
                }
            }

            if state.insights.generationStage != nil {
                InsightGenerationStatusView(workspace: state.insights)
            }

            // The error sits beside the summary rather than replacing it: a
            // regenerate that failed must not take away the summary the user had.
            if let error = state.insights.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HushnoteTheme.vermilionInk)
            }

            if state.insights.isEditingSummary {
                summaryEditor
            } else if state.insights.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start the meeting summary")
                        .font(HushnoteTheme.Font.subsectionTitle)
                    Text("Write it in your own words, or generate a cited draft from the transcript.")
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                    HStack(spacing: 10) {
                        Button("Write summary") { coordinator.beginSummaryEditing(meetingID: meetingID) }
                            .hushnoteButton(.primary)
                        Button("Generate summary") {
                            Task { await coordinator.generateInsights(meetingID: meetingID) }
                        }
                        .hushnoteButton(.secondary)
                        .disabled(state.insights.isGenerating || state.transcript.isEmpty)
                    }
                    .padding(.top, 6)
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
    }

    private func summaryRail(showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsActions { summaryRailActions }

            if let candidate = state.insights.candidateSummaryVersion {
                SummaryCandidateView(
                    version: candidate,
                    keep: { coordinator.keepCurrentSummary(meetingID: meetingID) },
                    use: { Task { await coordinator.activateSummaryVersion(candidate, meetingID: meetingID) } },
                    copy: { coordinator.copySummary(candidate.text) }
                )
            }

            if !state.insights.summaryVersions.isEmpty {
                SummaryHistoryView(
                    versions: state.insights.summaryVersions,
                    activeID: state.insights.activeSummaryVersionID,
                    hasMore: state.insights.hasMoreSummaryVersions,
                    isLoading: state.insights.isLoadingSummaryVersions,
                    activate: { version in
                        Task { await coordinator.activateSummaryVersion(version, meetingID: meetingID) }
                    },
                    loadMore: {
                        Task { await coordinator.loadMoreSummaryVersions(meetingID: meetingID) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var summaryRailActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderDisclosure(isLocal: state.selectedProvider.isLocal)
            if state.insights.generationStage != nil {
                Button("Cancel") { coordinator.cancelInsightGeneration(meetingID: meetingID) }
                    .hushnoteButton(.secondary)
            } else {
                if !state.insights.summary.isEmpty {
                    Button("Edit") { coordinator.beginSummaryEditing(meetingID: meetingID) }
                        .hushnoteButton(.secondary)
                }
                Button(state.insights.summary.isEmpty ? "Generate summary" : "Regenerate") {
                    Task { await coordinator.generateInsights(meetingID: meetingID) }
                }
                .hushnoteButton(.primary)
                .disabled(state.insights.isGenerating || state.transcript.isEmpty)
            }
        }
    }

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(
                get: { state.insights.summaryDraft },
                set: { value in
                    state.updateInsights(for: meetingID) { $0.summaryDraft = value }
                }
            ))
            .font(HushnoteTheme.Font.readingLarge)
            .lineSpacing(6)
            .frame(minHeight: 180)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(12)
            .background(HushnoteTheme.paperRaised, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(HushnoteTheme.rule) }
            .accessibilityLabel("Meeting summary")

            HStack(spacing: 10) {
                Button("Save") { Task { await coordinator.saveSummary(meetingID: meetingID) } }
                    .hushnoteButton(.primary)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(
                        state.insights.isSavingSummary
                            || !state.insights.hasUnsavedSummaryChanges
                            || state.insights.summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button("Cancel") { coordinator.cancelSummaryEditing(meetingID: meetingID) }
                    .hushnoteButton(.secondary)
                    .disabled(state.insights.isSavingSummary)
                if state.insights.isSavingSummary {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(HushnoteTheme.secondaryInk)
                } else if state.insights.hasUnsavedSummaryChanges {
                    Text("Unsaved changes").font(.caption).foregroundStyle(HushnoteTheme.secondaryInk)
                }
            }
        }
    }

    private var summaryTitle: some View {
        Text("Meeting summary")
            .font(HushnoteTheme.Font.sectionTitle)
    }

    @ViewBuilder
    private var summaryActions: some View {
        if state.insights.generationStage != nil {
            Button("Cancel") { coordinator.cancelInsightGeneration(meetingID: meetingID) }
                .hushnoteButton(.secondary)
        } else {
            HStack(spacing: 12) {
                ProviderDisclosure(isLocal: state.selectedProvider.isLocal)
                if !state.insights.summary.isEmpty {
                    Button("Edit") { coordinator.beginSummaryEditing(meetingID: meetingID) }
                        .hushnoteButton(.secondary)
                }
                Button(state.insights.summary.isEmpty ? "Generate summary" : "Regenerate") {
                    Task { await coordinator.generateInsights(meetingID: meetingID) }
                }
                .hushnoteButton(.primary)
                .disabled(state.insights.isGenerating || state.transcript.isEmpty)
            }
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

/// Product-owned workspace navigation. The selected state is carried by an
/// ink-filled capsule and an accessibility trait, instead of the system's blue
/// segmented control treatment. The row scrolls only when a compact split view
/// cannot accommodate all four destinations.
private struct MeetingWorkspaceTabBar: View {
    let tabs: [WorkspaceTab]
    let selected: WorkspaceTab
    let select: (WorkspaceTab) -> Void
    let horizontalInset: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(tabs, id: \.self) { tab in
                    let isSelected = selected == tab
                    Button { select(tab) } label: {
                        Text(tab.rawValue)
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : HushnoteTheme.secondaryInk)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                isSelected ? HushnoteTheme.inkFill : Color.clear,
                                in: Capsule(style: .continuous)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 10)
        }
        // `.scrollIndicators` rather than the `showsIndicators:` initializer,
        // so every scroll container in the workspace is suppressed the same way.
        .scrollIndicators(.never)
        .overlay(alignment: .bottom) {
            HushnoteRule(opacity: 0.72)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting workspace tabs")
    }
}

private struct EditableMeetingTitle: View {
    let title: String
    let save: (String) async -> Bool

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isEditing {
                TextField("Meeting name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(HushnoteTheme.Font.pageTitle)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .disabled(isSaving)
                if isSaving { ProgressView().controlSize(.small) }
            } else {
                Text(title)
                    .font(HushnoteTheme.Font.pageTitle)
                    .lineLimit(2)
                Button {
                    draft = title
                    isEditing = true
                    isFocused = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .help("Rename meeting")
                .accessibilityLabel("Rename meeting")
            }
        }
    }

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let saved = await save(draft)
            isSaving = false
            if saved { isEditing = false }
        }
    }

    private func cancel() {
        draft = title
        isEditing = false
    }
}

private struct SummaryCandidateView: View {
    let version: SummaryVersion
    let keep: () -> Void
    let use: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("New generated version", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text(version.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
            Text(version.text)
                .font(HushnoteTheme.Font.reading)
                .lineSpacing(5)
                .lineLimit(10)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Use Generated", action: use)
                    .hushnoteButton(.primary)
                Button("Keep Current", action: keep).hushnoteButton(.secondary)
                Button("Copy", action: copy).buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(HushnoteTheme.paperRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(HushnoteTheme.moss.opacity(0.45)) }
    }
}

private struct SummaryHistoryView: View {
    let versions: [SummaryVersion]
    let activeID: UUID?
    let hasMore: Bool
    let isLoading: Bool
    let activate: (SummaryVersion) -> Void
    let loadMore: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Summary history (\(versions.count))", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(versions) { version in
                    Button { activate(version) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: version.id == activeID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(version.id == activeID ? HushnoteTheme.moss : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.kind == .manual ? "Manual edit" : "Generated")
                                    .font(.callout.weight(.medium))
                                Text(version.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(HushnoteTheme.secondaryInk)
                            }
                            Spacer()
                            Text(version.text.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(HushnoteTheme.secondaryInk)
                                .lineLimit(1)
                                .frame(maxWidth: 300, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(version.id == activeID)
                    HushnoteRule(opacity: 0.45)
                }
                if hasMore {
                    Button(isLoading ? "Loading…" : "Load older versions", action: loadMore)
                        .buttonStyle(.borderless)
                        .disabled(isLoading)
                        .padding(.vertical, 8)
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }
}

private struct InsightGenerationStatusView: View {
    let workspace: InsightWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: workspace.generationProgress)
                .tint(HushnoteTheme.moss)
            HStack {
                Text(workspace.generationStage?.title ?? "Preparing summary…")
                Spacer()
                if let started = workspace.generationStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(DurationText.clock(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .padding(14)
        .background(HushnoteTheme.paperRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The page you write on.
///
/// It used to be a `TextEditor` fenced in a stroked, raised rounded rectangle
/// floating on the shell's paper -- the last unmistakably-platform control in
/// the app, and the only one on a route whose entire purpose is writing. A box
/// with a border says "fill this in". Every other route in Hushnote writes
/// directly on the page, and so does this one now.
///
/// It resolves the same `TranscriptLayout` the transcript does, so notes prose
/// and transcript prose begin at the same x and switching tabs never slides
/// the text sideways. The apparatus margin is deliberately left empty: there
/// is no per-line apparatus for a note, and the column costs nothing but the
/// alignment it buys.
struct MeetingNotesView: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    /// The editor's own caret. `TextEditor(text:selection:)` is macOS 15, and
    /// this package targets macOS 15, so stamping needs no AppKit bridge and
    /// no availability fence -- `TextSelection.Indices` hands back real
    /// `Range<String.Index>` values into the bound string.
    @State private var selection: TextSelection?

    private var notes: String { state.meetingNotes[meetingID, default: ""] }

    /// The transcript's own clock, which is the audio sample clock. Nil when
    /// nothing has been transcribed yet -- with live transcription off there is
    /// no honest time to stamp, and a wrong one is worse than none.
    ///
    /// Read only from `stampMoment`'s action closure, never from `body`.
    /// `state.transcript` is replaced on every live ASR delta, and a `body`
    /// that reads it is rebuilt at speaking cadence -- with the editor inside
    /// it. That is why the rail is `NotesRail`, a separate view.
    private var stampableSeconds: TimeInterval? {
        state.transcript.last?.end
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = TranscriptLayout.resolve(availableWidth: proxy.size.width)

            HStack(alignment: .top, spacing: 0) {
                page(layout)
                    .frame(maxWidth: layout.readerWidth ?? .infinity, alignment: .leading)

                if layout.showsIndexRail {
                    NotesRail(meetingID: meetingID)
                        .frame(width: layout.railWidth, alignment: .leading)
                        // 32, like the transcript's. The shared spread exists
                        // so switching tabs never moves the text; at 34 it
                        // moved by two points vertically instead.
                        .padding(.top, 32)
                        .padding(.trailing, layout.gutter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func page(_ layout: TranscriptLayout) -> some View {
        HStack(alignment: .top, spacing: layout.marginGap) {
            if layout.hasMargin {
                // Empty, and kept: it is what puts the first character of a
                // note directly under the first character of the transcript.
                Color.clear
                    .frame(width: layout.marginWidth, height: 0)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                editor
                // Below 1180pt there is no rail, and the page reported
                // nothing at all: no word count, no "Saving…", no "Saved".
                // The whole point of `AppViewState.notesSaving` is that the
                // page states what is true instead of promising it, and that
                // disappeared on any window narrower than the rail's
                // threshold. This is the rail's first block, relocated.
                if !layout.showsIndexRail {
                    NotesStatusLine(meetingID: meetingID)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: layout.measure, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, layout.gutter)
        .padding(.top, 32)
    }

    private var editor: some View {
        TextEditor(
            text: Binding(
                get: { notes },
                set: { coordinator.queueMeetingNotes(meetingID: meetingID, text: $0) }
            ),
            selection: $selection
        )
        .onReceive(NotificationCenter.default.publisher(for: .hushnoteStampMoment)) { _ in
            stampMoment()
        }
        .font(HushnoteTheme.Font.reading)
        .lineSpacing(6)
        .textEditorStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        // Inside the editor's own scroll content, not on the page around it.
        // On the page it did nothing for a note long enough to scroll: the
        // last line was sliced mid-glyph and then floated above a band of
        // blank paper, which reads as a rendering fault rather than as more
        // text below. The transcript already puts its inset inside the scroll
        // view for the same reason.
        .contentMargins(.bottom, 32, for: .scrollContent)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if notes.isEmpty {
                Text(NotesPagePolicy.placeholder(
                    isCapturing: state.recordingPhase.isCapturing
                ))
                    .font(HushnoteTheme.Font.reading)
                    // 2.50:1 at 0.55. Quiet is not the same as unreadable.
                    .foregroundStyle(HushnoteTheme.secondaryInk.opacity(0.75))
                    // Clears `NSTextView`'s own line-fragment padding, so the
                    // placeholder sits under the caret rather than beside it.
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Meeting notes")
    }

    /// Writes the moment being spoken into the note, at the caret.
    ///
    /// Delivered by notification rather than by a `keyboardShortcut` on a
    /// button, because the menu command cannot reach this view's `@State` --
    /// the same route `.hushnoteToggleSidebar` takes for the same reason.
    private func stampMoment() {
        guard let seconds = stampableSeconds else { return }

        var range: Range<String.Index>?
        if case .selection(let selected)? = selection?.indices {
            range = selected
        }

        let stamped = NoteStampPolicy.stamping(notes, selection: range, seconds: seconds)
        coordinator.queueMeetingNotes(meetingID: meetingID, text: stamped.text)
        // Re-derived against the *new* string: the index the caret came from
        // was invalidated by the insertion that just happened.
        selection = TextSelection(
            insertionPoint: stamped.text.index(
                stamped.text.startIndex,
                offsetBy: stamped.caretOffset
            )
        )
    }
}

/// What is true about these notes, and about the meeting behind them.
///
/// Its own view rather than a computed property on `MeetingNotesView`, because
/// it reads `state.transcript` -- which is replaced on every live ASR delta.
/// Read from the page's own body, it would rebuild the notes editor every time
/// somebody spoke. Same reason `SystemLevelMeter` is a leaf.
private struct NotesRail: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state

    private var notes: String { state.meetingNotes[meetingID, default: ""] }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                HushnoteEyebrow("Notes")
                NotesStatusLine(meetingID: meetingID, axis: .vertical)
            }

            if !state.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HushnoteEyebrow("This meeting")
                    Text(DurationText.clock(state.transcript.last?.end ?? 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                    Text("\(state.transcript.count) lines")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                    Text(state.insights.summary.isEmpty ? "No summary yet" : "Summary generated")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About these notes")
    }
}

/// What is true about these notes right now: whether the last keystroke has
/// reached the database, how much is written, and -- while recording -- that a
/// moment can be stamped.
///
/// Its own view because it appears in two places: stacked in `NotesRail` where
/// there is room for one, and inline under the measure where there is not.
private struct NotesStatusLine: View {
    let meetingID: UUID
    var axis: Axis = .horizontal
    @Environment(AppViewState.self) private var state

    private var notes: String { state.meetingNotes[meetingID, default: ""] }

    var body: some View {
        let content = Group {
            saveLine
            if !notes.isEmpty {
                Text(NotesPagePolicy.wordCountLabel(NotesPagePolicy.wordCount(notes)))
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
            if state.recordingPhase.isCapturing, state.transcript.last != nil {
                // Said where the writing is, not only in a menu. An affordance
                // reachable solely by shortcut is one nobody finds.
                Text("⌘⇧T stamps the moment")
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
        }

        if axis == .vertical {
            VStack(alignment: .leading, spacing: 8) { content }
        } else {
            HStack(spacing: 14) {
                content
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var saveLine: some View {
        switch NotesPagePolicy.saveState(
            text: notes,
            isSaving: state.notesSaving.contains(meetingID)
        ) {
        case .blank:
            Text("Nothing written yet")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        case .saving:
            HushnoteStatusLine(text: "Saving…", tone: .working)
        case .saved:
            HushnoteStatusLine(text: "Saved to this meeting", tone: .good)
        }
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

/// The transcript, read as prose.
///
/// The pane used to draw one row per ASR segment, and Whisper emits a segment
/// every few seconds: a fixed timestamp column, a fixed speaker column and a
/// fragment like "having a", several hundred times over. `TranscriptGrouping`
/// decides where a paragraph begins; this only draws them.
///
/// Correcting the transcript is still per segment. A paragraph is a block of
/// text until it is opened, and opening it reveals the segments inside as
/// individual fields -- so a correction is written back to the one segment it
/// belongs to, and a merged paragraph is never written over a single segment's
/// text. Only one paragraph is open at a time, and it closes by itself if the
/// transcript underneath it is replaced.
struct TranscriptView: View {
    let isEditable: Bool
    let horizontalInset: CGFloat
    var isRecording = false
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFollowing = true
    @State private var openParagraph: UUID?
    @State private var headerOffsets: [UUID: CGFloat] = [:]

    var body: some View {
        // One linear pass over the transcript. A paragraph that did not change
        // compares equal to the one it replaces, so a segment arriving live
        // rebuilds the paragraph it joins and leaves everything above it alone.
        let paragraphs = TranscriptGrouping.paragraphs(state.transcript)
        let open = TranscriptEditingFocus.surviving(
            openParagraph,
            isEditable: isEditable,
            in: paragraphs
        )
        // While recording, the chapter still accruing text is withheld: it
        // would rewrite its own opening words on every buffer and reflow an
        // index the reader is trying to steer by.
        let chapters = TranscriptGrouping.chapters(
            paragraphs,
            includesOpenChapter: !isRecording
        )
        let liveParagraph = isRecording ? paragraphs.last?.id : nil

        GeometryReader { proxy in
            let layout = TranscriptLayout.resolve(availableWidth: proxy.size.width)

            HStack(alignment: .top, spacing: 0) {
                reader(
                    paragraphs: paragraphs,
                    chapters: chapters,
                    open: open,
                    liveParagraph: liveParagraph,
                    layout: layout
                )
                // Capped where an index follows, so the index stays beside the
                // prose instead of being pinned to the window edge with a hole
                // between the two. See `TranscriptLayout.readerWidth`.
                .frame(maxWidth: layout.readerWidth ?? .infinity, alignment: .leading)

                if layout.showsIndexRail, !chapters.isEmpty {
                    TranscriptIndexRail(
                        chapters: chapters,
                        currentChapterID: TranscriptChapterVisibility.current(
                            headerOffsets: headerOffsets,
                            order: chapters.map(\.id)
                        ),
                        isRecording: isRecording,
                        width: layout.railWidth
                    )
                    .padding(.trailing, layout.gutter)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            // Asked of the paragraphs rather than the segments: a transcript of
            // nothing but control tokens has no prose in it, and an empty pane
            // would say nothing at all.
            if paragraphs.isEmpty {
                HushnoteEmptyState(
                    title: "No transcript",
                    message: "The final transcript has not been produced yet."
                ) {
                    HushnoteGlyph(systemName: "text.quote")
                }
                .padding(.horizontal, horizontalInset)
            }
        }
    }

    @ViewBuilder
    private func reader(
        paragraphs: [TranscriptParagraph],
        chapters: [TranscriptChapter],
        open: UUID?,
        liveParagraph: UUID?,
        layout: TranscriptLayout
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { paragraph in
                        if paragraph.opensSection, let start = paragraph.timestamp {
                            TranscriptChapterHeader(
                                start: start,
                                layout: layout,
                                isOpening: paragraph.id == paragraphs.first?.id
                            )
                            .id(chapterHeaderID(paragraph.id))
                            // Reports where this chapter sits relative to the
                            // top edge, which is what tells the rail where the
                            // reader is. Kept even for the opening chapter,
                            // whose header draws nothing: a zero-height anchor
                            // still reports, so the index still measures from
                            // the start of the meeting.
                            .background {
                                GeometryReader { header in
                                    Color.clear.preference(
                                        key: ChapterOffsetKey.self,
                                        value: [paragraph.id: header.frame(in: .named(scrollSpace)).minY]
                                    )
                                }
                            }
                        }

                        TranscriptParagraphView(
                            paragraph: paragraph,
                            layout: layout,
                            isEditable: isEditable,
                            isOpen: open == paragraph.id,
                            isLive: liveParagraph == paragraph.id,
                            toggleOpen: {
                                openParagraph = open == paragraph.id ? nil : paragraph.id
                            },
                            onEdit: commit
                        )
                    }
                }
                .frame(maxWidth: layout.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, layout.gutter)
                // Room to breathe under the tab rule, and enough at the foot
                // that reading never stops flush against the window edge.
                .padding(.top, 32)
                // Load-bearing, not decorative. With no scroll indicator this
                // band of blank paper is the only "you have reached the end"
                // signal the page has, and it works because the largest gap
                // inside the document is smaller: 32 between paragraphs, ~48
                // above a chapter rule -- and the chapter case brings a visible
                // hairline with it. Do not reduce it.
                .padding(.bottom, Self.readerBottomInset)
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: scrollSpace)
            .onPreferenceChange(ChapterOffsetKey.self) { headerOffsets = $0 }
            // A live transcript is a live region: VoiceOver should not treat a
            // new line as a layout change to re-announce from the top.
            .accessibilityAddTraits(.updatesFrequently)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                TranscriptFollow.isFollowing(
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height,
                    // The auto-scroll aligns the last paragraph's *bottom* with
                    // the viewport, which leaves the whole bottom inset below
                    // it. Without telling the policy about that inset, every
                    // auto-scroll lands outside its own tolerance and follow
                    // switches itself off -- so "Jump to latest" lit up on the
                    // first arriving segment and stayed lit for the rest of the
                    // recording, which is the same as meaning nothing.
                    bottomInset: Self.readerBottomInset
                )
            } action: { _, following in
                isFollowing = following
            }
            // Still driven by the arriving segment rather than by the paragraph:
            // a segment that joins the paragraph already on screen lengthens it
            // without changing its identity, and the pane has to keep up with
            // that too.
            .onChange(of: state.transcript.last?.id) { _, _ in
                guard isFollowing, let anchor = paragraphs.last?.id else { return }
                scroll(proxy, to: anchor, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                // Only offered once the user has actually left the bottom, so
                // it never competes with the transcript it would scroll.
                if !isFollowing, let anchor = paragraphs.last?.id {
                    // "Latest" implies something is still arriving. On a
                    // meeting that ended three weeks ago there is only an end.
                    Button(isRecording ? "Jump to latest" : "Jump to end", systemImage: "arrow.down") {
                        scroll(proxy, to: anchor, anchor: .bottom)
                        isFollowing = true
                    }
                    // Was a hand-rolled capsule: `paperRaised` on `paper` is a
                    // 1.06:1 fill and a `rule` stroke is 1.72:1, under WCAG's
                    // 3:1 for a component boundary -- so it read as one more
                    // piece of text floating over the prose rather than as a
                    // control. It is also the page's only scroll affordance
                    // now, which is a filled control's job.
                    .hushnoteButton(.primary)
                    .font(.caption.weight(.medium))
                    // Centred on the *measure*, not on the column. Centring on
                    // `columnWidth` counted the apparatus margin, which put the
                    // pill 44pt to the left of the text it scrolls.
                    .padding(.leading, layout.gutter + layout.marginWidth
                        + (layout.hasMargin ? layout.marginGap : 0))
                    .frame(maxWidth: layout.measure, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
            .onChange(of: state.transcriptJumpRequest) { _, _ in
                resolveJump(proxy, paragraphs: paragraphs)
            }
            // A request raised from search arrives before the meeting's
            // transcript has loaded. Retry as paragraphs appear, rather than
            // consuming the request against an empty list.
            .onChange(of: paragraphs.count) { _, _ in
                resolveJump(proxy, paragraphs: paragraphs)
            }
        }
    }

    private func resolveJump(_ proxy: ScrollViewProxy, paragraphs: [TranscriptParagraph]) {
        guard let request = state.transcriptJumpRequest else { return }

        if let paragraphID = request.paragraphID {
            // From the index: land on the chapter's own anchor, not the
            // paragraph's, or the rule and time it opens with end up above the
            // top edge and the reader arrives just past the beat.
            scroll(proxy, to: chapterHeaderID(paragraphID), anchor: .top)
        } else if let segmentID = request.segmentID,
                  let paragraphID = TranscriptGrouping.paragraphID(
                      containingSegmentID: segmentID,
                      in: paragraphs
                  ) {
            scroll(proxy, to: paragraphID, anchor: .center)
        } else {
            // Leave the request standing rather than consuming it against
            // nothing; the retry above will pick it up.
            return
        }

        // Without this the follow-scroll takes the view straight back to the
        // bottom as soon as the next segment arrives.
        isFollowing = false
        state.transcriptJumpRequest = nil
    }

    /// The blank paper under the last paragraph. Shared by the padding that
    /// draws it and the follow policy that has to know it is there.
    private static let readerBottomInset: CGFloat = 96

    private var scrollSpace: String { "hushnote.transcript.scroll" }

    /// Chapter headers scroll to their own anchor, which is deliberately not
    /// the paragraph's: scrolling to the paragraph would put its rule and time
    /// above the top edge, so the reader would arrive just after the beat.
    private func chapterHeaderID(_ paragraphID: UUID) -> String {
        "chapter-\(paragraphID.uuidString)"
    }

    private func scroll(
        _ proxy: ScrollViewProxy,
        to anchor: some Hashable,
        anchor edge: UnitPoint
    ) {
        if reduceMotion {
            proxy.scrollTo(anchor, anchor: edge)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(anchor, anchor: edge)
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

/// Where each rendered chapter header sits inside the scroll view.
///
/// `LazyVStack` only renders what is visible, so this map is small and sparse
/// by construction -- which is exactly what `TranscriptChapterVisibility`
/// expects to reason over.
private struct ChapterOffsetKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A beat in the recording, drawn where `TranscriptGrouping` decided the reader
/// has lost the thread of the clock. These are the stops the index points at.
private struct TranscriptChapterHeader: View {
    let start: TimeInterval
    let layout: TranscriptLayout
    /// The first chapter of the meeting, which is not drawn.
    var isOpening = false

    var body: some View {
        if isOpening {
            // A document begins; it is not ruled off from whatever is above
            // it. Drawing this one put a rule across the top of every
            // transcript with nothing over it, and printed `00:00` seventy
            // points above the identical `00:00` in the first paragraph's
            // margin. The anchor survives so the index can still point here.
            Color.clear.frame(height: 0)
        } else {
            rule
        }
    }

    private var rule: some View {
        HStack(alignment: .firstTextBaseline, spacing: layout.marginGap) {
            if layout.hasMargin {
                Text(DurationText.clock(start))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HushnoteTheme.ink)
                    .frame(width: layout.marginWidth, alignment: .trailing)
            }
            HushnoteRule(opacity: 0.45)
                .frame(maxWidth: layout.measure)
            if !layout.hasMargin {
                Text(DurationText.clock(start))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HushnoteTheme.ink)
            }
        }
        .padding(.top, 48)
        .padding(.bottom, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chapter at \(DurationText.spoken(start))")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The apparatus beside a paragraph: when it was said, the way into correcting
/// it, and whether it is still being written.
///
/// It hangs outside the measure, so a reader scanning prose never crosses it.
/// The time is set as bare digits rather than in a `TimestampButton` capsule,
/// because in this app a moss capsule means "you can go there" and a transcript
/// timestamp has nowhere to go -- there is no player behind it.
private struct TranscriptMargin: View {
    let start: TimeInterval
    let layout: TranscriptLayout
    let isEditable: Bool
    let isLive: Bool
    let possibleLeakage: Bool
    let isRevealed: Bool
    let correct: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // No opacity knockdown. `secondaryInk` passes at 6.88:1 and
            // `ThemeContrastTests` proves it, but that suite tests tokens and
            // never call sites -- at 0.62 this composited to 2.87:1 in light,
            // failing AA. Below 1180pt there is no index rail and no scroll
            // indicator, so this timestamp is the reader's only orientation.
            Text(DurationText.clock(start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .accessibilityLabel("At \(DurationText.spoken(start))")

            if isEditable {
                // A word, not a glyph. An affordance seen once every thirty
                // minutes has to be learned; a word is simply read.
                Button("Correct", action: correct)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .opacity(isRevealed ? 1 : 0)
                    .accessibilityHint("Opens the segments in this paragraph for editing")
            }

            if possibleLeakage {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.vermilionInk)
                    .help("This may duplicate audio leaking between tracks")
                    .accessibilityLabel("May duplicate audio leaking between tracks")
            }
        }
        .frame(width: layout.marginWidth, alignment: .trailing)
        .overlay(alignment: .trailing) {
            // The one accent, used for its one meaning, exactly where new text
            // is landing. Static: the header pulse already owns motion here,
            // and a second pulse beside prose you are reading is hostile.
            if isLive {
                Rectangle()
                    .fill(HushnoteTheme.vermilion.opacity(0.5))
                    .frame(width: 2)
                    .offset(x: 12)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The transcript's index: the beats of the meeting, who spoke in each, and
/// where the reader currently is. It is a sibling of the scroll view rather
/// than a passenger inside it, because an index that scrolls away cannot index.
private struct TranscriptIndexRail: View {
    let chapters: [TranscriptChapter]
    let currentChapterID: UUID?
    let isRecording: Bool
    let width: CGFloat
    @Environment(AppViewState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HushnoteEyebrow("Contents")

            ScrollViewReader { rail in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(chapters) { chapter in
                            let isCurrent = chapter.id == currentChapterID

                            HushnoteSelectableRow(
                                isSelected: isCurrent,
                                select: {
                                    state.transcriptJumpRequest = .init(paragraphID: chapter.id)
                                }
                            ) {
                                // One line, the way an index line is: a number
                                // and a heading. It used to carry a timestamp
                                // capsule, the speaker list and two lines of
                                // preview prose, which made seven of them a
                                // second column of body copy competing with the
                                // one being read. The speaker lists in
                                // particular said "Speaker 1, Speaker 2 /
                                // Speaker 2 / Speaker 2, Speaker 1" --
                                // repetition, not information. The voices
                                // survive in the foot, counted.
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Text(DurationText.clock(chapter.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(rowInk(isCurrent))
                                    Text(chapter.opening)
                                        .font(.caption)
                                        .foregroundStyle(rowInk(isCurrent))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            // The row is the target. A `TimestampButton` nested
                            // inside `HushnoteSelectableRow`'s own button gave
                            // one entry two hit areas doing the same thing.
                            .accessibilityLabel(
                                "\(DurationText.spoken(chapter.start)). \(chapter.opening)"
                            )
                            .id(chapter.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                // An index that highlights a row scrolled out of its own list
                // is not indexing anything. Especially so now that it is what
                // the scroll indicator used to do.
                .onChange(of: currentChapterID) { _, current in
                    guard let current else { return }
                    if reduceMotion {
                        rail.scrollTo(current, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            rail.scrollTo(current, anchor: .center)
                        }
                    }
                }
            }

            HushnoteRule(opacity: 0.45)
            foot
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, 32)
        .padding(.bottom, 24)
        // Deliberately not `.updatesFrequently`: a rail that re-announced on
        // every arriving segment would make VoiceOver unusable while recording.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript contents")
    }

    private func rowInk(_ isCurrent: Bool) -> Color {
        isCurrent ? HushnoteTheme.ink : HushnoteTheme.secondaryInk
    }

    @ViewBuilder
    private var foot: some View {
        if isRecording {
            HStack(spacing: 7) {
                RecordingPulse(isActive: true)
                ElapsedTimeLabel(font: .caption.monospacedDigit())
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
        } else if let last = chapters.last {
            let voices = Set(chapters.flatMap(\.speakers)).count
            Text("\(DurationText.clock(last.end)) · \(voices) \(voices == 1 ? "voice" : "voices")")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
    }
}

/// One paragraph: prose, and only the apparatus it earns.
///
/// The name of a speaker and the time appear above the paragraph, small and
/// quiet, and only where `TranscriptGrouping` decided a reader needs them. A
/// paragraph that continues the same voice in the same stretch of the recording
/// carries nothing at all -- the break is the signal.
private struct TranscriptParagraphView: View {
    let paragraph: TranscriptParagraph
    let layout: TranscriptLayout
    let isEditable: Bool
    let isOpen: Bool
    let isLive: Bool
    let toggleOpen: () -> Void
    let onEdit: (TranscriptLineItem, String) -> Void

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isCorrectFocused: Bool
    @State private var isRenamingSpeaker = false
    @State private var speakerDraft = ""
    @FocusState private var speakerFieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: layout.marginGap) {
            if layout.hasMargin {
                TranscriptMargin(
                    start: paragraph.start,
                    layout: layout,
                    isEditable: isEditable && !isOpen,
                    isLive: isLive,
                    possibleLeakage: paragraph.possibleLeakage,
                    isRevealed: isHovering || isCorrectFocused,
                    correct: toggleOpen
                )
                .focused($isCorrectFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                if paragraph.showsSpeakerName || isOpen { header }
                if isOpen { segments } else { prose }
            }
            .frame(maxWidth: layout.measure, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A hover target the whole width of the column, so the affordance in
        // the margin can be reached from anywhere in the paragraph rather than
        // only from the words themselves.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .background {
            // Says "this block is a unit you can act on" in the app's own
            // vocabulary, using the same surface the opened paragraph uses --
            // so opening is continuous with hovering rather than a jump.
            if isEditable, isHovering, !isOpen {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(HushnoteTheme.paperRaised)
                    .padding(.horizontal, -12)
                    .padding(.vertical, -8)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        // The instinctive gesture for "edit this text", offered beside the real
        // button rather than instead of it.
        .onTapGesture(count: 2) { if isEditable, !isOpen { toggleOpen() } }
        // A new voice opens a section and is given room; a paragraph that
        // merely continues gets a paragraph's worth of space. A chapter
        // opening brings its own, so it is deliberately not counted here.
        .padding(.top, paragraph.showsSpeakerName ? 32 : 16)
    }

    /// At compact widths there is no margin, so the affordance follows the
    /// paragraph instead of hanging beside it.
    @ViewBuilder
    private var inlineCorrect: some View {
        if isEditable, !isOpen, !layout.hasMargin {
            Button("Correct", action: toggleOpen)
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .accessibilityHint("Opens the segments in this paragraph for editing")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let speaker = paragraph.speakerLabel {
                if isRenamingSpeaker {
                    TextField("Speaker name", text: $speakerDraft)
                        .textFieldStyle(HushnoteFieldStyle())
                        .font(.footnote.weight(.semibold))
                        .frame(width: 180)
                        .focused($speakerFieldFocused)
                        .onSubmit { saveSpeakerName() }
                        .onExitCommand { isRenamingSpeaker = false }
                    Button("Save", action: saveSpeakerName)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                    Button("Cancel") { isRenamingSpeaker = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else {
                    Button {
                        speakerDraft = speaker
                        isRenamingSpeaker = true
                        speakerFieldFocused = true
                    } label: {
                        Text(speaker)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(
                                speaker == "You" ? HushnoteTheme.moss : HushnoteTheme.secondaryInk
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Rename speaker")
                    .accessibilityLabel("Rename \(speaker)")
                }
            }
            if isOpen {
                Spacer(minLength: 12)
                Button("Done", action: toggleOpen)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushnoteTheme.vermilionInk)
            }
        }
    }

    private func saveSpeakerName() {
        guard let segmentID = paragraph.lines.first?.segmentID,
              !speakerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = speakerDraft
        Task {
            if await coordinator.renameSpeaker(segmentID: segmentID, name: value) {
                isRenamingSpeaker = false
            }
        }
    }

    /// The paragraph as one block of text, built run by run so that live text
    /// arriving mid-paragraph can still read as provisional without breaking
    /// the paragraph in two.
    private var prose: some View {
        VStack(alignment: .leading, spacing: 6) {
            proseText
                .font(HushnoteTheme.Font.reading)
                .foregroundStyle(HushnoteTheme.ink)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            inlineCorrect
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(isHovering || isCorrectFocused ? 1 : 0)
        }
    }

    private var proseText: Text {
        paragraph.runs.enumerated().reduce(Text(verbatim: "")) { accumulated, entry in
            let run = Text(verbatim: entry.element.text)
            let styled = entry.element.isProvisional
                ? run.foregroundStyle(HushnoteTheme.secondaryInk).italic()
                : run
            return entry.offset == 0
                ? accumulated + styled
                : accumulated + Text(verbatim: " ") + styled
        }
    }

    /// The paragraph opened up: one field per segment, because one segment is
    /// what a correction is written back to.
    private var segments: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(paragraph.lines) { line in
                TranscriptRow(line: line) { onEdit(line, $0) }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(HushnoteTheme.paperRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(HushnoteTheme.rule.opacity(0.7))
        }
    }

}

/// One segment, while its paragraph is open for correction.
///
/// The row is handed its line by value and keeps its own draft, so it never
/// reads back through the array it came from. The editor used to take a
/// per-element binding out of `ForEach($state.transcript)`, and those resolve by
/// position: when the final pass replaced the transcript with a shorter list of
/// freshly identified segments, a focused field's `controlTextDidEndEditing`
/// read the old position and `Array._checkSubscript` trapped. The row's
/// identity is the line's, so a replacement tears the row down and builds a new
/// one instead of re-reading a position that has moved -- and a paragraph that
/// no longer exists closes rather than keeping a row alive over nothing.
private struct TranscriptRow: View {
    let line: TranscriptLineItem
    let onEdit: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(line: TranscriptLineItem, onEdit: @escaping (String) -> Void) {
        self.line = line
        self.onEdit = onEdit
        _draft = State(initialValue: TranscriptRowText.display(line.text))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimestampButton(seconds: line.start)
            TextField("Transcript", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(HushnoteTheme.Font.reading)
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
        }
        .padding(.vertical, 4)
    }
}

/// Whether the transcript is still following the newest line.
///
/// Auto-scrolling unconditionally fights anyone who has scrolled up to read, so
/// following is a state the user can leave by scrolling and return to
/// deliberately.
enum TranscriptFollow {
    /// - Parameters:
    ///   - bottomInset: blank scroll content below the last paragraph. The
    ///     auto-scroll aligns that paragraph's bottom with the viewport, so the
    ///     inset is *always* still below it -- an inset larger than `tolerance`
    ///     therefore makes every auto-scroll read as the user scrolling away,
    ///     and following switches itself off on the first arriving segment.
    ///   - tolerance: slack so a partly-scrolled line, or a bounce past the
    ///     end, does not read as the user taking over.
    nonisolated static func isFollowing(
        contentOffsetY: Double,
        containerHeight: Double,
        contentHeight: Double,
        bottomInset: Double = 0,
        tolerance: Double = 24
    ) -> Bool {
        contentOffsetY + containerHeight >= contentHeight - bottomInset - tolerance
    }
}

struct AskMeetingView: View {
    let horizontalInset: CGFloat
    var policy: AdaptiveLayoutPolicy = .regular
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state

        ScrollView {
            HStack(alignment: .top, spacing: policy.showsRightRail ? 44 : 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    field(state: state)

                    if !policy.showsRightRail {
                        disclosure.padding(.top, 26)
                    }

                    if let error = state.insights.error {
                        // Answering writes to `insights.error`, which only the
                        // summary workspace used to render -- so a question
                        // that failed looked exactly like one never asked.
                        HushnoteStatusLine(text: error, tone: .warning)
                            .padding(.top, 22)
                    }

                    if state.insights.answer.isEmpty {
                        suggestions.padding(.top, 32)
                    } else {
                        answer.padding(.top, 26)
                    }
                }
                .frame(maxWidth: AdaptiveLayoutPolicy.readingMeasure, alignment: .leading)

                if policy.showsRightRail {
                    rail.frame(width: 232, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 30)
        }
        .scrollIndicators(.never)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask this meeting")
                .font(HushnoteTheme.Font.sectionTitle)
                .foregroundStyle(HushnoteTheme.ink)
            // The differentiator, stated once, where it retires as soon as
            // there is an answer on screen to make the point instead.
            if state.insights.answer.isEmpty {
                Text("Every answer is quoted from the transcript. Nothing that can't be quoted is shown.")
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }

    private func field(state: AppViewState) -> some View {
        @Bindable var state = state

        return VStack(alignment: .leading, spacing: 10) {
            // The one raised surface on the page: an editor well, which is a
            // use the design language explicitly permits. The card that used to
            // wrap the label, the field and the button is gone.
            TextField(
                state.insights.answer.isEmpty ? "What did we agree to ship?" : "Ask another question…",
                text: $state.insights.question,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.body)
            .lineLimit(2...5)
            .hushnoteField()
            .accessibilityLabel("Your question")

            HStack(spacing: 10) {
                Button(state.insights.isGenerating ? "Asking…" : "Ask") {
                    Task { await coordinator.answerQuestion() }
                }
                .hushnoteButton(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isAskDisabled)

                // `.onSubmit` on a vertical-axis field inserts a newline as
                // often as it submits, so the shortcut is advertised instead.
                Text("⌘↩")
                    .font(.caption2.monospaced())
                    .foregroundStyle(HushnoteTheme.secondaryInk)

                if state.insights.isGenerating {
                    HushnoteStatusLine(text: "Checking every quote against the transcript…", tone: .working)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var isAskDisabled: Bool {
        state.insights.isGenerating
            || state.insights.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.transcript.isEmpty
    }

    // MARK: - Where to start

    private var suggestionList: [AskSuggestionPolicy.Suggestion] {
        AskSuggestionPolicy.suggestions(
            openQuestions: state.insights.openQuestions,
            topics: state.insights.topics,
            decisions: state.insights.decisions,
            speakers: AskSuggestionPolicy.namedSpeakers(
                lineCountsBySpeaker: state.transcript.reduce(into: [:]) { counts, line in
                    counts[line.speaker, default: 0] += 1
                }
            ),
            template: state.draft.template
        )
    }

    @ViewBuilder
    private var suggestions: some View {
        if state.transcript.isEmpty {
            HushnoteEmptyState(
                title: "Nothing to ask yet",
                message: "This meeting has no transcript. Record it, or finalize the recovery, and everything said becomes answerable here.",
                policy: policy
            ) {
                HushnoteGlyph(systemName: "text.magnifyingglass")
            }
        } else {
            let suggestions = suggestionList
            VStack(alignment: .leading, spacing: 0) {
                HushnoteEyebrow("Where to start")
                    .padding(.bottom, 14)

                ForEach(suggestions) { suggestion in
                    Button {
                        state.insights.question = suggestion.text
                        Task { await coordinator.answerQuestion() }
                    } label: {
                        HStack {
                            Text(suggestion.text)
                                .font(.callout)
                                .foregroundStyle(HushnoteTheme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 12)
                            Image(systemName: "return")
                                .font(.caption)
                                .foregroundStyle(HushnoteTheme.secondaryInk)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hushnoteBottomRule(opacity: 0.5)
                }

                Text(AskSuggestionPolicy.caption(for: suggestions))
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: - The finding

    private var answer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.insights.question.isEmpty ? "Answer" : state.insights.question)
                .font(HushnoteTheme.Font.subsectionTitle)
                .foregroundStyle(HushnoteTheme.ink)
                .padding(.bottom, 12)

            Text(state.insights.answer)
                .font(HushnoteTheme.Font.reading)
                .foregroundStyle(HushnoteTheme.ink)
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if state.insights.rejectedCitations > 0 {
                // The app's whole thesis, demonstrated. This count was computed
                // and thrown away; it is the opposite of alarming.
                HushnoteStatusLine(
                    text: rejectedCitationsMessage,
                    tone: .warning
                )
                .padding(.top, 22)
            }

            if !state.insights.answerCitations.isEmpty {
                HushnoteEyebrow("Evidence")
                    .padding(.top, 28)
                    .padding(.bottom, 14)

                ForEach(state.insights.answerCitations, id: \.segmentID) { citation in
                    AskEvidenceBlock(citation: citation) {
                        // The evidence is already on this meeting's transcript,
                        // so the jump only has to change tab and scroll.
                        coordinator.revealTranscriptSegment(citation.segmentID)
                    }
                    .padding(.bottom, 16)
                }
            }

            HushnoteRule(opacity: 0.45).padding(.top, 8)

            HStack(spacing: 10) {
                Text(state.selectedProvider.displayName)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                Spacer(minLength: 12)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.insights.answer, forType: .string)
                }
                Button("Ask again") { Task { await coordinator.answerQuestion() } }
                    .disabled(state.insights.isGenerating)
            }
            .hushnoteButton(.quiet)
            .padding(.top, 14)
        }
    }

    private var rejectedCitationsMessage: String {
        let count = state.insights.rejectedCitations
        return count == 1
            ? "1 quote the model offered wasn't in the transcript and was removed."
            : "\(count) quotes the model offered weren't in the transcript and were removed."
    }

    // MARK: - Disclosure

    private var disclosureValue: AskDisclosurePolicy.Disclosure {
        AskDisclosurePolicy.disclosure(
            provider: state.selectedProvider,
            model: nil,
            transcriptDuration: state.transcript.last?.end ?? 0,
            wordCount: state.transcript.reduce(0) { $0 + $1.text.split(separator: " ").count }
        )
    }

    private var disclosure: some View {
        let disclosure = disclosureValue

        return VStack(alignment: .leading, spacing: 8) {
            HushnoteBadge(
                title: disclosure.badge,
                tone: disclosure.reach == .onDevice ? .positive : .alert
            )
            Text(disclosure.providerLine)
                .font(.caption.weight(.medium))
                .foregroundStyle(HushnoteTheme.ink)
            Text(disclosure.detail)
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button(disclosure.actionTitle) { coordinator.setSelection(.settings) }
                .hushnoteButton(.quiet)
                .padding(.leading, -10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(disclosure.badge). \(disclosure.providerLine). \(disclosure.detail)")
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                HushnoteEyebrow("Asks")
                disclosure
            }

            if !state.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HushnoteEyebrow("This meeting")
                    Text(DurationText.clock(state.transcript.last?.end ?? 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                    Text("\(state.transcript.count) lines")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                    Text(state.insights.summary.isEmpty ? "No summary yet" : "Summary generated")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
            }
        }
    }
}

/// One quote behind an answer: when it was said, and the words themselves,
/// already proven present in the transcript by `CitationValidator`.
private struct AskEvidenceBlock: View {
    let citation: EvidenceCitation
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(HushnoteTheme.moss.opacity(0.55))
                .frame(width: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                TimestampButton(
                    seconds: TimeInterval(citation.startMilliseconds) / 1_000,
                    action: reveal
                )
                Text(citation.quote)
                    .font(HushnoteTheme.Font.quotation)
                    .foregroundStyle(HushnoteTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Show in transcript", action: reveal)
                    .hushnoteButton(.quiet)
                    .font(.caption)
                    .padding(.leading, -10)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
