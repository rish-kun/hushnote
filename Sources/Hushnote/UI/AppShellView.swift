import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let hushnoteNewFolder = Notification.Name("hushnote.new-folder")
    static let hushnoteSearchMeetings = Notification.Name("hushnote.search-meetings")
    static let hushnoteToggleSidebar = Notification.Name("hushnote.toggle-sidebar")
    static let hushnoteStampMoment = Notification.Name("hushnote.stamp-moment")
}

struct AppShellView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isShowingSearch = false
    @State private var searchQuery = ""
    @State private var selectedSearchResultID: UUID?
    @State private var newFolderRequestID = UUID()

    var body: some View {
        @Bindable var state = state
        let meetings = state.filteredMeetings

        return AppShellWindowToolbar(
            columnVisibility: $columnVisibility,
            isNewTranscriptionDisabled: state.recordingPhase.isBusy,
            createNewTranscription: {
                Task { await coordinator.createMeetingNote() }
            },
            presentSearch: presentSearch
        ) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarNavigationView(
                    meetings: meetings,
                    newFolderRequestID: newFolderRequestID
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: HushnoteTheme.sidebarWidth, max: 300)
                .safeAreaInset(edge: .bottom) {
                    recordingSidebarFooter
                }
                // `removing:` only has an effect on the column that installs
                // the stock item. Applied to a container *around*
                // NavigationSplitView it silently does nothing, and the split
                // view goes on drawing its own toggle beside ours -- two
                // sidebar buttons in one titlebar.
                .toolbar(removing: .sidebarToggle)
            } detail: {
                VStack(spacing: 0) {
                    if case .failed(let failure) = state.recordingPhase {
                        recordingErrorBanner(failure)
                    }
                    detail
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Detail owns one continuous paper surface. Destinations decide
                // their own content geometry, so the shell must not wrap every
                // route in a second scaffold or canvas.
                .paperBackground()
            }
            .navigationSplitViewStyle(.balanced)
            // `.task(id:)` cancels the previous run, so a keystroke replaces the
            // pending query instead of racing it: one FTS5 query per pause, not
            // one per character. Keeping it on the split view means a command
            // palette search works even while the navigation column is hidden.
            .task(id: state.searchText) {
                let query = state.searchText
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await coordinator.searchMeetings(query)
            }
        }
        .sheet(isPresented: $isShowingSearch, onDismiss: clearSearch) {
            MeetingSearchPalette(
                query: $searchQuery,
                selectedMeetingID: $selectedSearchResultID,
                onOpen: openSearchResult,
                onOpenMoment: openSearchMoment,
                onDismiss: { isShowingSearch = false }
            )
            .environment(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hushnoteNewFolder)) { _ in
            columnVisibility = .all
            state.searchText = ""
            newFolderRequestID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hushnoteSearchMeetings)) { _ in
            presentSearch()
        }
        // The titlebar-hosted toggle cannot carry its own shortcut, so the View
        // menu drives the same state transition.
        .onReceive(NotificationCenter.default.publisher(for: .hushnoteToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
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

    private func presentSearch() {
        searchQuery = ""
        selectedSearchResultID = nil
        state.searchText = ""
        isShowingSearch = true
    }

    private func openSearchResult(_ id: UUID) {
        coordinator.setSelection(.meeting(id))
        isShowingSearch = false
    }

    /// Opens the meeting *at* the matched line rather than at its remembered
    /// tab. The user asked for a moment, so the transcript is what they get.
    private func openSearchMoment(_ meetingID: UUID, _ segmentID: String) {
        coordinator.openMeetingMoment(meetingID: meetingID, segmentID: segmentID)
        isShowingSearch = false
    }

    private func clearSearch() {
        searchQuery = ""
        selectedSearchResultID = nil
        state.searchText = ""
        state.searchPhase = .idle
        state.searchResults = []
        Task { await coordinator.searchMeetings("") }
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
                .hushnoteButton(.secondary)
        case .retryRecording(let id):
            Button("Try Again") { Task { await coordinator.startMeeting(meetingID: id) } }
                .hushnoteButton(.recording)
        case .retryFinalization(let id):
            Button("Finalize Again") { Task { await coordinator.recoverMeeting(id) } }
                .hushnoteButton(.recording)
        case .openModels:
            Button("Open Models") { coordinator.setSelection(.models) }
                .hushnoteButton(.primary)
        case .openSettings:
            Button("Open Settings") { coordinator.setSelection(.settings) }
                .hushnoteButton(.primary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .meetings, nil:
            MeetingsHomeView()
        case .unfiled:
            MeetingsHomeView(scope: .unfiled)
        case .folder(let id):
            MeetingsHomeView(scope: .folder(id))
        case .shared:
            SharedLinksView()
        case .recentlyDeleted:
            MeetingsHomeView(scope: .recentlyDeleted)
        case .models:
            ModelManagerView()
        case .storage:
            StorageDashboardView()
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
                if let id = state.activeMeetingID { coordinator.setSelection(.meeting(id)) }
            } label: {
                HStack(spacing: 10) {
                    RecordingPulse(isActive: state.recordingPhase == .recording)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecordingStatusText.label(for: state.recordingPhase))
                            .font(.callout.weight(.semibold))
                        // A leaf view: without it this whole shell body -- and
                        // the O(n) meeting filter in it -- re-evaluated once a
                        // second for the length of the meeting.
                        ElapsedTimeLabel(font: .caption.monospacedDigit())
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk.opacity(0.72))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(HushnoteTheme.navigationSurface)
            .overlay(alignment: .top) { HushnoteRule(opacity: 0.65) }
        } else if state.recordingPhase == .preparing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(RecordingStatusText.label(for: .preparing)).font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HushnoteTheme.navigationSurface)
        } else if case .finalizing = state.recordingPhase {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(state.finalizationLabel).font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HushnoteTheme.navigationSurface)
        }
    }
}

