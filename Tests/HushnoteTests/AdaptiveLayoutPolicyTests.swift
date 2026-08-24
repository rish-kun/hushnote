import Testing
@testable import Hushnote

@Suite("Adaptive layout policy")
struct AdaptiveLayoutPolicyTests {
    @Test("Container thresholds are deterministic")
    func thresholds() {
        #expect(AdaptiveLayoutPolicy.tier(for: 0) == .compact)
        #expect(AdaptiveLayoutPolicy.tier(for: 759) == .compact)
        #expect(AdaptiveLayoutPolicy.tier(for: 760) == .regular)
        #expect(AdaptiveLayoutPolicy.tier(for: 1_099) == .regular)
        #expect(AdaptiveLayoutPolicy.tier(for: 1_100) == .wide)
    }

    @Test("Each tier owns a deliberate spacing policy")
    func spacing() {
        #expect(AdaptiveLayoutPolicy.compact.gutter == 24)
        #expect(AdaptiveLayoutPolicy.regular.gutter == 32)
        #expect(AdaptiveLayoutPolicy.wide.gutter >= 48)
        #expect(AdaptiveLayoutPolicy.wide.gutter <= 64)
        #expect(AdaptiveLayoutPolicy.wide.showsRightRail)
        #expect(AdaptiveLayoutPolicy.regular.showsRightRail == false)
    }

    @Test("Reading measure remains within an editorial line length")
    func readingMeasure() {
        #expect(AdaptiveLayoutPolicy.readingMeasure >= 680)
        #expect(AdaptiveLayoutPolicy.readingMeasure <= 720)
    }

    @Test("Unbounded scaffold height does not disable vertical scrolling")
    func finiteMinimumHeight() {
        #expect(AdaptiveLayoutPolicy.finiteMinimumHeight(for: 640) == 640)
        #expect(AdaptiveLayoutPolicy.finiteMinimumHeight(for: 0) == 0)
        #expect(AdaptiveLayoutPolicy.finiteMinimumHeight(for: .infinity) == 0)
    }
}
