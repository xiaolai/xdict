import AppKit
import Testing
@testable import XDictUI

/// **The lookup popover never takes the reader's app away** (P41; owner, 2026-10-17): a real `NSPopover`, shown from an
/// invisible anchor at the word, must leave the frontmost app, XDict's activation and the key window as they were, both
/// once shown and once dismissed. And it sits as the system's does: below the word, above where below has no room.
@MainActor
struct LookupPopoverTests {
    /// What XDict's side decides: whether it is the frontmost app, active, and which window is key. (Which other app is
    /// frontmost is the shared test Mac's, which other runs move: 2026-10-18, a process launched mid-test took it.)
    private struct Focus: Equatable {
        let frontIsThisApp: Bool
        let active: Bool
        let key: ObjectIdentifier?
    }

    private func focus() -> Focus {
        Focus(frontIsThisApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              active: NSApp.isActive, key: NSApp.keyWindow.map(ObjectIdentifier.init))
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

    /// **Arrow and body are one surface** (orchestrator's eye check, 2026-10-18: in dark the arrow was near-black and
    /// the body a flat grey). The popover is captured alone, in each appearance, and the arrow's middle and the body
    /// beside it must be the same colour within a small delta.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theArrowAndTheBodyAreOneSurface(_ appearance: NSAppearance.Name) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let popover = LookupPopover()
        popover.popover.appearance = NSAppearance(named: appearance)
        popover.show(NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 200)), size: CGSize(width: 390, height: 200),
                     word: CGRect(x: 600, y: 600, width: 40, height: 14), pointer: .zero,
                     visible: CGRect(x: 0, y: 0, width: 1440, height: 900))
        defer { popover.close() }
        try await Task.sleep(for: .milliseconds(600))
        let window = try #require(popover.popover.contentViewController?.view.window)
        #expect(window.frame.width == 416, "a 390 pt body in a 416 pt window, as Apple's")
        let image = try #require(Self.capture(window.windowNumber))
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        // The arrow points up at the word, at the anchor's centre: down that column, the first opaque pixel is its tip;
        // 4 pt under the tip is the arrow, 40 pt under it the body.
        let anchorX = (popover.anchor.frame.midX - window.frame.minX) * scale
        let tip = try #require((0..<image.pixelsHigh).first { (image.colorAt(x: Int(anchorX), y: $0)?.alphaComponent ?? 0) > 0.9 })
        let arrow = try #require(Self.colour(image, x: anchorX, y: CGFloat(tip) + 4 * scale))
        let body = try #require(Self.colour(image, x: anchorX, y: CGFloat(tip) + 40 * scale))
        let delta = zip(arrow, body).map { abs($0 - $1) }.max() ?? 1
        #expect(delta < 0.08, "arrow \(arrow) and body \(body) differ by \(delta) in \(appearance.rawValue)")
    }

    @Test func theEntryFadesBeforeTheFootersHairline() {
        #expect(PanelLook.entryFade == 16)
    }

    private static func capture(_ window: Int) -> NSBitmapImageRep? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("popover-\(window).png").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(window)", path]
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    private static func colour(_ image: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [CGFloat]? {
        guard let c = image.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return nil }
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }
}