/// One addressable line in the palette. The list the keyboard walks is flat,
/// even though the rows are drawn grouped by meeting.
private enum SearchEntry: Hashable {
    case meeting(UUID)
    case moment(meetingID: UUID, segmentID: String)

    var meetingID: UUID {
        switch self {
        case .meeting(let id): id
        case .moment(let id, _): id
        }
    }
}

/// The ⌘K palette.
///
/// Deliberately banded rather than stacked: the field, the listing and the
/// legend each run edge to edge and own their inset, separated by a hairline
/// rather than by air. The previous layout put four blocks at one uniform gap
/// inside one uniform padding, so nothing was emphasised -- including the
/// field, which is the entire point of the screen.
private struct MeetingSearchPalette: View {
    @Binding var query: String
    @Binding var selectedMeetingID: UUID?
    let onOpen: (UUID) -> Void
    let onOpenMoment: (UUID, String) -> Void
    let onDismiss: () -> Void
    @Environment(AppViewState.self) private var state
    @FocusState private var isSearchFieldFocused: Bool
    @State private var selection: SearchEntry?

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// On open the palette shows recents rather than a poster. Pressing
    /// down-down-return is then a two-second path to yesterday's meeting, and
    /// the row shape is learned before it has to be read under time pressure.
    private var results: [MeetingSearchResult] {
        hasQuery
            ? state.searchResults
            : state.meetings.prefix(8).map {
                MeetingSearchResult(meeting: $0, moments: [], additionalMomentCount: 0)
            }
    }

    /// Visual order, flattened. This is what ↑↓ walk.
    private var entries: [SearchEntry] {
        results.flatMap { result in
            [.meeting(result.id)]
                + result.moments.map { .moment(meetingID: result.id, segmentID: $0.id) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            HushnoteRule()
            body(for: results)
            HushnoteRule()
            legend
        }
        .frame(width: 640)
        .background(HushnoteTheme.paperRaised)
        .task {
            isSearchFieldFocused = true
            selection = entries.first
        }
        .onMoveCommand(perform: moveSelection)
        // The Cancel button used to carry `.cancelAction`, so deleting it would
        // have silently taken Escape with it.
        .onExitCommand(perform: onDismiss)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(isSearchFieldFocused ? HushnoteTheme.ink : HushnoteTheme.secondaryInk)
            TextField("Search every meeting", text: $query)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 18))
                .foregroundStyle(HushnoteTheme.ink)
                .focused($isSearchFieldFocused)
                .accessibilityLabel("Search every meeting")
                .onSubmit(openSelection)
                .onChange(of: query) { _, value in
                    state.searchText = value
                    state.searchPhase = value.isEmpty ? .idle : .pending
                    selection = entries.first
                }
            if hasQuery {
                Button {
                    query = ""
                    state.searchText = ""
                    state.searchPhase = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        // The focus indication is a moss underline rather than a box: a rounded
        // rectangle inside a 640-point edge-to-edge band fights the panel.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HushnoteTheme.moss)
                .frame(height: 2)
                .opacity(isSearchFieldFocused ? 1 : 0)
        }
    }

    @ViewBuilder
    private func body(for results: [MeetingSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HushnoteEyebrow(eyebrow)
                .padding(.horizontal, 20)
                .frame(height: 28, alignment: .leading)

            if results.isEmpty {
                emptyBody
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                MeetingSearchRow(
                                    result: result,
                                    selection: selection,
                                    open: { onOpen(result.id) },
                                    openMoment: { onOpenMoment(result.id, $0) }
                                )
                                .id(SearchEntry.meeting(result.id))
                                HushnoteRule(opacity: 0.5)
                            }
                        }
                    }
                    .onChange(of: selection) { _, entry in
                        guard let entry else { return }
                        proxy.scrollTo(entry.meetingID.hashValue == 0 ? entry : entry, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 400, alignment: .top)
    }

    @ViewBuilder
    private var emptyBody: some View {
        if state.meetings.isEmpty {
            paletteEmptyState(
                title: "No meetings yet",
                message: "Record one, and everything said in it becomes searchable here."
            )
        } else {
            paletteEmptyState(
                title: "No matching meetings",
                message: "Try a title, a speaker, or a phrase somebody actually said."
            )
        }
    }

