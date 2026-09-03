import CoreGraphics
import XCTest
@testable import Hushnote

final class FloatingPanelPositioningTests: XCTestCase {
    func testPanelSizingUsesDeterministicCompactAndExpandedDimensions() {
        XCTAssertEqual(
            FloatingRecordingPanelPolicy.panelSize(isExpanded: false),
            FloatingRecordingPanelPolicy.compactPanelSize
        )
        XCTAssertEqual(
            FloatingRecordingPanelPolicy.panelSize(isExpanded: true),
            FloatingRecordingPanelPolicy.expandedPanelSize
        )
        XCTAssertGreaterThan(
            FloatingRecordingPanelPolicy.expandedPanelSize.height,
            FloatingRecordingPanelPolicy.compactPanelSize.height
        )
    }

    func testDefaultPositionIsCenteredNearTopOfPreferredScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondary = CGRect(x: 1_440, y: 100, width: 1_920, height: 1_080)

        let origin = FloatingPanelPositioning.clampedOrigin(
            savedOrigin: nil,
            panelSize: CGSize(width: 400, height: 64),
            visibleFrames: [primary, secondary],
            defaultVisibleFrame: secondary
        )

        XCTAssertEqual(origin.x, 2_200)
        XCTAssertEqual(origin.y, 1_098)
    }

    func testSavedPositionIsClampedInsideItsIntersectingScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1_440, height: 875)

        let origin = FloatingPanelPositioning.clampedOrigin(
            savedOrigin: CGPoint(x: 1_400, y: 880),
            panelSize: CGSize(width: 400, height: 64),
            visibleFrames: [screen]
        )

        XCTAssertEqual(origin, CGPoint(x: 1_040, y: 836))
    }

    func testRemovedDisplayMovesPanelToNearestRemainingScreen() {
        let left = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let origin = FloatingPanelPositioning.clampedOrigin(
            savedOrigin: CGPoint(x: 2_200, y: 400),
            panelSize: CGSize(width: 400, height: 64),
            visibleFrames: [left, right]
        )

        XCTAssertEqual(origin, CGPoint(x: 1_040, y: 400))
    }

    func testLargestIntersectionSelectsTargetDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)

        let origin = FloatingPanelPositioning.clampedOrigin(
            savedOrigin: CGPoint(x: 850, y: 300),
            panelSize: CGSize(width: 400, height: 64),
            visibleFrames: [left, right]
        )

        XCTAssertEqual(origin, CGPoint(x: 1_000, y: 300))
    }

    func testResizePreservesTopEdgeWhenThereIsRoomOnDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let currentFrame = CGRect(x: 520, y: 700, width: 390, height: 64)
        let newSize = FloatingRecordingPanelPolicy.expandedPanelSize

        let origin = FloatingPanelPositioning.originPreservingTopEdge(
            currentFrame: currentFrame,
            newSize: newSize,
            visibleFrames: [screen]
        )

        XCTAssertEqual(
            origin,
            CGPoint(x: 520, y: currentFrame.maxY - newSize.height)
        )
        XCTAssertEqual(origin.y + newSize.height, currentFrame.maxY)
    }

    func testResizeClampsToDisplayWhenExpandedPanelWouldCrossTopEdge() {
        let screen = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let currentFrame = CGRect(x: 1_200, y: 40, width: 390, height: 64)
        let newSize = FloatingRecordingPanelPolicy.expandedPanelSize

        let origin = FloatingPanelPositioning.originPreservingTopEdge(
            currentFrame: currentFrame,
            newSize: newSize,
            visibleFrames: [screen]
        )

        XCTAssertEqual(origin, CGPoint(x: 1_054, y: 25))
        XCTAssertGreaterThanOrEqual(CGRect(origin: origin, size: newSize).minY, screen.minY)
    }

    func testAtomicResizeUsesCurrentExpandedDimensionsAndPreservesTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let current = CGRect(
            x: 520,
            y: 700,
            width: FloatingRecordingPanelPolicy.compactPanelSize.width,
            height: FloatingRecordingPanelPolicy.compactPanelSize.height
        )

        let frame = FloatingPanelPositioning.resizedFrame(
            currentFrame: current,
            requestedSize: FloatingRecordingPanelPolicy.expandedPanelSize,
            compactSize: FloatingRecordingPanelPolicy.compactPanelSize,
            visibleFrames: [screen]
        )

        XCTAssertEqual(frame.size, FloatingRecordingPanelPolicy.expandedPanelSize)
        XCTAssertEqual(frame.maxY, current.maxY)
        XCTAssertEqual(frame.minX, current.minX)
    }

    func testResizeFallsBackToAccessibleCompactPanelWhenDisplayCannotFitExpandedPanel() {
        let smallScreen = CGRect(x: 0, y: 0, width: 500, height: 300)
        let current = CGRect(
            x: 20,
            y: 220,
            width: FloatingRecordingPanelPolicy.compactPanelSize.width,
            height: FloatingRecordingPanelPolicy.compactPanelSize.height
        )

        let frame = FloatingPanelPositioning.resizedFrame(
            currentFrame: current,
            requestedSize: FloatingRecordingPanelPolicy.expandedPanelSize,
            compactSize: FloatingRecordingPanelPolicy.compactPanelSize,
            visibleFrames: [smallScreen]
        )

        XCTAssertEqual(frame.size, FloatingRecordingPanelPolicy.compactPanelSize)
        XCTAssertTrue(smallScreen.contains(frame))
        XCTAssertEqual(frame.maxY, current.maxY)
        XCTAssertFalse(FloatingPanelPositioning.canShowExpandedPanel(
            frame: current,
            expandedSize: FloatingRecordingPanelPolicy.expandedPanelSize,
            visibleFrames: [smallScreen]
        ))
    }

    func testResizeChoosesTheScreenContainingTheCurrentPanelBeforeClamping() {
        let left = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let current = CGRect(x: -900, y: 650, width: 390, height: 64)

        let frame = FloatingPanelPositioning.resizedFrame(
            currentFrame: current,
            requestedSize: FloatingRecordingPanelPolicy.expandedPanelSize,
            compactSize: FloatingRecordingPanelPolicy.compactPanelSize,
            visibleFrames: [left, right]
        )

        XCTAssertTrue(left.contains(frame))
        XCTAssertEqual(frame.maxY, current.maxY)
    }

    func testNoScreensPreservesSavedOriginAndFallsBackToZero() {
        let saved = CGPoint(x: 120, y: 240)
        XCTAssertEqual(
            FloatingPanelPositioning.clampedOrigin(
                savedOrigin: saved,
                panelSize: CGSize(width: 400, height: 64),
                visibleFrames: []
            ),
            saved
        )
        XCTAssertEqual(
            FloatingPanelPositioning.clampedOrigin(
                savedOrigin: nil,
                panelSize: CGSize(width: 400, height: 64),
                visibleFrames: []
            ),
            .zero
        )
    }

    func testExpandedContentOnlyAppearsDuringCapture() {
        XCTAssertTrue(FloatingRecordingPanelPolicy.showsExpandedContent(
            requested: true,
            phase: .recording
        ))
        XCTAssertTrue(FloatingRecordingPanelPolicy.showsExpandedContent(
            requested: true,
            phase: .paused
        ))
        XCTAssertFalse(FloatingRecordingPanelPolicy.showsExpandedContent(
            requested: true,
            phase: .finalizing(0.4)
        ))
        XCTAssertFalse(FloatingRecordingPanelPolicy.showsExpandedContent(
            requested: false,
            phase: .recording
        ))
    }

    func testQuickNoteTrimsAndAppendsWithoutRewritingExistingNotes() {
        XCTAssertNil(FloatingRecordingPanelPolicy.appendingQuickNote("   ", to: "Existing"))
        XCTAssertEqual(
            FloatingRecordingPanelPolicy.appendingQuickNote("  Follow up  ", to: "Existing"),
            "Existing\nFollow up"
        )
        XCTAssertEqual(
            FloatingRecordingPanelPolicy.appendingQuickNote("Decision", to: "Existing\n"),
            "Existing\nDecision"
        )
        XCTAssertEqual(
            FloatingRecordingPanelPolicy.appendingQuickNote("First", to: ""),
            "First"
        )
    }

    func testMicrophoneControlShowsStableOnAndOffStates() {
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.state(
                enabled: true,
                lifecycle: .healthy,
                pendingRequest: nil
            ),
            .on
        )
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.state(
                enabled: false,
                lifecycle: .disabled,
                pendingRequest: nil
            ),
            .off
        )
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.State.on.statusText,
            "On"
        )
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.State.off.statusText,
            "Off"
        )
    }

    func testMicrophoneControlRepresentsRequestsAndKeepsUnavailableActionable() {
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.state(
                enabled: true,
                lifecycle: .arming,
                pendingRequest: true
            ),
            .turningOn
        )
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.state(
                enabled: false,
                lifecycle: .disabled,
                pendingRequest: false
            ),
            .turningOff
        )

        let unavailable = FloatingMicrophoneControlPolicy.state(
            enabled: true,
            lifecycle: .unavailable,
            pendingRequest: nil
        )
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertTrue(unavailable.isActionEnabled)
        XCTAssertEqual(unavailable.actionTitle, "Try again")
    }

    func testMicrophoneControlRefusesDuplicateRequestsUntilTheFirstCompletes() {
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.requestedValue(
                enabled: false,
                lifecycle: .disabled,
                pendingRequest: nil
            ),
            true
        )
        XCTAssertNil(
            FloatingMicrophoneControlPolicy.requestedValue(
                enabled: false,
                lifecycle: .arming,
                pendingRequest: true
            )
        )
        XCTAssertNil(
            FloatingMicrophoneControlPolicy.requestedValue(
                enabled: true,
                lifecycle: .disabled,
                pendingRequest: false
            )
        )
    }

    func testUnavailableMicrophoneRetryPreservesTheEnableIntent() {
        XCTAssertTrue(
            FloatingMicrophoneControlPolicy.retriesUnavailableSource(.unavailable)
        )
        XCTAssertFalse(
            FloatingMicrophoneControlPolicy.retriesUnavailableSource(.healthy)
        )
        XCTAssertEqual(
            FloatingMicrophoneControlPolicy.requestedValue(
                enabled: true,
                lifecycle: .unavailable,
                pendingRequest: nil
            ),
            true
        )
    }

    func testStaleMicrophoneRequestsCannotReachThePipeline() {
        XCTAssertFalse(
            FloatingMicrophoneControlPolicy.requestIsCurrent(
                requestedEnabled: true,
                requestedMicrophone: nil,
                currentEnabled: false,
                currentMicrophone: nil
            )
        )
        XCTAssertFalse(
            FloatingMicrophoneControlPolicy.requestIsCurrent(
                requestedEnabled: true,
                requestedMicrophone: PreferredMicrophone(uid: "built-in"),
                currentEnabled: true,
                currentMicrophone: PreferredMicrophone(uid: "headset")
            )
        )
        XCTAssertTrue(
            FloatingMicrophoneControlPolicy.requestIsCurrent(
                requestedEnabled: false,
                requestedMicrophone: nil,
                currentEnabled: false,
                currentMicrophone: nil
            )
        )
    }

    func testSnapshotPolicyUsesStableProgressCopyAndDisablesDuplicateCapture() {
        XCTAssertEqual(FloatingSnapshotPolicy.State.idle.buttonTitle, "Snapshot")
        XCTAssertTrue(FloatingSnapshotPolicy.canStart(.idle))

        XCTAssertEqual(FloatingSnapshotPolicy.State.saving.buttonTitle, "Saving…")
        XCTAssertFalse(FloatingSnapshotPolicy.canStart(.saving))

        XCTAssertEqual(FloatingSnapshotPolicy.State.saved.buttonTitle, "Saved")
        XCTAssertFalse(FloatingSnapshotPolicy.canStart(.saved))
        XCTAssertEqual(
            FloatingSnapshotPolicy.State.saved.accessibilityLabel,
            "Screenshot saved to this meeting"
        )
    }

    func testSnapshotPolicyAllowsRetryAfterFailureAndKeepsErrorForHelp() {
        let failed = FloatingSnapshotPolicy.State.failed("Screen Recording permission is required.")

        XCTAssertTrue(FloatingSnapshotPolicy.canStart(failed))
        XCTAssertEqual(failed.buttonTitle, "Try again")
        XCTAssertEqual(failed.helpText, "Screen Recording permission is required.")
        XCTAssertEqual(failed.accessibilityLabel, "Retry screenshot")
    }
}
