import CoreGraphics
import Foundation
import Testing
import XDictTestSupport
@testable import XDictUI

/// **The Explore panel's tabs wrap rather than clip** (owner, 2026-10-29: the last tab was cut off at the panel's edge,
/// and clicking it made the strip grow). A segmented control had to be as wide as seven equal segments and could not
/// shrink, so it overflowed the panel's fixed width; wrapped chips have no such width.
///
/// The layout itself cannot be run in this test process (SwiftUI, with no `NSApplication`), so what is held here is the
/// arithmetic it is built on — `ChipWrap.lines` — and that the panel is the wrapping row rather than a segmented picker.
struct ExploreTabsTests {
    private func chips(_ widths: [CGFloat], height: CGFloat = 22) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    @Test func everythingSitsOnOneLineWhenItFits() {
        let sizes = chips([48, 39, 35, 38, 63, 61, 77])
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 608, gap: 4) == [0..<7])
    }

    /// The Explore panel's own case: seven equal segments of 100 pt in a 608 pt row — the shape a segmented control took
    /// — need two lines, and the break comes before the chip that would not fit.
    @Test func aLineBreaksBeforeTheChipThatWouldNotFit() {
        let sizes = chips(Array(repeating: 100, count: 7))
        // Five chips and their four gaps are 516 pt; a sixth would make 620, past the 608 the panel has.
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 608, gap: 4) == [0..<5, 5..<7])
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 724, gap: 4) == [0..<7])
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 723, gap: 4) == [0..<6, 6..<7])
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 300, gap: 4) == [0..<2, 2..<4, 4..<6, 6..<7])
    }

    /// A chip wider than the room is not cut: it takes a line of its own and the next one starts below it.
    @Test func aChipWiderThanTheRoomGetsItsOwnLine() {
        let sizes = chips([700, 50])
        #expect(ChipWrap.lines(sizes: sizes, maxWidth: 608, gap: 4) == [0..<1, 1..<2])
    }

    @Test func aLineCountsItsGapsAndItsTallestChip() {
        let sizes = chips([100, 100, 100], height: 22)
        #expect(ChipWrap.width(of: 0..<3, sizes: sizes, gap: 4) == 308)
        #expect(ChipWrap.height(of: 0..<3, sizes: sizes) == 22)
        #expect(ChipWrap.lines(sizes: [], maxWidth: 100, gap: 4).isEmpty)
    }

    /// The panel is the wrapping row: a segmented picker here is the defect, whatever its width.
    @Test func thePanelUsesTheWrappingTabs() throws {
        let file = Manifest.package.appending(path: "Sources/XDictUI/ExplorePopover.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("ExploreTabs("), "the Explore panel lost its wrapping tab row")
        #expect(!text.contains(".pickerStyle(.segmented)"), "a segmented picker cannot fit seven tabs in the panel")
    }
}
