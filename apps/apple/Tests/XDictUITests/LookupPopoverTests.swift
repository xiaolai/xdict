import AppKit
import Testing
@testable import XDictUI

/// **The lookup popover never takes the reader's app away** (P41; owner, 2026-10-17): a real `NSPopover`, shown from an
/// invisible anchor at the word, must leave the frontmost app, XDict's activation and the key window as they were, both
/// once shown and once dismissed. And it sits as the system's does: below the word, above where below has no room.
@MainActor
struct LookupPopoverTests {
    private struct Focus: Equatable {
        let front: pid_t?
        let active: Bool
        let key: ObjectIdentifier?
    }

    private func focus() -> Focus {
        Focus(front: NSWorkspace.shared.frontmostApplication?.processIdentifier, active: NSApp.isActive,
              key: NSApp.keyWindow.map(ObjectIdentifier.init))
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func theAnchorCanNeitherBeKeyNorMainNorTakeAClick() {
        let anchor = PopoverAnchor()
        #expect(!anchor.canBecomeKey && !anchor.canBecomeMain)
        #expect(anchor.ignoresMouseEvents)
        #expect(anchor.styleMask.contains(.nonactivatingPanel))
        #expect(anchor.alphaValue == 0 || !anchor.isOpaque)
    }

    @Test func showingAndDismissingLeaveFocusWhereItWas() async {
        // An accessory app, as XDict beside the reader's app: one that could activate, were it asked to.
        NSApplication.shared.setActivationPolicy(.accessory)
        let before = focus()
        let popover = LookupPopover()
        popover.show(NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 200)), size: CGSize(width: 390, height: 200),
                     word: CGRect(x: 400, y: 500, width: 40, height: 14), pointer: .zero,
                     visible: CGRect(x: 0, y: 0, width: 1440, height: 900))
        await settle()
        #expect(popover.isShown)
        #expect(popover.popover.behavior == .transient)
        #expect(popover.anchor.frame == CGRect(x: 400, y: 500, width: 40, height: 14), "anchored at the word")
        #expect(popover.popover.contentViewController?.view.window?.isKeyWindow != true, "the popover became key")
        #expect(focus() == before, "showing moved the focus")
        popover.close()
        await settle()
        #expect(!popover.isShown && !popover.anchor.isVisible)
        #expect(focus() == before, "dismissing moved the focus")
    }

    @Test func belowTheWordAboveWhereBelowHasNoRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(LookupPopover.edge(word: CGRect(x: 100, y: 600, width: 40, height: 14), height: 300, visible: visible)
                == .minY)
        #expect(LookupPopover.edge(word: CGRect(x: 100, y: 120, width: 40, height: 14), height: 300, visible: visible)
                == .maxY)
    }

    @Test func withoutAWordTheAnchorIsAPointAtThePointer() {
        #expect(LookupPopover.anchorRect(word: nil, pointer: CGPoint(x: 50, y: 60)) == CGRect(x: 50, y: 60, width: 1, height: 1))
    }

    @Test func theLastFooterRowKeepsTheBottomInset() {
        #expect(PanelLook.bottomInset == 8)
    }
}
