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
        let target = visibleFrames.max { lhs, rhs in
            intersectionArea(proposedFrame, lhs) < intersectionArea(proposedFrame, rhs)
        }.flatMap { best in
            intersectionArea(proposedFrame, best) > 0 ? best : nil
        } ?? visibleFrames.min { lhs, rhs in
            squaredDistance(from: proposedFrame.center, to: lhs)
                < squaredDistance(from: proposedFrame.center, to: rhs)
        }!

        return clamp(savedOrigin, panelSize: panelSize, to: target)
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
@Observable
final class FloatingRecordingPanelController: NSObject, NSWindowDelegate {
    @ObservationIgnored private let state: AppViewState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let panel: NSPanel
    @ObservationIgnored private var isRestoringPosition = false

    private static let savedXKey = "floatingRecordingPanel.origin.x"
    private static let savedYKey = "floatingRecordingPanel.origin.y"

    init(
        state: AppViewState,
        coordinator: AppCoordinator,
        defaults: UserDefaults = .standard
    ) {
        self.state = state
        self.defaults = defaults

        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 390, height: 64)),
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
        let content = FloatingRecordingPanelContent { [weak self] in
            self?.resizeToFitContent()
        }
        .environment(state)
        .environment(coordinator)
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = [.preferredContentSize]
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
            panel.contentView?.layoutSubtreeIfNeeded()
            if let fittingSize = panel.contentView?.fittingSize,
               fittingSize.width > 0,
               fittingSize.height > 0 {
                panel.setContentSize(fittingSize)
            }
            restoreAndClampPosition()
            panel.orderFrontRegardless()
        case .idle, .failed:
            panel.orderOut(nil)
        }
    }

    private func resizeToFitContent() {
        Task { @MainActor [weak self] in
            // Let SwiftUI commit the expanded/collapsed hierarchy before
            // asking AppKit for its preferred size.
            await Task.yield()
            guard let self, let contentView = self.panel.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            let fittingSize = contentView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }

            let previousTop = self.panel.frame.maxY
            self.panel.setContentSize(fittingSize)
            let proposed = CGPoint(
                x: self.panel.frame.minX,
                y: previousTop - self.panel.frame.height
            )
            let origin = FloatingPanelPositioning.clampedOrigin(
                savedOrigin: proposed,
                panelSize: self.panel.frame.size,
                visibleFrames: NSScreen.screens.map(\.visibleFrame),
                defaultVisibleFrame: NSScreen.main?.visibleFrame
            )
            self.isRestoringPosition = true
            self.panel.setFrameOrigin(origin)
            self.isRestoringPosition = false
        }
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
        panel.setFrameOrigin(origin)
        isRestoringPosition = false
    }
}

private struct FloatingRecordingPanelContent: View {
    let onSizeChange: @MainActor () -> Void
    @Environment(AppViewState.self) private var state
    @State private var isExpanded = false

    var body: some View {
        Group {
            if FloatingRecordingPanelPolicy.showsExpandedContent(
                requested: isExpanded,
                phase: state.recordingPhase
            ) {
                ExpandedRecordingPanel {
                    isExpanded = false
                    onSizeChange()
                }
            } else {
                HStack(spacing: 6) {
                    RecordingPill()
                    if state.recordingPhase.isCapturing {
                        Button {
                            isExpanded = true
                            onSizeChange()
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
            onSizeChange()
        }
        .onChange(of: state.recordingPhase) { _, phase in
            if !phase.isCapturing { isExpanded = false }
            onSizeChange()
        }
    }
}

private struct ExpandedRecordingPanel: View {
    let collapse: @MainActor () -> Void
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var quickNote = ""
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HushnoteRule(opacity: 0.72)

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
        .frame(width: 370, alignment: .leading)
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
        let microphone = RecordingDiagnosticsPolicy.sourceRow(
            state.recordingDiagnostics.diagnostics(for: .microphone)
        )
        return HStack(spacing: 18) {
            health(system)
            health(microphone)
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
        HStack(spacing: 8) {
            Menu {
                ForEach(RecordingMarkerType.allCases) { type in
                    Button(type.title) {
                        Task { await coordinator.markMoment(type) }
                    }
                }
            } label: {
                Label("Mark", systemImage: "bookmark")
            } primaryAction: {
                Task { await coordinator.markMoment(.important) }
            }
            .hushnoteButton(.secondary)
            .accessibilityHint("Marks Important; open the menu to choose another type")

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

    private func saveQuickNote() {
        let draft = quickNote
        Task {
            guard await coordinator.saveQuickNote(draft) else { return }
            quickNote = ""
        }
    }
}
