import AppKit
import Observation
import SwiftUI

/// Geometry used to restore the recording controller after a display is removed
/// or its visible frame changes. Kept independent of `NSScreen` for deterministic
/// unit tests.
struct FloatingPanelPositioning {
    static func clampedOrigin(
        savedOrigin: CGPoint?,
        panelSize: CGSize,
        visibleFrames: [CGRect],
        defaultVisibleFrame: CGRect? = nil
    ) -> CGPoint {
        guard !visibleFrames.isEmpty else { return savedOrigin ?? .zero }

        guard let savedOrigin else {
            let frame = defaultVisibleFrame ?? visibleFrames[0]
            return clamp(
                CGPoint(
                    x: frame.midX - panelSize.width / 2,
                    y: frame.maxY - panelSize.height - 18
                ),
                panelSize: panelSize,
                to: frame
            )
        }

        let proposedFrame = CGRect(origin: savedOrigin, size: panelSize)
        let target = targetVisibleFrame(
            for: proposedFrame,
            visibleFrames: visibleFrames,
            defaultVisibleFrame: defaultVisibleFrame
        )!

        return clamp(savedOrigin, panelSize: panelSize, to: target)
    }

    /// Returns an origin for a resize that keeps the panel's top edge fixed,
    /// then keeps the resized frame inside the display it belongs to.
    static func originPreservingTopEdge(
        currentFrame: CGRect,
        newSize: CGSize,
        visibleFrames: [CGRect],
        defaultVisibleFrame: CGRect? = nil
    ) -> CGPoint {
        clampedOrigin(
            savedOrigin: CGPoint(
                x: currentFrame.minX,
                y: currentFrame.maxY - newSize.height
            ),
            panelSize: newSize,
            visibleFrames: visibleFrames,
            defaultVisibleFrame: defaultVisibleFrame
        )
    }

    /// Resolves an entire resize in one place so the caller can apply one
    /// AppKit frame change. A panel must never grow beyond the visible frame
    /// that currently contains it: if there is insufficient room for the
    /// expanded recording workspace, retain the compact control instead.
    static func resizedFrame(
        currentFrame: CGRect,
        requestedSize: CGSize,
        compactSize: CGSize,
        visibleFrames: [CGRect],
        defaultVisibleFrame: CGRect? = nil
    ) -> CGRect {
        guard let target = targetVisibleFrame(
            for: currentFrame,
            visibleFrames: visibleFrames,
            defaultVisibleFrame: defaultVisibleFrame
        ) else {
            return CGRect(
                origin: CGPoint(
                    x: currentFrame.minX,
                    y: currentFrame.maxY - requestedSize.height
                ),
                size: requestedSize
            )
        }

        let requestedFits = requestedSize.width <= target.width
            && requestedSize.height <= target.height
        let preferredSize = requestedFits ? requestedSize : compactSize
        // A display can itself be smaller than the compact pill (for example
        // a remote-desktop surface). Keep as much of the persistent control
        // reachable as the display permits rather than placing an edge off
        // screen.
        let fittedSize = CGSize(
            width: min(preferredSize.width, target.width),
            height: min(preferredSize.height, target.height)
        )
        let origin = clamp(
            CGPoint(
                x: currentFrame.minX,
                y: currentFrame.maxY - fittedSize.height
            ),
            panelSize: fittedSize,
            to: target
        )
        return CGRect(origin: origin, size: fittedSize)
    }

    static func canShowExpandedPanel(
        frame: CGRect,
        expandedSize: CGSize,
        visibleFrames: [CGRect],
        defaultVisibleFrame: CGRect? = nil
    ) -> Bool {
        guard let target = targetVisibleFrame(
            for: frame,
            visibleFrames: visibleFrames,
            defaultVisibleFrame: defaultVisibleFrame
        ) else {
            return true
        }
        return expandedSize.width <= target.width && expandedSize.height <= target.height
    }