    private func paletteEmptyState(title: String, message: String) -> some View {
        HushnoteEmptyState(title: title, message: message) {
            HushnoteGlyph(systemName: "magnifyingglass")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The only thing that changes during the debounce. A 12-point uppercase
    /// label can swap ten times a second without reading as flicker; a spinner
    /// cannot, which is why there isn't one.
    private var eyebrow: String {
        guard hasQuery else { return "Recent" }
        if state.searchPhase == .pending { return "Searching transcripts…" }
        let moments = results.reduce(0) { $0 + $1.moments.count }
        guard moments > 0 else {
            return results.isEmpty ? "No matches" : "\(results.count) by title"
        }
        return "\(moments) moment\(moments == 1 ? "" : "s") in \(results.count) meeting\(results.count == 1 ? "" : "s")"
    }

    private var legend: some View {
        Text("↑↓ choose · ↩ open · ⌘↩ open meeting · esc close")
            .font(.caption)
            .foregroundStyle(HushnoteTheme.secondaryInk)
            .padding(.horizontal, 20)
            .frame(height: 34, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Keyboard shortcuts. Up and down arrows choose. Return opens. Command Return opens the meeting. Escape closes."
            )
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let entries = entries
        guard !entries.isEmpty else { return }
        let current = selection.flatMap { entries.firstIndex(of: $0) } ?? 0
        switch direction {
        // Clamped rather than wrapped: springing from the last row to the first
        // loses the reader's place in a list they are scanning.
        case .down: selection = entries[min(current + 1, entries.count - 1)]
        case .up: selection = entries[max(current - 1, 0)]
        default: break
        }
        selectedMeetingID = selection?.meetingID
    }

    private func openSelection() {
        switch selection ?? entries.first {
        case .meeting(let id): onOpen(id)
        case .moment(let meetingID, let segmentID): onOpenMoment(meetingID, segmentID)
        case nil: break
        }
    }
}

/// One meeting in the palette, with the moments inside it that matched.
private struct MeetingSearchRow: View {
    let result: MeetingSearchResult
    let selection: SearchEntry?
    let open: () -> Void
    let openMoment: (String) -> Void

    private var isMeetingSelected: Bool { selection == .meeting(result.id) }

    private var isAnythingHereSelected: Bool {
        selection?.meetingID == result.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HushnoteRowDate(date: result.meeting.startedAt)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Text(result.meeting.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(HushnoteTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(DurationText.clock(result.meeting.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(result.meeting.title)")
                .accessibilityAddTraits(isMeetingSelected ? [.isSelected] : [])

                if result.moments.isEmpty {
                    Text(result.meeting.excerpt.isEmpty ? "No transcript yet" : result.meeting.excerpt)
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .lineLimit(1)
                } else {
                    ForEach(result.moments) { moment in
                        MeetingSearchMomentLine(
                            moment: moment,
                            isSelected: selection == .moment(
                                meetingID: result.id,
                                segmentID: moment.id
                            ),
                            open: { openMoment(moment.id) }
                        )
                    }
                    if result.additionalMomentCount > 0 {
                        Text("+\(result.additionalMomentCount) more in this meeting")
                            .font(.caption2)
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if isAnythingHereSelected {
                HushnoteTheme.selectionSurface
                    .overlay(alignment: .leading) {
                        // The tint alone gives the eye no anchor at this width,
                        // and is the only cue a colour-blind reader would lose.
                        Rectangle()
                            .fill(HushnoteTheme.moss)
                            .frame(width: 2)
                    }
            }
        }
    }
}

/// A matched line of transcript: when it was said, by whom, and what was said.
private struct MeetingSearchMomentLine: View {
    let moment: MeetingSearchMoment
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                // A moss capsule, because this one really does go somewhere.
                TimestampButton(seconds: moment.start, action: open)
                if let speaker = moment.speaker, !speaker.isEmpty {
                    Text(speaker)
                        .font(.caption2)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                Text(moment.text)
                    .font(.caption)
                    .foregroundStyle(isSelected ? HushnoteTheme.ink : HushnoteTheme.secondaryInk)
                    // One line each: two moments at one line beat one moment at
                    // two, because breadth is what tells you which meeting.
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            moment.speaker.map { "\($0): \(moment.text)" } ?? moment.text
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The sole owner of Hushnote's window toolbar. Keeping this real container
/// outside `NavigationSplitView` prevents SwiftUI from re-homing the leading
/// toggle into whichever split-view column happens to be visible.
private struct AppShellWindowToolbar<Content: View>: View {
    @Binding private var columnVisibility: NavigationSplitViewVisibility
    private let isNewTranscriptionDisabled: Bool
    private let createNewTranscription: () -> Void
    private let presentSearch: () -> Void
    private let content: Content

    init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        isNewTranscriptionDisabled: Bool,
        createNewTranscription: @escaping () -> Void,
        presentSearch: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _columnVisibility = columnVisibility
        self.isNewTranscriptionDisabled = isNewTranscriptionDisabled
        self.createNewTranscription = createNewTranscription
        self.presentSearch = presentSearch
        self.content = content()
    }

    var body: some View {
        // A concrete container is required here. Applying `.toolbar` straight
        // to generic `content` would still make NavigationSplitView its host.
        ZStack {
            content
        }
            // The toggle is deliberately absent from `.toolbar`. Every toolbar
            // placement macOS offers inside a split view is measured from a
            // column edge, so a toolbar-hosted toggle shifts sideways each time
            // the sidebar opens. It lives in the titlebar instead.
            .background(
                SidebarToggleTitlebarAccessory(columnVisibility: $columnVisibility)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if columnVisibility == .detailOnly {
                        Button("New Transcription", action: createNewTranscription)
                            .hushnoteButton(.primary)
                            .disabled(isNewTranscriptionDisabled)
                            .help("Create a new meeting transcription")
                            .accessibilityLabel("New Transcription")
                            .accessibilityHint("Creates a new meeting note ready to transcribe")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: presentSearch) {
                        Label("Search meetings", systemImage: "magnifyingglass")
                    }
                    .help("Search meetings (⌘K)")
                }
            }
            .toolbarBackground(HushnoteTheme.paper, for: .windowToolbar)
    }
}

/// A semantic, app-owned substitute for NavigationSplitView's default toolbar
/// item. Rendered exactly once, inside the window's titlebar accessory.
///
/// It carries no `keyboardShortcut`: a hosted titlebar view is not in the key
/// window's menu responder chain, so the shortcut would look present and never
/// fire. The View menu owns it instead.
private struct AppSidebarToggle: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isHovering = false

    private var sidebarIsVisible: Bool {
        columnVisibility != .detailOnly
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = sidebarIsVisible ? .detailOnly : .all
            }
        } label: {
            Image(systemName: sidebarIsVisible ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(HushnoteTheme.ink.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .help(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityHint("Shows or hides Hushnote navigation")
    }
}

/// Pins the sidebar toggle to the window titlebar, immediately after the
/// traffic lights.
///
/// Every SwiftUI toolbar placement available inside `NavigationSplitView` is
/// resolved against a split-view column: `.navigation` re-homes into whichever
/// column is showing, and `.automatic` is measured from the detail column's
/// leading edge. Either way the toggle slides horizontally the moment the
/// sidebar collapses -- which is the bug this replaces.
/// `NSTitlebarAccessoryViewController` with a `.leading` layout attribute is
/// positioned by the window, not by the split view, so the control keeps one
/// constant position in both states.
private struct SidebarToggleTitlebarAccessory: NSViewRepresentable {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    func makeNSView(context: Context) -> SidebarToggleAccessoryProbe {
        SidebarToggleAccessoryProbe()
    }

    func updateNSView(_ nsView: SidebarToggleAccessoryProbe, context: Context) {
        nsView.apply(AppSidebarToggle(columnVisibility: $columnVisibility))
    }

    static func dismantleNSView(_ nsView: SidebarToggleAccessoryProbe, coordinator: ()) {
        nsView.detach()
    }
}

/// A zero-sized probe that reaches its host window and installs the accessory.
///
/// The window is not known at `makeNSView` time, so installation is deferred to
/// `viewDidMoveToWindow` and the most recent toggle is held until then.
private final class SidebarToggleAccessoryProbe: NSView {
    private var hosting: NSHostingView<AppSidebarToggle>?
    private var controller: NSTitlebarAccessoryViewController?
    private weak var installedWindow: NSWindow?
    private var pending: AppSidebarToggle?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pending { apply(pending) }
    }

    func apply(_ toggle: AppSidebarToggle) {
        pending = toggle

        guard let window else { return }

        if installedWindow === window, let hosting {
            // SwiftUI hands us a fresh value on every state change; the
            // accessory is installed once and re-rendered in place.
            hosting.rootView = toggle
            return
        }

        detach()

        let hostingView = NSHostingView(rootView: toggle)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = hostingView

        window.addTitlebarAccessoryViewController(accessory)

        hosting = hostingView
        controller = accessory
        installedWindow = window
    }

    /// Removing the controller from its parent is what actually detaches it;
    /// dropping our reference alone leaves a stale button in the titlebar when
    /// the window is rebuilt.
    func detach() {
        controller?.removeFromParent()
        controller = nil
        hosting = nil
        installedWindow = nil
    }
}

private struct SidebarNavigationView: View {
    let meetings: [MeetingListItem]
    let newFolderRequestID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var folderEditor: FolderEditorMode?
    @State private var folderPendingDeletion: MeetingFolder?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        HushnoteBrandMark()
                            .frame(width: 19, height: 19)
                        Text("Hushnote")
                            .font(.headline.weight(.semibold))
                    }
                    Text("Private meeting notebook")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }

                Button {
                    Task { await coordinator.createMeetingNote() }
                } label: {
                    Label("New Transcription", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .hushnoteButton(.primary)
                .disabled(state.recordingPhase.isBusy)
                .accessibilityHint("Creates a new meeting note ready to transcribe")

                sidebarSection("Library") {
                    SidebarNavigationRow(
                        title: "All Meetings",
                        systemImage: "text.book.closed",
                        count: meetings.count,
                        isSelected: state.selection == nil || state.selection == .meetings
                    ) { coordinator.setSelection(.meetings) }

                    SidebarNavigationRow(
                        title: "Unfiled",
                        systemImage: "tray",
                        count: state.unfiledMeetingCount,
                        isSelected: state.selection == .unfiled
                    ) { coordinator.setSelection(.unfiled) }

                    // Only once there is something to manage. There is no web
                    // dashboard, so this route is the only place a published
                    // link can be seen or withdrawn -- but an empty row for a
                    // feature nobody has used is just a permanent advert.
                    if !state.meetingShares.isEmpty {
                        SidebarNavigationRow(
                            title: "Shared",
                            systemImage: "link",
                            count: state.meetingShares.count,
                            isSelected: state.selection == .shared
                        ) { coordinator.setSelection(.shared) }
                    }

                    SidebarNavigationRow(
                        title: "Recently Deleted",
                        systemImage: "trash",
                        count: state.recentlyDeletedMeetings.count,
                        isSelected: state.selection == .recentlyDeleted
                    ) { coordinator.setSelection(.recentlyDeleted) }
                }

                sidebarSection("Folders", action: presentNewFolder) {
                    if state.folders.isEmpty {
                        Button("New Folder", systemImage: "folder.badge.plus", action: presentNewFolder)
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    } else {
                        ForEach(state.folders) { folder in
                            SidebarNavigationRow(
                                title: folder.name,
                                systemImage: "folder",
                                count: state.folderMeetingCounts[folder.id, default: 0],
                                isSelected: state.selection == .folder(folder.id),
                                action: { coordinator.setSelection(.folder(folder.id)) }
                            ) {
                                SidebarRowMenu(
                                    name: folder.name,
                                    rename: { folderEditor = .rename(folder) },
                                    delete: { folderPendingDeletion = folder },
                                    isProminent: state.selection == .folder(folder.id)
                                )
                            }
                            .contextMenu {
                                Button("Rename…") { folderEditor = .rename(folder) }
                                Divider()
                                Button("Delete Folder", role: .destructive) {
                                    folderPendingDeletion = folder
                                }
                            }
                        }
                    }
                }

                if !meetings.isEmpty {
                    sidebarSection("Recent") {
                        ForEach(meetings.prefix(8)) { meeting in
                            SidebarNavigationRow(
                                title: meeting.title,
                                subtitle: meeting.startedAt.formatted(.dateTime.month(.abbreviated).day()),
                                systemImage: "doc.text",
                                isSelected: state.selection == .meeting(meeting.id)
                            ) { coordinator.setSelection(.meeting(meeting.id)) }
                            .contextMenu {
                                recentMeetingActions(meeting)
                            }
                            .accessibilityAction(named: "Rename") {
                                coordinator.promptToRenameMeeting(meetingID: meeting.id)
                            }
                            .accessibilityAction(named: "Move to Recently Deleted") {
                                guard state.activeMeetingID != meeting.id else { return }
                                Task { await coordinator.softDeleteMeeting(meeting.id) }
                            }
                        }
                    }
                }

                sidebarSection("System") {
                    SidebarNavigationRow(
                        title: "Models",
                        systemImage: "cpu",
                        isSelected: state.selection == .models
                    ) { coordinator.setSelection(.models) }
                    SidebarNavigationRow(
                        title: "Storage",
                        systemImage: "internaldrive",
                        isSelected: state.selection == .storage
                    ) { coordinator.setSelection(.storage) }
                    SidebarNavigationRow(
                        title: "Settings",
                        systemImage: "slider.horizontal.3",
                        isSelected: state.selection == .settings
                    ) { coordinator.setSelection(.settings) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
            // `scrollIndicators(.hidden)` does not reliably suppress the
            // AppKit scroller installed for this sidebar on every macOS
            // appearance. Configure this ScrollView's nearest native owner
            // instead, without touching detail or workspace scroll views.
            .modifier(SidebarScrollerVisibilityModifier())
        }
        // `.never` is stronger than `.hidden` on macOS: it prevents the
        // system "Always show scroll bars" preference from drawing sidebar
        // chrome while leaving every scrolling input available.
        .scrollIndicators(.never)
        .background(HushnoteTheme.navigationSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HushnoteTheme.rule.opacity(0.62))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .foregroundStyle(HushnoteTheme.ink)
        .onChange(of: newFolderRequestID) { _, _ in
            presentNewFolder()
        }
        .sheet(item: $folderEditor) { editor in
            FolderEditorSheet(editor: editor)
                .environment(state)
                .environment(coordinator)
        }
        .alert(
            "Delete folder?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            presenting: folderPendingDeletion
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                folderPendingDeletion = nil
                Task { await coordinator.deleteMeetingFolder(folder.id) }
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: { folder in
            Text("“\(folder.name)” will be removed. Its meetings will remain available in Unfiled.")
        }
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        _ title: String,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HushnoteEyebrow(title)
                Spacer(minLength: 4)
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")
                    .accessibilityLabel("New Folder")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, action == nil ? 10 : 4)
            content()
        }
    }

    private func presentNewFolder() {
        folderEditor = .new
    }

    @ViewBuilder
    private func recentMeetingActions(_ meeting: MeetingListItem) -> some View {
        Button("Rename…") {
            coordinator.promptToRenameMeeting(meetingID: meeting.id)
        }
        Menu("Move to Folder") {
            Button("Unfiled") {
                Task { await coordinator.moveMeeting(meeting.id, toFolder: nil) }
            }
            .disabled(meeting.folderID == nil)

            if !state.folders.isEmpty {
                Divider()
                ForEach(state.folders) { folder in
                    Button(folder.name) {
                        Task { await coordinator.moveMeeting(meeting.id, toFolder: folder.id) }
                    }
                    .disabled(meeting.folderID == folder.id)
                }
            }
        }
        Divider()
        Button("Move to Recently Deleted", role: .destructive) {
            // `softDeleteMeeting` owns the unsaved-summary confirmation before
            // it mutates navigation or persistence, so sidebar actions retain
            // the same safety guarantee as inventory-row actions.
            Task { await coordinator.softDeleteMeeting(meeting.id) }
        }
        .disabled(state.activeMeetingID == meeting.id)
    }
}

/// Native scroller policy for the navigation column. Hiding the scroller does
/// not disable the scroll view itself: trackpad, wheel, keyboard and
/// accessibility scrolling continue to be handled by `NSScrollView`.
struct SidebarScrollerConfiguration: Equatable {
    let hidesVerticalScroller: Bool
    let autohidesScrollers: Bool

    static let navigation = Self(
        hidesVerticalScroller: true,
        autohidesScrollers: true
    )
}

private struct SidebarScrollerVisibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(SidebarScrollerConfigurationView())
    }
}

/// SwiftUI's `.scrollIndicators(.hidden)` is advisory on macOS. This tiny
/// probe sits *inside* the sidebar's `ScrollView`, finds its closest enclosing
/// `NSScrollView`, and changes only that instance's scroller chrome.
private struct SidebarScrollerConfigurationView: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarScrollerConfigurationProbe {
        SidebarScrollerConfigurationProbe()
    }

    func updateNSView(_ nsView: SidebarScrollerConfigurationProbe, context: Context) {
        nsView.applyConfigurationWhenAttached()
    }
}

private final class SidebarScrollerConfigurationProbe: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyConfigurationWhenAttached()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfigurationWhenAttached()
    }

    override func layout() {
        super.layout()
        // SwiftUI may restore AppKit scroller properties during a later layout
        // pass. Reassert the sidebar-only policy whenever this probe lays out.
        applyConfiguration()
    }

    func applyConfigurationWhenAttached() {
        // SwiftUI may attach the background before it has inserted the
        // surrounding NSScrollView, so defer the lookup to the next run loop.
        DispatchQueue.main.async { [weak self] in
            self?.applyConfiguration()
        }
    }

    private func applyConfiguration() {
        guard let scrollView = nearestEnclosingScrollView else { return }
        let configuration = SidebarScrollerConfiguration.navigation
        scrollView.hasVerticalScroller = !configuration.hidesVerticalScroller
        scrollView.autohidesScrollers = configuration.autohidesScrollers
        scrollView.verticalScroller?.isHidden = configuration.hidesVerticalScroller
    }

    private var nearestEnclosingScrollView: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }
}

