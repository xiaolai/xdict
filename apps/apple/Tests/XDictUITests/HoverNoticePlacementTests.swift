import AppKit
import Testing
@testable import XDictUI

/// **The brief hover notice never takes a click, the key window or the reader's app** (verifier, 2026-10-19: each of these
/// settings could be removed with no test failing). Click-through is also what makes hover look through it
/// (`HoverReader.passesClicksThrough`): a notice that took clicks would be read as a window of XDict's.
@MainActor
struct HoverNoticePanelTests {
    private struct Focus: Equatable {
        let active: Bool
        let key: ObjectIdentifier?
    }

    private func focus() -> Focus { Focus(active: NSApp.isActive, key: NSApp.keyWindow.map(ObjectIdentifier.init)) }

    @Test func thePanelTakesNoClickAndCannotActivate() {
        let panel = HoverNoticeHUD.makePanel()
        #expect(panel.ignoresMouseEvents, "the notice takes clicks, and hover would read it as XDict's window")
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    }

    /// Shown, the notice is up and nothing else moved: XDict not activated, no window made key.
    @Test func showingTheNoticeLeavesFocusWhereItWas() async {
        // An accessory app, as XDict beside the reader's app: one that could activate, were it asked to.
        NSApplication.shared.setActivationPolicy(.accessory)
        let before = focus()
        let hud = HoverNoticeHUD()
        hud.show("Nothing to look up here", near: CGPoint(x: 400, y: 400))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(hud.panel?.isVisible == true)
        #expect(hud.panel?.isKeyWindow != true, "the notice became key")
        #expect((hud.panel as? HoverNoticePanel)?.askedToBecomeKey == 0, "the notice was asked to become key")
        #expect(focus() == before, "showing the notice moved the focus")
        hud.panel?.orderOut(nil)
    }
}

/// **Where the brief hover notice sits** (owner's report, 2026-10-19). It must never cover the pointer, where it would
/// hide the word being read. Screen points, y up.
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
