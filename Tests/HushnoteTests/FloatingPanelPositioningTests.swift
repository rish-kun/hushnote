import CoreGraphics
import XCTest
@testable import Hushnote

final class FloatingPanelPositioningTests: XCTestCase {
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
}
