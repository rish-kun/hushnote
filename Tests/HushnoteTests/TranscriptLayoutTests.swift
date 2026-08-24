import Foundation
import Testing
@testable import Hushnote

/// The reading column used to be pinned to the left of a canvas built for two
/// columns, leaving roughly 900 points of nothing beside every paragraph. These
/// are the widths at which the apparatus margin and the index appear.
@Suite("Transcript layout")
struct TranscriptLayoutTests {
    @Test("Compact fills the window rather than leaving a ragged edge")
    func compact() {
        let layout = TranscriptLayout.resolve(availableWidth: 700)
        #expect(layout.gutter == 24)
        #expect(layout.hasMargin == false)
        #expect(layout.showsIndexRail == false)
        #expect(layout.measure == .infinity)
    }

    /// The margin needs its own width plus the gap plus the full measure. At
    /// the regular gutter that is 32 + 64 + 24 + 704 + 32 = 856.
    @Test("The apparatus margin appears partway through the regular tier")
    func marginThreshold() {
        #expect(TranscriptLayout.resolve(availableWidth: 855).hasMargin == false)
        #expect(TranscriptLayout.resolve(availableWidth: 856).hasMargin)
    }

    /// A tier boundary is not a layout boundary. Between 1100 and 1180 the pane
    /// is wide, and still has nowhere to put an index. The threshold is
    /// 56 + 64 + 24 + 704 + 44 + 232 + 56.
    @Test("The wide tier does not by itself earn an index")
    func railThreshold() {
        let justWide = TranscriptLayout.resolve(availableWidth: 1_100)
        #expect(justWide.hasMargin)
        #expect(justWide.showsIndexRail == false)

        #expect(TranscriptLayout.resolve(availableWidth: 1_179).showsIndexRail == false)
        #expect(TranscriptLayout.resolve(availableWidth: 1_180).showsIndexRail)
    }

    /// Whatever the tier, the column and its gutters have to fit inside the
    /// container -- otherwise the rail would be pushed off the trailing edge.
    @Test("The resolved spread always fits its container")
    func spreadFits() {
        for width in stride(from: CGFloat(400), through: 2_400, by: 17) {
            let layout = TranscriptLayout.resolve(availableWidth: width)
            guard layout.measure.isFinite else { continue }

            var required = 2 * layout.gutter + layout.columnWidth
            if layout.showsIndexRail {
                required += layout.railGap + layout.railWidth
            }
            #expect(required <= width, "spread overflows at \(width)")
        }
    }

    /// The hole this closes: the reader used to expand to the full pane while
    /// the index was pinned to the trailing edge, so at a 1650-point pane a
    /// 792-point column sat at the left, a 232-point index at the right, and
    /// roughly 470 points of nothing lay between a paragraph and the entry
    /// that indexes it. Capping the reader moves the surplus outside the
    /// spread, where it reads as page margin.
    @Test("The index sits beside the prose, not at the window edge")
    func readerIsCappedBesideTheIndex() {
        let layout = TranscriptLayout.resolve(availableWidth: 1_650)
        let reader = try! #require(layout.readerWidth)

        #expect(layout.showsIndexRail)
        #expect(reader == layout.gutter + layout.columnWidth + layout.railGap)
        // The gap between the last word and the first index entry is the gap
        // the spread declares -- not whatever the window happens to be.
        #expect(reader + layout.railWidth + layout.gutter <= 1_650)
        #expect(1_650 - (reader + layout.railWidth) > 0)
    }

    /// Without an index there is nothing to hold a position against, so the
    /// reader takes the pane and the column stays left-anchored at the gutter.
    @Test("Without an index the reader is uncapped")
    func readerIsUncappedAlone() {
        #expect(TranscriptLayout.resolve(availableWidth: 700).readerWidth == nil)
        #expect(TranscriptLayout.resolve(availableWidth: 1_000).readerWidth == nil)
    }

    /// The measure is the reason the transcript is readable at all, and the
    /// approved design pins it to 680–720.
    @Test("Widening the container never widens the measure")
    func measureIsStable() {
        #expect(
            TranscriptLayout.resolve(availableWidth: 1_200).measure
                == TranscriptLayout.resolve(availableWidth: 2_400).measure
        )
    }
}
