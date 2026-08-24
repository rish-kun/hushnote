import Foundation
import Testing
@testable import Hushnote

/// The sidebar toggle's position is not observable from a unit test: SwiftUI
/// exposes no toolbar-placement introspection, and `AppShellView` cannot be
/// constructed because `AppCoordinator` requires the real database. What *is*
/// checkable is the ownership structure that produced the bug, so these tests
/// read the source.
@Suite("Window toolbar ownership")
struct WindowToolbarOwnershipTests {
    /// The toggle used to sit in `.toolbar`. Every placement macOS offers
    /// inside a split view is measured from a column edge, so the control slid
    /// sideways whenever the sidebar collapsed. It belongs to the window's
    /// titlebar, which the split view does not lay out.
    @Test("The sidebar toggle is hosted by the titlebar, not the toolbar")
    func toggleIsTitlebarHosted() throws {
        let source = try appShellSource()
        let windowToolbar = try section(
            from: "private struct AppShellWindowToolbar",
            to: "private struct AppSidebarToggle",
            in: source
        )
        let accessory = try section(
            from: "private struct SidebarToggleTitlebarAccessory",
            to: "private struct SidebarNavigationView",
            in: source
        )

        #expect(windowToolbar.contains("AppSidebarToggle(") == false)
        #expect(occurrences(of: "AppSidebarToggle(columnVisibility:", in: source) == 1)
        #expect(accessory.contains("AppSidebarToggle(columnVisibility: $columnVisibility)"))

        // `.leading` is the whole point: the window pins the accessory just
        // after the traffic lights, independently of split-view state.
        #expect(accessory.contains("NSTitlebarAccessoryViewController()"))
        #expect(accessory.contains("layoutAttribute = .leading"))
        #expect(accessory.contains("addTitlebarAccessoryViewController"))

        // Dropping the reference without detaching leaves a stale button in
        // the titlebar when the window is rebuilt.
        #expect(accessory.contains("controller?.removeFromParent()"))
    }

    /// `toolbar(removing:)` only suppresses the stock item when it is applied
    /// to the column that installs it. Applied to a container wrapping
    /// `NavigationSplitView` it does nothing at all, and the app drew two
    /// sidebar buttons side by side.
    @Test("The stock toggle is removed on the column that installs it")
    func stockToggleRemovalIsOnTheSidebarColumn() throws {
        let source = try appShellSource()
        let shell = try section(
            from: "struct AppShellView: View {",
            to: "private struct MeetingSearchPalette",
            in: source
        )
        let windowToolbar = try section(
            from: "private struct AppShellWindowToolbar",
            to: "private struct AppSidebarToggle",
            in: source
        )

        #expect(occurrences(of: ".toolbar(removing: .sidebarToggle)", in: source) == 1)
        #expect(shell.contains(".toolbar(removing: .sidebarToggle)"))
        #expect(windowToolbar.contains(".toolbar(removing: .sidebarToggle)") == false)

        // The removal has to follow the sidebar column's own modifiers, so it
        // applies to the column rather than to the split view.
        let column = try section(
            from: "SidebarNavigationView(",
            to: "} detail: {",
            in: shell
        )
        #expect(column.contains(".toolbar(removing: .sidebarToggle)"))
    }

    /// A view hosted in a titlebar accessory is outside the key window's menu
    /// responder chain. A `keyboardShortcut` there looks present and never
    /// fires, so the View menu owns it.
    @Test("The toggle's keyboard shortcut lives in the menu, not the accessory")
    func keyboardShortcutIsMenuOwned() throws {
        let source = try appShellSource()
        let toggle = try section(
            from: "private struct AppSidebarToggle",
            to: "private struct SidebarToggleTitlebarAccessory",
            in: source
        )
        #expect(toggle.contains("keyboardShortcut") == false)

        let app = try String(contentsOf: sourceURL("Sources/Hushnote/App/HushnoteApp.swift"), encoding: .utf8)
        #expect(app.contains("CommandGroup(after: .sidebar)"))
        #expect(app.contains(".hushnoteToggleSidebar"))
        #expect(app.contains(#".keyboardShortcut("s", modifiers: [.command, .option])"#))

        // The menu posts; the shell performs the same transition the button does.
        #expect(source.contains("publisher(for: .hushnoteToggleSidebar)"))
    }

    /// Neither split column may own a movable toolbar, or SwiftUI re-homes
    /// items between columns as visibility changes.
    @Test("The sidebar column declares no toolbar of its own")
    func sidebarColumnHasNoToolbar() throws {
        let source = try appShellSource()
        let sidebar = try section(
            from: "private struct SidebarNavigationView",
            to: "struct SidebarScrollerConfiguration",
            in: source
        )
        #expect(sidebar.contains(".toolbar") == false)
    }

    private func appShellSource() throws -> String {
        try String(contentsOf: sourceURL("Sources/Hushnote/UI/AppShellView.swift"), encoding: .utf8)
    }

    private func sourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
    }

    private func section<S: StringProtocol>(
        from startMarker: String,
        to endMarker: String,
        in source: S
    ) throws -> String {
        guard let start = source.range(of: startMarker) else {
            throw SourceStructureError.missing(startMarker)
        }
        guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            throw SourceStructureError.missing(endMarker)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}

private enum SourceStructureError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let marker): "Missing source marker: \(marker)"
        }
    }
}
