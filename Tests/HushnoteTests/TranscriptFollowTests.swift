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
}
