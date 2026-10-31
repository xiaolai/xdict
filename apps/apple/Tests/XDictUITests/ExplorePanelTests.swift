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
}
