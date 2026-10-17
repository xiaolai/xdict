import CoreGraphics
import Testing
import XDictAnywhere

/// **Where the panel goes** (plan-macos-v1 WI-8: "opens the panel by the selection"), in AppKit's coordinates, y up:
/// below the word and centred on it where it fits, above where it does not, the larger side where neither does, always
/// inside the screen; by the pointer where the app could not say where the word is. Adapted from XiaolaiDict's
/// `PanelPlacement`, without the card's tail.
struct PanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    private let size = CGSize(width: 400, height: 300)

    @Test func belowTheWordAndCentredOnIt() {
        let word = CGRect(x: 600, y: 700, width: 60, height: 16)
        let frame = PanelPlacement.frame(size: size, word: word, pointer: .zero, visible: screen)
        #expect(frame.size == size)
        #expect(frame.midX == word.midX)
        #expect(frame.maxY == word.minY - PanelPlacement.wordGap)
        #expect(!frame.intersects(word), "the panel covers the word it explains")
    }

    /// Room on both sides: below, as a reader reads down — not the larger side.
    @Test func belowWhereBothSidesHaveRoom() {
        let word = CGRect(x: 600, y: 400, width: 60, height: 16)
        let frame = PanelPlacement.frame(size: size, word: word, pointer: .zero, visible: screen)
        #expect(frame.maxY == word.minY - PanelPlacement.wordGap)
    }

    @Test func aboveTheWordWhereBelowHasNoRoom() {
        let word = CGRect(x: 600, y: 100, width: 60, height: 16)
        let frame = PanelPlacement.frame(size: size, word: word, pointer: .zero, visible: screen)
        #expect(frame.minY == word.maxY + PanelPlacement.wordGap)
        #expect(!frame.intersects(word))
    }

    @Test func keptOnScreenByItsMargin() {
        let word = CGRect(x: 1_420, y: 700, width: 15, height: 16)
        let frame = PanelPlacement.frame(size: size, word: word, pointer: .zero, visible: screen)
        #expect(frame.maxX == screen.maxX - PanelPlacement.margin)
        let left = PanelPlacement.frame(size: size, word: CGRect(x: 2, y: 700, width: 10, height: 16), pointer: .zero,
                                        visible: screen)
        #expect(left.minX == screen.minX + PanelPlacement.margin)
    }

    /// Neither side has room: the larger, the panel shrunk to it, so it scrolls rather than covers the word.
    @Test func theLargerSideShrunkWhereNeitherFits() {
        let tall = CGSize(width: 400, height: 800)
        let word = CGRect(x: 600, y: 500, width: 60, height: 16)
        let frame = PanelPlacement.frame(size: tall, word: word, pointer: .zero, visible: screen)
        #expect(!frame.intersects(word))
        #expect(frame.maxY == word.minY - PanelPlacement.wordGap)
        #expect(frame.minY == screen.minY + PanelPlacement.margin)
    }

    /// No word: by the pointer, below and right of it, on screen.
    @Test func byThePointerWithNoWord() {
        let frame = PanelPlacement.frame(size: size, word: nil, pointer: CGPoint(x: 300, y: 600), visible: screen)
        #expect(frame.minX == 300 + PanelPlacement.pointerGap.width)
        #expect(frame.maxY == 600 - PanelPlacement.pointerGap.height)
        let corner = PanelPlacement.frame(size: size, word: nil, pointer: CGPoint(x: 1_430, y: 20), visible: screen)
        #expect(screen.insetBy(dx: PanelPlacement.margin, dy: PanelPlacement.margin).contains(corner))
    }

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
        #expect(PanelPlacement.height(document: nil, chrome: 29) == PanelPlacement.defaultHeight)
        #expect(PanelPlacement.height(document: .nan, chrome: 29) == PanelPlacement.defaultHeight)
    }
}