    private static func targetVisibleFrame(
        for proposedFrame: CGRect,
        visibleFrames: [CGRect],
        defaultVisibleFrame: CGRect?
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        return visibleFrames.max { lhs, rhs in
            intersectionArea(proposedFrame, lhs) < intersectionArea(proposedFrame, rhs)
        }.flatMap { best in
            intersectionArea(proposedFrame, best) > 0 ? best : nil
        } ?? visibleFrames.min { lhs, rhs in
            squaredDistance(from: proposedFrame.center, to: lhs)
                < squaredDistance(from: proposedFrame.center, to: rhs)
        } ?? defaultVisibleFrame
    }

    private static func clamp(_ origin: CGPoint, panelSize: CGSize, to frame: CGRect) -> CGPoint {
        let maximumX = max(frame.minX, frame.maxX - panelSize.width)
        let maximumY = max(frame.minY, frame.maxY - panelSize.height)
        return CGPoint(
            x: min(max(origin.x, frame.minX), maximumX),
            y: min(max(origin.y, frame.minY), maximumY)
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - nearestX
        let dy = point.y - nearestY
        return dx * dx + dy * dy
    }
}

enum FloatingRecordingPanelPolicy {
    /// The controller owns these dimensions instead of asking SwiftUI for a
    /// transient fitting size while its hierarchy is changing.
    static let compactPanelSize = CGSize(width: 390, height: 64)
    // ExpandedRecordingPanel has a 370x352 frame and the content container
    // contributes 8pt of padding on every edge.
    static let expandedPanelSize = CGSize(width: 386, height: 368)
    static let expandedContentSize = CGSize(width: 370, height: 352)

    nonisolated static func panelSize(isExpanded: Bool) -> CGSize {
        isExpanded ? expandedPanelSize : compactPanelSize
    }

    nonisolated static func showsExpandedContent(
        requested: Bool,
        phase: RecordingPhase
    ) -> Bool {
        requested && phase.isCapturing
    }

    nonisolated static func appendingQuickNote(
        _ draft: String,
        to existing: String
    ) -> String? {
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        guard !existing.isEmpty else { return note }
        return existing.hasSuffix("\n") ? existing + note : existing + "\n" + note
    }
}

/// The panel-facing boundary for a visual snapshot. The capture service owns
/// screen selection, permissions, and durable attachment storage; the pill
/// only needs to await completion so it can give deterministic feedback.
typealias FloatingRecordingPanelSnapshotAction = @MainActor () async throws -> Void

enum FloatingRecordingPanelSnapshotError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Snapshot capture is unavailable right now."
        }
    }
}

enum FloatingSnapshotPolicy {
    enum State: Equatable, Sendable {
        case idle
        case saving
        case saved
        case failed(String)

        var buttonTitle: String {
            switch self {
            case .idle: "Snapshot"
            case .saving: "Saving…"
            case .saved: "Saved"
            case .failed: "Try again"
            }
        }

        var isActionEnabled: Bool {
            switch self {
            case .idle, .failed: true
            case .saving, .saved: false
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: "Take a screenshot of the display under the pointer"
            case .saving: "Saving screenshot"
            case .saved: "Screenshot saved to this meeting"
            case .failed: "Retry screenshot"
            }
        }

        var helpText: String {
            switch self {
            case .idle: "Save a screenshot of the display under the pointer to this meeting"
            case .saving: "Saving screenshot to this meeting"
            case .saved: "Screenshot saved to this meeting"
            case .failed(let message): message
            }
        }
    }

    nonisolated static func canStart(_ state: State) -> Bool {
        state.isActionEnabled
    }
}

/// Presentation and interaction rules for the microphone control in the
/// expanded recording panel. The panel keeps a request pending until the
/// coordinator's serialized configuration task finishes; diagnostics then
/// distinguish a healthy source from a source-specific setup failure.
enum FloatingMicrophoneControlPolicy {
    enum State: Equatable, Sendable {
        case on
        case off
        case turningOn
        case turningOff
        case unavailable

