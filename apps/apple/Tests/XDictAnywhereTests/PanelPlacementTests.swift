import CoreGraphics
import Testing
import XDictAnywhere

/// **The panel's word and height** (plan-macos-v1 WI-8): the word's Accessibility rectangle in AppKit's coordinates,
/// and the height the entry asks. Where the popover goes is AppKit's, from its anchor (LookupPopoverTests).
struct PanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    /// The Accessibility API's rectangles are y down from the primary screen's top-left; AppKit's are y up.
    @Test func anAccessibilityRectangleIsFlipped() {
        let down = CGRect(x: 10, y: 100, width: 50, height: 20)
        #expect(PanelPlacement.flipped(down, primaryHeight: 900) == CGRect(x: 10, y: 780, width: 50, height: 20))
    }

    /// **The panel is as tall as its entry** (UI review P-03): a one-line entry no longer leaves 300 pt of white, a
    /// long one stops at the cap and scrolls, and an entry not measured keeps the default.
    @Test func thePanelIsAsTallAsItsEntryWithinBounds() {
        #expect(PanelPlacement.height(document: 40, chrome: 29) == PanelPlacement.minimumHeight)
        #expect(PanelPlacement.height(document: 300, chrome: 29) == 329)
        #expect(PanelPlacement.height(document: 5_000, chrome: 29) == PanelPlacement.maximumHeight)
        #expect(PanelPlacement.height(document: nil, chrome: 29) == PanelPlacement.initialHeight)
        #expect(PanelPlacement.height(document: .nan, chrome: 29) == PanelPlacement.initialHeight)
    }
}
