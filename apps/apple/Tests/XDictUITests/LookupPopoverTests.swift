import AppKit
import Testing
@testable import XDictUI

/// **The lookup popover never takes the reader's app away** (P41; owner, 2026-10-17): a real `NSPopover`, shown from an
/// invisible anchor at the word, takes no key window and leaves nothing behind, once shown and once dismissed. And it
/// sits as the system's does: below the word, above where below has no room.
///
/// **What it cannot assert here is activation** (measured 2026-10-25): another suite in this process
/// (`AISettingsEndpointTests`) activates the app on purpose while this one runs, and SwiftPM runs every test target in
/// one process, so `NSApp.isActive` and `NSWorkspace.frontmostApplication` move for reasons that are not this popover's
/// — the full-run-only flake, which passed five times alone the same hour. The reader's front app is upheld where it is
/// observable: the E2E reader stage holds the front before each action and fails when another app took it.
@Suite(.serialized)
@MainActor
struct LookupPopoverTests {

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func theAnchorCanNeitherBeKeyNorMainNorTakeAClick() {
        let anchor = PopoverAnchor()
        #expect(!anchor.canBecomeKey && !anchor.canBecomeMain)
        #expect(anchor.ignoresMouseEvents)
        #expect(anchor.styleMask.contains(.nonactivatingPanel))
        #expect(anchor.alphaValue == 0 || !anchor.isOpaque)
    }

    /// **Shown and dismissed, it takes no key window and leaves nothing behind**: the anchor is not key, the popover is
    /// not key, and after the close neither is shown — the state a steal of the reader's keyboard would leave.
    @Test func showingAndDismissingTakeNoKeyWindowAndLeaveNothingBehind() async {
        // An accessory app, as XDict beside the reader's app: one that could activate, were it asked to.
        NSApplication.shared.setActivationPolicy(.accessory)
        let popover = LookupPopover()
        popover.show(NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 200)), size: CGSize(width: 390, height: 200),
                     word: CGRect(x: 400, y: 500, width: 40, height: 14), pointer: .zero,
                     visible: CGRect(x: 0, y: 0, width: 1440, height: 900))
        await settle()
        #expect(popover.isShown)
        // **`applicationDefined`, not `transient`** (2026-10-21): a transient popover takes the outside click that
        // dismisses it, so the click never reaches the app the reader clicked and that app comes back to the front.
        // XDict's own two monitors close the panel and hand the event on; AppKit takes nothing.
        #expect(popover.popover.behavior == .applicationDefined)
        #expect(popover.anchor.frame == CGRect(x: 400, y: 500, width: 40, height: 14), "anchored at the word")
        #expect(popover.popover.contentViewController?.view.window?.isKeyWindow != true, "the popover became key")
        #expect(NSApp.keyWindow !== popover.anchor, "the anchor became key")
        popover.close()
        await settle()
        #expect(!popover.isShown && !popover.anchor.isVisible)
        #expect(NSApp.keyWindow !== popover.anchor, "the anchor was left key")
        #expect(popover.popover.contentViewController?.view.window?.isKeyWindow != true, "the popover was left key")
    }

    @Test func belowTheWordAboveWhereBelowHasNoRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(LookupPopover.edge(word: CGRect(x: 100, y: 600, width: 40, height: 14), height: 300, visible: visible)
                == .minY)
        #expect(LookupPopover.edge(word: CGRect(x: 100, y: 120, width: 40, height: 14), height: 300, visible: visible)
                == .maxY)
    }

    /// **Shown again and again, it stays its size and by the word** (E2E of 2026-10-18: one popover, reused for every
    /// lookup, grew by the opening-to-entry difference at each showing, 586, 812, 978, then the whole screen, its body
    /// left at the bottom and its window over the word). Each showing opens at 180 pt and grows to the 560 pt cap, as
    /// `LookupAnywhere` does; the window must be the body plus its chrome every time, its top edge under the word.
    @Test func reusedTheWindowIsItsBodyEveryTimeAndUnderTheWord() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let popover = LookupPopover()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        for round in 0..<4 {
            let word = CGRect(x: 300 + CGFloat(round) * 40, y: 760, width: 60, height: 16)
            popover.show(content, size: CGSize(width: 390, height: 180), word: word, pointer: .zero, visible: visible)
            await settle()
            #expect(popover.frame?.height == 206, "round \(round) opened at \(String(describing: popover.frame))")
            popover.resize(height: 560)
            await settle()
            let frame = popover.frame ?? .zero
            #expect(frame.height == 586, "round \(round) grew to \(frame)")
            #expect(frame.maxY <= word.minY + LookupPopover.chrome.height, "round \(round) over the word: \(frame)")
            #expect(word.minY - frame.maxY <= 12, "round \(round) not by the word: \(frame)")
            popover.close()
            await settle()
        }
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
