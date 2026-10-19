import AppKit
import Testing
@testable import XDictUI

/// **Where the brief hover notice sits** (owner's report, 2026-10-19). It must never cover the pointer: a window of
/// XDict's in front at the pointer refuses the next hover there (`PointerWindow.ownership`). Screen points, y up.
struct HoverNoticePlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1_728, height: 1_084)
    private let size = CGSize(width: 160, height: 28)
    private let offset = HoverNoticePlacement.offset

    /// Above and to the right of the pointer, clear of it by the offset.
    @Test func theNoticeSitsAboveAndRightOfThePointer() {
        let pointer = CGPoint(x: 500, y: 500)
        let frame = HoverNoticePlacement.frame(size: size, pointer: pointer, visible: visible)
        #expect(frame.origin == CGPoint(x: pointer.x + offset, y: pointer.y + offset))
        #expect(!frame.insetBy(dx: -offset / 2, dy: -offset / 2).contains(pointer))
    }

    /// At the screen's top-right corner it goes below and to the left, still on the screen and still clear of the pointer.
    @Test func atTheCornerItFlipsAndStaysOnTheScreen() {
        let pointer = CGPoint(x: visible.maxX - 10, y: visible.maxY - 10)
        let frame = HoverNoticePlacement.frame(size: size, pointer: pointer, visible: visible)
        #expect(visible.contains(frame))
        #expect(frame.maxX == pointer.x - offset && frame.maxY == pointer.y - offset)
        #expect(!frame.contains(pointer))
    }
}