/// One row for every sidebar destination, folders included.
///
/// There used to be two. `SidebarNavigationRow` padded `.horizontal, 10` and
/// kept its count inside the button; `SidebarFolderRow` padded `.leading, 10`
/// and placed a 26-point menu after its count. The two counts therefore landed
/// roughly 29 points apart, and the sidebar's number column read as ragged.
///
/// The menu slot is reserved on every row whether or not that row has a menu,
/// which is what actually holds the counts on one axis.
private struct SidebarNavigationRow<Actions: View>: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HushnoteSelectableRow(isSelected: isSelected, select: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                }
            }
        } trailing: {
            HStack(spacing: 4) {
                if let count {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                ZStack {
                    // Reserves the slot. `EmptyView` drops its frame, so an
                    // actual clear rectangle is what holds the column.
                    Color.clear.frame(width: 22, height: 22)
                    actions
                }
            }
        }
    }
}

extension SidebarNavigationRow where Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        count: Int? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            count: count,
            isSelected: isSelected,
            action: action
        ) { EmptyView() }
    }
}

/// The trailing menu a folder row carries. Hover-dimmed rather than hidden, so
/// the affordance is discoverable without keyboard users losing it.
private struct SidebarRowMenu: View {
    let name: String
    let rename: () -> Void
    let delete: () -> Void
    var isProminent: Bool