        var statusText: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .turningOn: "Turning on…"
            case .turningOff: "Turning off…"
            case .unavailable: "Unavailable"
            }
        }

        var actionTitle: String {
            switch self {
            case .on: "Turn off"
            case .off: "Turn on"
            case .turningOn: "Turning on…"
            case .turningOff: "Turning off…"
            case .unavailable: "Try again"
            }
        }

        var isActionEnabled: Bool {
            switch self {
            case .turningOn, .turningOff: false
            case .on, .off, .unavailable: true
            }
        }
    }

    nonisolated static func state(
        enabled: Bool,
        lifecycle: RecordingSourceLifecycle,
        pendingRequest: Bool?
    ) -> State {
        if pendingRequest == true { return .turningOn }
        if pendingRequest == false { return .turningOff }
        if lifecycle == .unavailable { return .unavailable }
        if lifecycle == .arming { return enabled ? .turningOn : .turningOff }
        return enabled ? .on : .off
    }

    /// Returns the next desired value, or nil while an earlier request is
    /// still in flight. This is the pure gate that keeps rapid clicks from
    /// building a second toggle atop a queued coordinator request.
    nonisolated static func requestedValue(
        enabled: Bool,
        lifecycle: RecordingSourceLifecycle,
        pendingRequest: Bool?
    ) -> Bool? {
        guard pendingRequest == nil else { return nil }
        // An unavailable source means the desired preference is still on but
        // setup failed. Retry that intent; do not interpret the retry as a
        // request to disable the microphone.
        if retriesUnavailableSource(lifecycle) { return true }
        return !enabled
    }

    nonisolated static func retriesUnavailableSource(
        _ lifecycle: RecordingSourceLifecycle
    ) -> Bool {
        lifecycle == .unavailable
    }

    /// A queued request is allowed to reach the capture pipeline only while
    /// it still describes the user's latest intent. This prevents an older
    /// suspended request (for example, "on") from being applied after a
    /// newer request ("off") has already updated the desired state.
    nonisolated static func requestIsCurrent(
        requestedEnabled: Bool,
        requestedMicrophone: PreferredMicrophone?,
        currentEnabled: Bool,
        currentMicrophone: PreferredMicrophone?
    ) -> Bool {
        requestedEnabled == currentEnabled
            && requestedMicrophone == currentMicrophone
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
@Observable
final class FloatingRecordingPanelController: NSObject, NSWindowDelegate {
    @ObservationIgnored private let state: AppViewState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let snapshotAction: FloatingRecordingPanelSnapshotAction
    @ObservationIgnored private let panel: NSPanel
    @ObservationIgnored private var hostingView: NSView?
    @ObservationIgnored private var isRestoringPosition = false

    private static let savedXKey = "floatingRecordingPanel.origin.x"
    private static let savedYKey = "floatingRecordingPanel.origin.y"

    init(
        state: AppViewState,
        coordinator: AppCoordinator,
        defaults: UserDefaults = .standard,
        snapshotAction: @escaping FloatingRecordingPanelSnapshotAction = {
            throw FloatingRecordingPanelSnapshotError.unavailable
        }
    ) {
        self.state = state
        self.defaults = defaults
        self.snapshotAction = snapshotAction

        panel = NSPanel(
            contentRect: CGRect(
                origin: .zero,
                size: FloatingRecordingPanelPolicy.compactPanelSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        super.init()
        let content = FloatingRecordingPanelContent { [weak self] isExpanded in
            self?.applyPanelSize(isExpanded: isExpanded) ?? false
        } onSnapshot: { [snapshotAction] in
            try await snapshotAction()
        }
        .environment(state)
        .environment(coordinator)
        let hostingView = NSHostingView(rootView: content)
        // The controller owns the panel frame. Letting AppKit infer it from
        // SwiftUI's preferred size reintroduces the expansion measurement
        // race this controller is responsible for avoiding.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(
            origin: .zero,
            size: FloatingRecordingPanelPolicy.compactPanelSize
        )
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView
        panel.contentView = hostingView
        panel.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observePhase()
        syncVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange() {
        restoreAndClampPosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoringPosition else { return }
        defaults.set(panel.frame.origin.x, forKey: Self.savedXKey)
        defaults.set(panel.frame.origin.y, forKey: Self.savedYKey)
    }

    private func observePhase() {
        withObservationTracking {
            _ = state.recordingPhase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observePhase()
            }
        }
    }

    private func syncVisibility() {
        switch state.recordingPhase {
        case .preparing, .recording, .paused, .finalizing:
            restoreAndClampPosition()
            panel.orderFrontRegardless()
        case .idle, .failed:
            panel.orderOut(nil)
        }
    }

    /// Applies one final panel rectangle. Resizing the content and moving the
    /// panel separately can expose the expanded SwiftUI tree inside the old,
    /// compact frame for a run-loop turn.
    @discardableResult
    private func applyPanelSize(isExpanded: Bool) -> Bool {
        let requestedSize = FloatingRecordingPanelPolicy.panelSize(isExpanded: isExpanded)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let targetFrame = FloatingPanelPositioning.resizedFrame(
            currentFrame: panel.frame,
            requestedSize: requestedSize,
            compactSize: FloatingRecordingPanelPolicy.compactPanelSize,
            visibleFrames: visibleFrames,
            defaultVisibleFrame: NSScreen.main?.visibleFrame
        )
        let expansionFits = !isExpanded || targetFrame.size == requestedSize

        guard panel.frame != targetFrame else { return expansionFits }
        isRestoringPosition = true
        defer { isRestoringPosition = false }
        panel.setFrame(targetFrame, display: true, animate: false)
        // `NSHostingView` deliberately has no intrinsic-size policy. Its
        // autoresizing mask is the contract that makes it fill this native
        // frame through the next SwiftUI layout pass.
        hostingView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        return expansionFits
    }

    private func restoreAndClampPosition() {
        let hasSavedOrigin = defaults.object(forKey: Self.savedXKey) != nil
            && defaults.object(forKey: Self.savedYKey) != nil
        let savedOrigin = hasSavedOrigin
            ? CGPoint(
                x: defaults.double(forKey: Self.savedXKey),
                y: defaults.double(forKey: Self.savedYKey)
            )
            : nil
        let screens = NSScreen.screens.map(\.visibleFrame)
        let origin = FloatingPanelPositioning.clampedOrigin(
            savedOrigin: savedOrigin,
            panelSize: panel.frame.size,
            visibleFrames: screens,
            defaultVisibleFrame: NSScreen.main?.visibleFrame
        )

        isRestoringPosition = true
        defer { isRestoringPosition = false }
        panel.setFrame(
            CGRect(origin: origin, size: panel.frame.size),
            display: true,
            animate: false
        )
    }
}

private struct FloatingRecordingPanelContent: View {
    /// Returns false only when the current visible display cannot contain the
    /// expanded panel. The view then returns to the compact control, where
    /// its expand affordance is always reachable.
    let onSizeChange: @MainActor (Bool) -> Bool
    let onSnapshot: @MainActor () async throws -> Void
    @Environment(AppViewState.self) private var state
    @State private var isExpanded = false

    var body: some View {
        Group {
            if FloatingRecordingPanelPolicy.showsExpandedContent(
                requested: isExpanded,
                phase: state.recordingPhase
            ) {
                ExpandedRecordingPanel(
                    collapse: {
                        isExpanded = false
                    },
                    onSnapshot: onSnapshot
                )
            } else {
                HStack(spacing: 6) {
                    RecordingPill()
                    if state.recordingPhase.isCapturing {
                        Button {
                            isExpanded = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 28, height: 28)
                                .background(HushnoteTheme.controlSurface, in: Circle())
                                .overlay {
                                    Circle().stroke(HushnoteTheme.rule.opacity(0.72), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Show recording details")
                        .accessibilityLabel("Expand recording panel")
                    }
                }
                .fixedSize()
            }
        }
        .padding(8)
        .onExitCommand {
            guard isExpanded else { return }
            isExpanded = false
        }
        .onAppear(perform: schedulePanelResize)
        .onChange(of: isExpanded) { _, _ in
            schedulePanelResize()
        }
        .onChange(of: state.recordingPhase) { _, phase in
            if !phase.isCapturing { isExpanded = false }
            schedulePanelResize()
        }
    }

    private func schedulePanelResize() {
        // State mutation and body recomposition happen after a button action
        // returns. Yielding once lets the root switch branches before native
        // geometry changes; this is the boundary that prevents the expanded
        // tree being clipped by the old compact panel frame.
        Task { @MainActor in
            await Task.yield()
            let shouldExpand = FloatingRecordingPanelPolicy.showsExpandedContent(
                requested: isExpanded,
                phase: state.recordingPhase
            )
            guard onSizeChange(shouldExpand) || !shouldExpand else {
                isExpanded = false
                return
            }
        }
    }
}

private struct ExpandedRecordingPanel: View {
    let collapse: @MainActor () -> Void
    let onSnapshot: @MainActor () async throws -> Void
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var quickNote = ""
    @State private var microphoneRequest: Bool?
    @State private var snapshotState = FloatingSnapshotPolicy.State.idle
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            HushnoteRule(opacity: 0.72)

            // Keep the collapse control outside the scrollable body. Should
            // copy grow (or a display force a smaller content rect), the user
            // can always get back to the compact recording pill.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        SystemLevelMeter()
                        MicrophoneLevelMeter()
                    }

                    sourceHealth
                    confidence
                    controls
                    quickNoteField
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .frame(
            width: FloatingRecordingPanelPolicy.expandedContentSize.width,
            height: FloatingRecordingPanelPolicy.expandedContentSize.height,
            alignment: .topLeading
        )
        .background(HushnoteTheme.controlSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(HushnoteTheme.rule.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.13), radius: 14, y: 5)
    }

    private var header: some View {
        HStack(spacing: 9) {
            RecordingPulse(isActive: state.recordingPhase == .recording)
            Text(RecordingStatusText.label(for: state.recordingPhase))
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    state.recordingPhase == .paused
                        ? HushnoteTheme.secondaryInk
                        : HushnoteTheme.vermilionInk
                )
            Spacer()
            RecordingDurationComparison()
            Button(action: collapse) {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Collapse recording panel")
            .accessibilityLabel("Collapse recording panel")
        }
    }

    private var sourceHealth: some View {
        let system = RecordingDiagnosticsPolicy.sourceRow(
            state.recordingDiagnostics.diagnostics(for: .system)
        )
        return VStack(alignment: .leading, spacing: 6) {
            health(system)
            microphoneControl
        }
    }

    private var microphoneControl: some View {
        let diagnostics = state.recordingDiagnostics.diagnostics(for: .microphone)
        let row = RecordingDiagnosticsPolicy.sourceRow(diagnostics)
        let control = FloatingMicrophoneControlPolicy.state(
            enabled: state.microphoneCaptureEnabled,
            lifecycle: diagnostics.lifecycle,
            pendingRequest: microphoneRequest
        )

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.title) · \(row.status)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(diagnosticForeground(row.tone))
                    .lineLimit(1)
                if control == .unavailable {
                    Text("Check permission or choose another input in Settings.")
                        .font(.caption2)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(control.actionTitle) {
                requestMicrophoneChange()
            }
            .hushnoteButton(.secondary)
            .disabled(!control.isActionEnabled)
            .accessibilityLabel(
                control == .unavailable
                    ? "Try microphone again"
                    : control.actionTitle + " microphone"
            )
            .accessibilityHint(
                control == .unavailable
                    ? "Retries microphone capture after checking permission or input settings."
                    : "Changes microphone capture for this meeting."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: state.recordingPhase) { _, phase in
            if !phase.isCapturing { microphoneRequest = nil }
        }
    }

    private var confidence: some View {
        let line = RecordingConfidencePolicy.line(for: state.recordingDiagnostics)
        return HushnoteStatusLine(
            text: line.text,
            tone: statusTone(line.tone)
        )
        .lineLimit(2)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlsRow(compact: false)
            controlsRow(compact: true)
        }
    }

    private func controlsRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(RecordingMarkerType.allCases) { type in
                    Button(type.title) {
                        Task { await coordinator.markMoment(type) }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: "bookmark")
                } else {
                    Label("Mark", systemImage: "bookmark")
                }
            } primaryAction: {
                Task { await coordinator.markMoment(.important) }
            }
            .hushnoteButton(.secondary)
            .accessibilityLabel("Mark moment")
            .accessibilityHint("Marks Important; open the menu to choose another type")

            Button {
                requestSnapshot()
            } label: {
                if compact {
                    Image(systemName: snapshotIcon)
                } else {
                    Label(snapshotState.buttonTitle, systemImage: snapshotIcon)
                }
            }
            .hushnoteButton(.quiet)
            .disabled(!FloatingSnapshotPolicy.canStart(snapshotState))
            .help(snapshotState.helpText)
            .accessibilityLabel(snapshotState.accessibilityLabel)
            .accessibilityHint("Captures the display under the pointer without interrupting recording")

            Spacer(minLength: 8)

            Button(state.recordingPhase == .paused ? "Resume" : "Pause") {
                Task { await coordinator.togglePause() }
            }
            .hushnoteButton(.secondary)

            Button("Stop") {
                Task { await coordinator.stopMeeting() }
            }
            .hushnoteButton(.recording)
        }
    }

    private var quickNoteField: some View {
        TextField("Quick note — press Return to save", text: $quickNote)
            .textFieldStyle(HushnoteFieldStyle())
            .focused($noteIsFocused)
            .hushnoteFocusRing(noteIsFocused)
            .onSubmit(saveQuickNote)
            .accessibilityHint("Adds this line to the active meeting notes")
    }

    private func health(_ row: RecordingDiagnosticRow) -> some View {
        HushnoteStatusLine(
            text: "\(row.title) · \(row.status)",
            tone: statusTone(row.tone)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusTone(_ tone: RecordingDiagnosticTone) -> HushnoteStatusTone {
        switch tone {
        case .neutral: .neutral
        case .working: .working
        case .good: .good
        case .attention, .warning: .warning
        }
    }

    private func diagnosticForeground(_ tone: RecordingDiagnosticTone) -> Color {
        switch tone {
        case .good: HushnoteTheme.moss
        case .warning, .attention: HushnoteTheme.vermilionInk
        case .working: HushnoteTheme.ink
        case .neutral: HushnoteTheme.secondaryInk
        }
    }

    private func saveQuickNote() {
        let draft = quickNote
        Task {
            guard await coordinator.saveQuickNote(draft) else { return }
            quickNote = ""
        }
    }

    private func requestMicrophoneChange() {
        let lifecycle = state.recordingDiagnostics.diagnostics(for: .microphone).lifecycle
        let requested = FloatingMicrophoneControlPolicy.requestedValue(
            enabled: state.microphoneCaptureEnabled,
            lifecycle: lifecycle,
            pendingRequest: microphoneRequest
        )
        guard let requested else { return }

        microphoneRequest = requested
        Task { @MainActor in
            let configuration = FloatingMicrophoneControlPolicy.retriesUnavailableSource(lifecycle)
                ? coordinator.retryMicrophoneCapture()
                : coordinator.setMicrophoneCaptureEnabled(requested)
            await configuration?.value
            guard !Task.isCancelled else { return }
            microphoneRequest = nil
        }
    }

    private func requestSnapshot() {
        guard FloatingSnapshotPolicy.canStart(snapshotState) else { return }
        snapshotState = .saving
        Task { @MainActor in
            do {
                try await onSnapshot()
                guard !Task.isCancelled else { return }
                snapshotState = .saved
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled, case .saved = snapshotState {
                    snapshotState = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                snapshotState = .failed(error.localizedDescription)
            }
        }
    }

    private var snapshotIcon: String {
        switch snapshotState {
        case .idle, .failed: "camera.viewfinder"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark"
        }
    }
}
