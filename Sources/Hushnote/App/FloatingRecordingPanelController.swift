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

        let content = FloatingRecordingPanelContent()
            .environment(state)
            .environment(coordinator)
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = [.preferredContentSize]

        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 390, height: 64)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
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
    var body: some View {
        RecordingPill()
            .fixedSize()
            .padding(8)
    }
}