    var body: some View {
        Menu {
            Button("Rename…", action: rename)
            Divider()
            Button("Delete Folder", role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More actions for \(name)")
        .accessibilityLabel("More actions for \(name)")
        .opacity(isProminent ? 1 : 0.58)
    }
}

private enum FolderEditorMode: Identifiable {
    case new
    case rename(MeetingFolder)

    var id: String {
        switch self {
        case .new: "new-folder"
        case .rename(let folder): "rename-\(folder.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .new: "New Folder"
        case .rename: "Rename Folder"
        }
    }

    var initialName: String {
        if case .rename(let folder) = self { return folder.name }
        return ""
    }

    var renamedFolderID: UUID? {
        if case .rename(let folder) = self { return folder.id }
        return nil
    }
}

private struct FolderEditorSheet: View {
    let editor: FolderEditorMode
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var validationMessage: String?

    init(editor: FolderEditorMode) {
        self.editor = editor
        _name = State(initialValue: editor.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editor.title)
                .font(HushnoteTheme.Font.sectionTitle)

            VStack(alignment: .leading, spacing: 7) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField("Folder name", text: $name)
                    .textFieldStyle(HushnoteFieldStyle())
                    .focused($isNameFocused)
                    .onSubmit(save)
                    .onChange(of: name) { _, _ in validationMessage = nil }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.vermilionInk)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use 1–80 characters. Folder names must be unique.")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editor.renamedFolderID == nil ? "Create Folder" : "Save") {
                    save()
                }
                .hushnoteButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { isNameFocused = true }
    }

