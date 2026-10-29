import Foundation
import Testing
import XDictTestSupport

/// **The Explore panel is as wide as its tab strip, not as wide as a constant** (owner, 2026-10-29: the last tab was cut
/// off at the panel's edge, and clicking it made the strip grow). A segmented `Picker` gives every segment the width of
/// the widest label, so seven one-word tabs want about 700 pt — more than the token, which had been reasoned up from the
/// labels' own widths (553 pt). A fixed `.frame(width:)` clipped the control; `.frame(minWidth:)` lets the panel follow it.
///
/// The layout itself cannot be measured here (SwiftUI, in a test process with no `NSApplication`), so this holds the
/// shape of the fix: the panel takes the strip's width. `Tokens.Window.explorePopoverWidth` is the least, and its token
/// says so.
struct ExplorePanelLayoutTests {
    @Test func thePanelTakesItsTabStripsWidth() throws {
        let file = Manifest.package.appending(path: "Sources/XDictUI/ExplorePopover.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(".frame(minWidth: Tokens.Window.explorePopoverWidth"),
                "the Explore panel lost the width its tab strip needs")
        #expect(!text.contains(".frame(width: Tokens.Window.explorePopoverWidth"),
                "a fixed width clips the seven-segment tab strip: the last tab is cut off and grows when clicked")
    }
}
