import Foundation
import Testing
import XDictTestSupport
@testable import XDictUI

/// **The Explore panel's rows are given a height, not only a cap** (owner, 2026-10-31: every tab showed exactly
/// one row, whatever the answer held).
///
/// A SwiftUI `List` has no height of its own: it fills whatever it is proposed. The panel's popover latches its
/// size when it is shown — while the tab is still loading, so the List is empty — and a `.frame(maxHeight:)`
/// proposes nothing, only caps. The List is then left the leftover space, about one row, and it never grows when
/// the answer's rows arrive: every tab, however many rows the core answered, draws one. The list is the token's
/// eight rows tall from the loading state on, so the popover's latched size already holds them.
///
/// SwiftUI layout cannot be measured in this test process (no `NSApplication`), so this holds the shape of the
/// fix in the source, as `ExploreTabsTests` holds the tab strip's.
struct ExplorePanelTests {
    @Test func theRowsListIsGivenItsHeight() throws {
        let file = Manifest.package.appending(path: "Sources/XDictUI/ExplorePopover.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(".frame(height: Tokens.Window.exploreListHeight)"),
                "the Explore rows list lost the height the popover sizes it by")
        #expect(!text.contains(".frame(maxHeight: Tokens.Window.exploreListHeight)"),
                "a maxHeight only caps the list; in a popover it leaves it one row tall")
    }

    /// **An answer's rows are the app's list rows, not a control's boxes** (owner, 2026-10-31: every row wore a white
    /// fill, a hairline border, square corners, and its text sat at the top of a tall row). A `List` in this fixed-height
    /// popover drew its own row chrome and stretched each row over the list's height. The rows are a `ScrollView` and a
    /// `LazyVStack` of plain buttons — one line of the sidebar's height, the reading face for the word, the caption role
    /// for its reason — and the highlight uses the sidebar's selection corner.
    ///
    /// SwiftUI layout cannot be measured in this test process (no `NSApplication`), so this holds the source's shape,
    /// as the test above does.
    @Test func theRowsAreTheAppsOwnListRows() throws {
        let file = Manifest.package.appending(path: "Sources/XDictUI/ExplorePopover.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("List(model.page.rows"), "the answer's rows are a List again: its row chrome is back")
        #expect(text.contains("ScrollView") && text.contains("LazyVStack"), "the rows lost their plain stack")
        #expect(text.contains("minHeight: Tokens.Row.sidebar"),
                "a row no longer takes a list row's height, so the text can sit at the top of a tall box")
        #expect(text.contains("ReadingText.body"), "the row's word left the panel's reading face")
        #expect(text.contains("Tokens.Colour.accent.color"), "a chosen row lost the accent the app's lists give it")
        #expect(text.contains("Tokens.Radius.sidebarSelection"),
                "the hover and selection highlight left the sidebar's own selection corner")
    }
}
