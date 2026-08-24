import Testing
@testable import Hushnote

@Suite("Sidebar scroller configuration")
struct SidebarScrollerConfigurationTests {
    @Test("Navigation hides only its vertical scroller chrome")
    func navigationScrollerChrome() {
        let configuration = SidebarScrollerConfiguration.navigation

        #expect(configuration.hidesVerticalScroller)
        #expect(configuration.autohidesScrollers)
    }
}