    private func save() {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            validationMessage = "Enter a folder name."
            return
        }
        guard cleaned.count <= 80 else {
            validationMessage = "Use 80 characters or fewer."
            return
        }
        let currentID = editor.renamedFolderID
        if state.folders.contains(where: {
            $0.id != currentID && $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                == cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }) {
            validationMessage = "A folder named “\(cleaned)” already exists."
            return
        }

        Task {
            if let id = editor.renamedFolderID {
                await coordinator.renameMeetingFolder(id, to: cleaned)
                dismiss()
            } else if let folder = await coordinator.createMeetingFolder(named: cleaned) {
                coordinator.setSelection(.folder(folder.id))
                dismiss()
            } else {
                // The database remains the final uniqueness authority. The
                // preflight above catches ordinary duplicates; this covers a
                // race with another writer without silently closing the sheet.
                validationMessage = "That folder could not be saved. Choose a different name and try again."
            }
        }
    }
}

enum MeetingLibraryScope: Equatable {
    case all
    case unfiled
    case folder(UUID)
    case recentlyDeleted
}

struct MeetingsHomeView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isShowingRecentlyDeleted = false
    @State private var isShowingRecordingImporter = false
    var scope: MeetingLibraryScope = .all

    var body: some View {
        let meetings = scopedMeetings
        let recentlyDeleted = scope == .all || scope == .recentlyDeleted
            ? state.recentlyDeletedMeetings
            : []

        return ScrollView {
            AdaptivePageScaffold { policy in
                VStack(alignment: .leading, spacing: 0) {
                    libraryHeader(policy: policy)

                    HushnoteRule(opacity: 0.68)

                    if meetings.isEmpty && recentlyDeleted.isEmpty {
                        emptyState(policy: policy)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !meetings.isEmpty { meetingList(meetings, policy: policy) }
                            if !recentlyDeleted.isEmpty { recentlyDeletedSection(recentlyDeleted, policy: policy) }
                        }
                        .padding(.top, policy == .compact ? 8 : 12)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
            }
            .padding(.vertical, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $isShowingRecordingImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await coordinator.importRecording(from: url) }
            case .failure(let error):
                state.report(.recordingImport, error.localizedDescription)
            }
        }
    }

    private func libraryHeader(policy: AdaptiveLayoutPolicy) -> some View {
        HushnotePageHeader(title: libraryTitle, subtitle: librarySubtitle, policy: policy) {
            if scope != .recentlyDeleted {
                Button("Import Recording") { isShowingRecordingImporter = true }
                    .hushnoteButton(.secondary)
                    .disabled(!MeetingRecordingImportPolicy.canImport(
                        into: nil,
                        recordingIsBusy: state.recordingPhase.isBusy
                    ))
            }
        }
    }

    @ViewBuilder
    private func emptyState(policy: AdaptiveLayoutPolicy) -> some View {
        let copy = VStack(alignment: .leading, spacing: 14) {
            Text(state.searchText.isEmpty ? emptyTitle : "No matching notes")
                .font(HushnoteTheme.Font.emptyStateTitle)
            Text(state.searchText.isEmpty
                 ? emptyDescription
                 : "Try a title, speaker, decision, or phrase from the transcript.")
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .lineSpacing(3)
                .frame(maxWidth: 390, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if state.searchText.isEmpty, scope != .recentlyDeleted {
                HStack(spacing: 10) {
                    Button("Create your first note") { Task { await coordinator.createMeetingNote() } }
                        .hushnoteButton(.primary)
                        .disabled(state.recordingPhase.isBusy)
                    Button("Import Recording") { isShowingRecordingImporter = true }
                        .hushnoteButton(.secondary)
                        .disabled(state.recordingPhase.isBusy)
                }
            }
        }

        Group {
            if policy == .compact {
                VStack(alignment: .leading, spacing: 28) {
                    EmptyMeetingIllustration()
                    copy
                }
            } else {
                HStack(spacing: 44) {
                    EmptyMeetingIllustration()
                    copy
                }
            }
        }
        .padding(.vertical, policy == .compact ? 46 : 68)
        .frame(maxWidth: .infinity, alignment: policy == .compact ? .leading : .center)
    }

    private func meetingList(_ meetings: [MeetingListItem], policy: AdaptiveLayoutPolicy) -> some View {
        ForEach(meetings) { meeting in
            meetingInventoryRow(meeting, policy: policy)
            HushnoteRule(opacity: 0.62)
        }
    }

    @ViewBuilder
    private func recentlyDeletedSection(_ meetings: [MeetingListItem], policy: AdaptiveLayoutPolicy) -> some View {
        if scope == .recentlyDeleted {
            recentlyDeletedRows(meetings, policy: policy)
                .padding(.top, 8)
        } else {
            DisclosureGroup(isExpanded: $isShowingRecentlyDeleted) {
                recentlyDeletedRows(meetings, policy: policy)
                    .padding(.top, 8)
            } label: {
                Label("Recently Deleted · \(meetings.count)", systemImage: "trash")
                    .font(.callout.weight(.semibold))
            }
            .padding(.vertical, 26)
        }
    }

    private func recentlyDeletedRows(_ meetings: [MeetingListItem], policy: AdaptiveLayoutPolicy) -> some View {
        VStack(spacing: 0) {
            ForEach(meetings) { meeting in
                deletedMeetingInventoryRow(meeting, policy: policy)
                HushnoteRule(opacity: 0.62)
            }
        }
    }

    private func meetingInventoryRow(_ meeting: MeetingListItem, policy: AdaptiveLayoutPolicy) -> some View {
        HStack(alignment: .top, spacing: policy == .compact ? 12 : 20) {
            Button {
                coordinator.setSelection(.meeting(meeting.id))
            } label: {
                Group {
                    if policy == .compact {
                        compactMeetingRowContent(meeting)
                    } else {
                        HStack(alignment: .top, spacing: 22) {
                            meetingDate(meeting)
                                .frame(width: 70, alignment: .leading)
                            meetingDetails(meeting)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { meetingActions(meeting) }

            Menu {
                meetingActions(meeting)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("More actions for \(meeting.title)")
            .accessibilityLabel("More actions for \(meeting.title)")
            .fixedSize()
        }
        .padding(.vertical, policy == .compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactMeetingRowContent(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
            meetingDetails(meeting)
        }
    }

    private func meetingDate(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption.weight(.semibold))
            Text(meeting.startedAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
    }

    private func meetingDetails(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                if meeting.isRecoverable {
                    Text("RECOVER")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(HushnoteTheme.vermilionInk)
                }
            }
            Text(meeting.excerpt.isEmpty ? "No transcript yet" : meeting.excerpt)
                .lineLimit(2)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Text(meeting.template.rawValue)
                Text("·")
                Text(DurationText.clock(meeting.duration))
            }
            .font(.caption)
            .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func meetingActions(_ meeting: MeetingListItem) -> some View {
        Button("Rename…") { coordinator.promptToRenameMeeting(meetingID: meeting.id) }
        if !state.folders.isEmpty {
            Menu("Move to Folder") {
                Button("Unfiled") { Task { await coordinator.moveMeeting(meeting.id, toFolder: nil) } }
                Divider()
                ForEach(state.folders) { folder in
                    Button(folder.name) {
                        Task { await coordinator.moveMeeting(meeting.id, toFolder: folder.id) }
                    }
                    .disabled(meeting.folderID == folder.id)
                }
            }
        }
        Divider()
        Button("Move to Recently Deleted", role: .destructive) {
            Task { await coordinator.softDeleteMeeting(meeting.id) }
        }
        .disabled(state.activeMeetingID == meeting.id)
    }

    private func deletedMeetingInventoryRow(_ meeting: MeetingListItem, policy: AdaptiveLayoutPolicy) -> some View {
        Group {
            if policy == .compact {
                VStack(alignment: .leading, spacing: 13) {
                    deletedMeetingIdentity(meeting)
                    deletedMeetingActions(meeting)
                }
            } else {
                HStack(alignment: .center, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption.weight(.semibold))
                        Text(meeting.startedAt, format: .dateTime.year())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(HushnoteTheme.secondaryInk)
                    }
                    .frame(width: 70, alignment: .leading)
                    deletedMeetingIdentity(meeting)
                    Spacer(minLength: 16)
                    deletedMeetingActions(meeting)
                }
            }
        }
        .padding(.vertical, policy == .compact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deletedMeetingIdentity(_ meeting: MeetingListItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            Text("Kept for up to 30 days")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deletedMeetingActions(_ meeting: MeetingListItem) -> some View {
        HStack(spacing: 8) {
            Button("Restore") {
                Task { await coordinator.restoreMeeting(meeting.id) }
            }
            .hushnoteButton(.secondary)
            Button("Delete Permanently", role: .destructive) {
                coordinator.confirmPermanentDelete(meetingID: meeting.id)
            }
            .hushnoteButton(.quiet)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var scopedMeetings: [MeetingListItem] {
        // Search is a global command: leaving a folder selected must not hide
        // a result that happens to live elsewhere.
        if !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return state.filteredMeetings
        }

        switch scope {
        case .all:
            return state.filteredMeetings
        case .unfiled:
            return state.filteredMeetings.filter { $0.folderID == nil }
        case .folder(let id):
            return state.filteredMeetings.filter { $0.folderID == id }
        case .recentlyDeleted:
            return []
        }
    }

    private var libraryTitle: String {
        switch scope {
        case .all: "Meeting notebook"
        case .unfiled: "Unfiled meetings"
        case .folder(let id): state.folders.first(where: { $0.id == id })?.name ?? "Folder"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    private var librarySubtitle: String {
        switch scope {
        case .all: "Private recordings, accurate transcripts, useful follow-through."
        case .unfiled: "Meetings that have not been filed yet."
        case .folder: "Private recordings collected in one place."
        case .recentlyDeleted: "Restore a note within 30 days, or remove it permanently."
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .all: "Nothing recorded yet"
        case .unfiled: "No unfiled meetings"
        case .folder: "This folder is empty"
        case .recentlyDeleted: "Nothing in Recently Deleted"
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .all: "Start with your next call. Hushnote captures system audio locally, then turns the conversation into a cited working note."
        case .unfiled: "Move a meeting here from its contextual menu when you are ready to organize it."
        case .folder: "Move a meeting into this folder from its contextual menu."
        case .recentlyDeleted: "Deleted meetings stay here for up to 30 days before they are removed."
        }
    }
}
