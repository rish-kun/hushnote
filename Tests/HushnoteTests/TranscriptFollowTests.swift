import Foundation
import Testing
@testable import Hushnote

/// The live transcript had no scrolling behaviour at all -- a plain `ScrollView`
/// with no `ScrollViewReader` and no bottom anchor -- so every new line landed
/// below the fold and the user scrolled by hand for the whole meeting. Auto
/// scrolling alone is not the answer either: it fights anyone who has scrolled
/// up to read something, so following has to be a state that the user can leave
/// and come back to.
@Suite("Transcript follow")
struct TranscriptFollowTests {
    private let containerHeight = 600.0

    @Test("A transcript shorter than the window is always at the bottom")
    func shortTranscriptFollows() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 0,
                containerHeight: containerHeight,
                contentHeight: 200
            )
        )
    }

    @Test("Resting at the bottom is following")
    func bottomFollows() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 2_400,
                containerHeight: containerHeight,
                contentHeight: 3_000
            )
        )
    }

    /// A few points of slack, so a partially-scrolled line or a bounce does not
    /// read as the user taking over.
    @Test("A few points short of the bottom is still following")
    func nearBottomStillFollows() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 2_390,
                containerHeight: containerHeight,
                contentHeight: 3_000
            )
        )
    }

    /// The case auto-scroll must not fight.
    @Test("Scrolling up to read stops the follow")
    func scrollingUpStopsFollowing() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 1_200,
                containerHeight: containerHeight,
                contentHeight: 3_000
            ) == false
        )
    }

    /// Overscroll at the bottom must not be mistaken for having left.
    @Test("Bouncing past the bottom is still following")
    func overscrollStillFollows() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 2_460,
                containerHeight: containerHeight,
                contentHeight: 3_000
            )
        )
    }

    /// The bug this parameter exists for. The auto-scroll aligns the last
    /// paragraph's *bottom* with the viewport, so the reader's bottom inset --
    /// 96 points of blank paper, and the page's only "you have reached the end"
    /// signal now that there is no scroll indicator -- is still below it. An
    /// inset larger than the tolerance therefore made every auto-scroll read as
    /// the user scrolling away: following switched itself off on the first
    /// arriving segment, and "Jump to latest" stayed lit for the rest of the
    /// recording, which is the same as meaning nothing.
    @Test("Blank paper below the last paragraph is not the user scrolling away")
    func bottomInsetIsNotAScrollAway() {
        // Exactly where `scrollTo(anchor: .bottom)` leaves the viewport.
        let restingOffset = 3_000.0 - containerHeight - 96

        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: restingOffset,
                containerHeight: containerHeight,
                contentHeight: 3_000,
                bottomInset: 96
            )
        )
        // And without being told about the inset, it gets it wrong -- which is
        // what shipped.
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: restingOffset,
                containerHeight: containerHeight,
                contentHeight: 3_000
            ) == false
        )
    }

    /// The inset is slack, not a licence. Scrolling a screen up is still the
    /// user taking over.
    @Test("A reader who has actually scrolled away is not dragged back")
    func realScrollAwayStillStops() {
        #expect(
            TranscriptFollow.isFollowing(
                contentOffsetY: 3_000 - containerHeight - 96 - 400,
                containerHeight: containerHeight,
                contentHeight: 3_000,
                bottomInset: 96
            ) == false
        )
    }
}
