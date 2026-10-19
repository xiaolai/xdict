import CoreGraphics
import Foundation
import Testing
@testable import XDictCapture

/// Whose window is under the pointer, which the hover path has to know **before** it asks
/// Accessibility anything — see `PointerWindow`'s own note and the 2026-09-25 crash report.
struct PointerWindowTests {
    private func window(_ pid: Int32, _ rect: CGRect) -> ListedWindow {
        ListedWindow(pid: pid, bounds: rect)
    }

    /// **Another app's window in front of ours owns the point** (owner's report, 2026-10-19: hover read only the one word of
    /// System Settings' title that lay outside XDict's main and Settings windows behind it). Ours beneath is still named,
    /// so the hit test asks that app alone and never the system-wide element, which could land in this process.
    @Test func anotherAppsWindowInFrontOfOursOwnsThePoint() {
        let point = CGPoint(x: 500, y: 400)
        let windows = [
            window(22, CGRect(x: 0, y: 0, width: 1_400, height: 900)),
            window(99, CGRect(x: 400, y: 300, width: 300, height: 300)),
        ]
        #expect(PointerWindow.ownership(at: point, in: windows, ours: 99) == .coveringOurs(owner: 22))
    }

    /// **A click-through window of ours is no window at all to hover** — the hover notice, the popover's anchor: dropped
    /// from the list by its window number, so the window under it owns the point. Only ours: another app's window with
    /// the same number is kept, and so is every ordinary window of ours (the main window, Settings, the popover).
    @Test func ourClickThroughWindowsAreDroppedAndNothingElse() {
        let point = CGPoint(x: 50, y: 50)
        let notice = ListedWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 7, layer: 3)
        let popover = ListedWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 8, layer: 3)
        let theirs = ListedWindow(pid: 22, bounds: CGRect(x: 0, y: 0, width: 900, height: 900), windowID: 7)
        let kept = PointerWindow.withoutClickThrough([notice, popover, theirs], ours: 99, passesClicksThrough: { $0 == 7 })
        #expect(kept == [popover, theirs])
        #expect(PointerWindow.ownership(at: point, in: PointerWindow.withoutClickThrough(
            [notice, theirs], ours: 99, passesClicksThrough: { $0 == 7 }), ours: 99) == .notOurs)
    }

    /// Ours in front is ours, whatever lies beneath it.
    @Test func ourWindowInFrontIsOurs() {
        let point = CGPoint(x: 500, y: 400)
        let windows = [
            window(99, CGRect(x: 400, y: 300, width: 300, height: 300)),
            window(22, CGRect(x: 0, y: 0, width: 1_400, height: 900)),
        ]
        #expect(PointerWindow.ownership(at: point, in: windows, ours: 99) == .ours)
    }

    /// Ours elsewhere on the screen does not count: the control for the tests above.
    @Test func ourWindowElsewhereDoesNotCount() {
        let windows = [
            window(99, CGRect(x: 400, y: 300, width: 300, height: 300)),
            window(22, CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        #expect(PointerWindow.ownership(at: CGPoint(x: 50, y: 50), in: windows, ours: 99) == .notOurs)
    }

    /// Our own window counts even while invisible — one fading in is still serviced in-process.
    @Test func ourInvisibleWindowStillCounts() {
        let fading = ListedWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 0)
        let behind = window(22, CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(PointerWindow.ownership(at: CGPoint(x: 10, y: 10), in: [fading, behind], ours: 99) == .ours)
    }

    /// Another app's invisible window covers nothing: no pixel of it is under the pointer, so ours beneath is in front.
    @Test func anotherAppsInvisibleWindowCoversNothing() {
        let invisible = ListedWindow(pid: 22, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 0)
        let ours = window(99, CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(PointerWindow.ownership(at: CGPoint(x: 10, y: 10), in: [invisible, ours], ours: 99) == .ours)
    }

    @Test func anEmptyListHasNothingOfOurs() {
        #expect(PointerWindow.ownership(at: .zero, in: [], ours: 99) == .notOurs)
    }

    /// **The panel is at `.floating`, so a level filter would miss exactly the window this is for.**
    /// The recogniser's own search keeps `kCGWindowLayer == 0` on purpose; copying that line here
    /// would restore the crash while leaving every other test green.
    @Test func aWindowAboveTheOrdinaryLevelIsStillListed() {
        let listed = PointerWindow.listed([
            [
                kCGWindowOwnerPID as String: Int32(11),
                kCGWindowLayer as String: 3,
                kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 30, height: 40)
                    .dictionaryRepresentation as NSDictionary,
            ],
            [
                kCGWindowOwnerPID as String: Int32(22),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600)
                    .dictionaryRepresentation as NSDictionary,
            ],
        ])
        #expect(listed == [
            ListedWindow(pid: 11, bounds: CGRect(x: 10, y: 20, width: 30, height: 40), layer: 3),
            ListedWindow(pid: 22, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
        ])
    }

    /// A window the compositor described incompletely is dropped, not placed at the origin — a rect of
    /// zeros would claim every hover at the top-left corner of the screen.
    @Test func aWindowWithoutAPlaceOrAnOwnerIsDropped() {
        #expect(PointerWindow.listed([
            [kCGWindowOwnerPID as String: Int32(11)],
            [kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 10, height: 10)
                .dictionaryRepresentation as NSDictionary],
            [:],
        ]).isEmpty)
    }
}
