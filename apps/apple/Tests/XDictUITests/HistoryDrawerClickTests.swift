import CoreGraphics
import Testing
import XDictUI

/// **Which clicks dismiss the open drawer** (XiaolaiDict `9695fcb`, its shudder fix): the drawer's own rect dismisses on
/// nothing; anywhere else dismisses, **except the owned status button's live rectangle** — its click belongs to its own
/// action, and dismissing on the mouse-down would close the drawer and reopen it on the mouse-up, a visible
/// retract-then-pop on every repeated tray click.
struct HistoryDrawerClickTests {
    static let content = CGRect(x: 1_120, y: 0, width: 320, height: 875)
    static let statusItem = CGRect(x: 1_330, y: 878, width: 24, height: 22)

    @Test func aClickInsideTheDrawerIsTheReaders() {
        #expect(!HistoryDrawerController.clickDismisses(at: CGPoint(x: 1_200, y: 400), content: Self.content,
                                                       statusItem: Self.statusItem))
    }

    @Test func aClickAnywhereElseDismisses() {
        #expect(HistoryDrawerController.clickDismisses(at: CGPoint(x: 400, y: 400), content: Self.content,
                                                      statusItem: Self.statusItem))
        #expect(HistoryDrawerController.clickDismisses(at: CGPoint(x: 400, y: 400), content: Self.content,
                                                      statusItem: nil),
                "no status item known, the reader's click still goes through")
    }

    /// The regression: the tray click lies outside the drawer and used to dismiss it on the down. The button's action then
    /// re-shows it on the up — the shudder. The live rectangle keeps the drawer open, so `show()` is the no-op it is meant
    /// to be.
    @Test func aClickOnTheStatusButtonNeverDismisses() {
        let onTray = CGPoint(x: 1_342, y: 889)
        #expect(!HistoryDrawerController.clickDismisses(at: onTray, content: Self.content, statusItem: Self.statusItem))
        #expect(!Self.content.contains(onTray), "the tray is outside the drawer: only the exclusion keeps it open")
    }

    /// The rectangle is read live, so a reader who moved the item (a wider menu bar, another display) is still excluded.
    @Test func theRectangleIsWhateverTheButtonSaysNow() {
        let moved = CGRect(x: 200, y: 878, width: 24, height: 22)
        #expect(!HistoryDrawerController.clickDismisses(at: CGPoint(x: 212, y: 889), content: Self.content,
                                                       statusItem: moved))
        #expect(HistoryDrawerController.clickDismisses(at: CGPoint(x: 1_342, y: 889), content: Self.content,
                                                      statusItem: moved))
    }
}
