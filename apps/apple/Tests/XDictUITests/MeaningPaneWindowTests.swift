import AppKit
import Testing
import XDictTokens
@testable import XDictUI

/// **The answer pane's window** (owner, 2026-10-24): full height against the main window's trailing edge, so the main
/// window keeps its frame, its reading width and SwiftUI's `.searchable` at its own trailing edge. A screen with no room
/// beside the main window gives no frame, and the sheet takes over.
struct MeaningPaneWindowTests {
    static let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    static let pane = Tokens.Window.meaningPaneIdeal

    @Test func thePaneSitsFullHeightAgainstTheMainWindowsTrailingEdge() throws {
        let main = NSRect(x: 100, y: 120, width: 800, height: 600)
        let frame = try #require(MeaningPaneWindow.Layout.frame(main: main, screen: Self.screen, width: Self.pane))
        #expect(frame.origin.x == main.maxX + MeaningPanePreferences.gap(),
                "beside the main window, a little apart")
        #expect(frame.origin.y == main.minY)
        #expect(frame.size.width == Self.pane)
        #expect(frame.size.height == main.height, "full height")
        #expect(frame.maxX <= Self.screen.maxX)
    }

    @Test func aScreenWithNoRoomBesideTheMainWindowUsesTheSheet() {
        let atTheEdge = NSRect(x: Self.screen.maxX - 800, y: 120, width: 800, height: 600)
        #expect(MeaningPaneWindow.Layout.frame(main: atTheEdge, screen: Self.screen, width: Self.pane) == nil,
                "no room to the right: the sheet")
        #expect(MeaningPaneWindow.Layout.frame(main: NSRect(x: 0, y: 0, width: 800, height: 600),
                                               screen: Self.screen, width: 0) == nil,
                "a pane with no width has no window")
    }
}
