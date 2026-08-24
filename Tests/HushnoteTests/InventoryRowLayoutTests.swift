import Testing
@testable import Hushnote

/// The inventory row replaced seven hand-written row cadences (6, 8, 10, 11,
/// 12, 18 and 20 points of vertical padding) with one. The arrangement is the
/// only part of that worth a test: it is a decision, not composition, and it
/// is what stops a row from overflowing a narrow window.
@Suite("Inventory row layout")
struct InventoryRowLayoutTests {
    @Test("Only the compact tier stacks the leading column above the content")
    func arrangement() {
        #expect(InventoryRowLayout.arrangement(for: .compact) == .stacked)
        #expect(InventoryRowLayout.arrangement(for: .regular) == .columns)
        #expect(InventoryRowLayout.arrangement(for: .wide) == .columns)
    }

    /// Regular and wide deliberately share a cadence. A row is a row at any
    /// width above the compact threshold; only the page gutter opens up.
    @Test("Regular and wide share one row cadence")
    func cadence() {
        #expect(
            InventoryRowLayout.verticalPadding(for: .regular)
                == InventoryRowLayout.verticalPadding(for: .wide)
        )
        #expect(
            InventoryRowLayout.columnSpacing(for: .regular)
                == InventoryRowLayout.columnSpacing(for: .wide)
        )
    }

    /// Compact tightens the column gap because the columns have become a
    /// stack, and the gutter is already at its narrowest.
    @Test("Compact tightens rather than loosens")
    func compactTightens() {
        #expect(
            InventoryRowLayout.verticalPadding(for: .compact)
                < InventoryRowLayout.verticalPadding(for: .regular)
        )
        #expect(
            InventoryRowLayout.columnSpacing(for: .compact)
                < InventoryRowLayout.columnSpacing(for: .regular)
        )
    }

    /// Every value is a real, positive measurement. A zero here would collapse
    /// rows into each other and still compile.
    @Test("Every tier yields usable spacing")
    func spacingIsUsable() {
        for policy in [AdaptiveLayoutPolicy.compact, .regular, .wide] {
            #expect(InventoryRowLayout.verticalPadding(for: policy) > 0)
            #expect(InventoryRowLayout.columnSpacing(for: policy) > 0)
        }
    }
}
