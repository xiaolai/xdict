import AppKit

/// **The lookup popover** (P41; owner, 2026-10-17: "make it a real popover"): an `NSPopover` — the system's glass body
/// and arrow — shown from an invisible anchor window placed at the word's screen rectangle (the selection's
/// Accessibility bounds), below the word and above where below has no room, as the system Look Up popover sits.
/// **It never takes the reader's app away**: the anchor is a non-activating panel that can be neither key nor main and
/// takes no click, and nothing here activates XDict (`LookupPopoverTests` holds the frontmost app, XDict's activation
/// and the key window unchanged across showing and dismissing). Transient, so a click elsewhere in XDict closes it;
/// Escape and clicks in other apps are the caller's (`LookupAnywhere`), as XDict is not the active app.
@MainActor
public final class LookupPopover: NSObject, NSPopoverDelegate {
    public let anchor = PopoverAnchor()
    public let popover = NSPopover()
    /// Told when the popover closed by itself (transient behaviour), not by `close()`.
    public var onClose: (() -> Void)?
    private var closing = false

    override public init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    public var isShown: Bool { popover.isShown }
    /// The popover's window frame, arrow and shadow included: what the instruments record.
    public var frame: CGRect? { popover.isShown ? popover.contentViewController?.view.window?.frame : nil }

    /// The anchor: the word, or a point at the pointer when no word could be read.
    public static func anchorRect(word: CGRect?, pointer: CGPoint) -> CGRect {
        word ?? CGRect(x: pointer.x, y: pointer.y, width: 1, height: 1)
    }

    /// Below the word (AppKit's `minY`, y up), above where the room below is short of the popover and above is larger.
    public static func edge(word: CGRect, height: CGFloat, visible: CGRect) -> NSRectEdge {
        let below = word.minY - visible.minY, above = visible.maxY - word.maxY
        return below >= height || below >= above ? .minY : .maxY
    }

    /// Shows `content` at `size` by the word (or the pointer), or resizes it in place when already shown.
    public func show(_ content: NSView, size: CGSize, word: CGRect?, pointer: CGPoint, visible: CGRect) {
        if popover.contentViewController?.view !== content {
            let controller = NSViewController()
            controller.view = content
            popover.contentViewController = controller
        }
        popover.contentSize = size
        let rect = Self.anchorRect(word: word, pointer: pointer)
        anchor.setFrame(rect, display: false)
        anchor.orderFrontRegardless()
        let edge = Self.edge(word: rect, height: size.height, visible: visible)
        guard let view = anchor.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
    }

    /// The entry's height arrived: the popover keeps its anchor and edge, AppKit moves the body.
    public func resize(height: CGFloat) {
        popover.contentSize = CGSize(width: popover.contentSize.width, height: height)
    }

    public func close() {
        closing = true
        popover.performClose(nil)
        popover.close()
        anchor.orderOut(nil)
        closing = false
    }

    public func popoverDidClose(_ notification: Notification) {
        anchor.orderOut(nil)
        if !closing { onClose?() }
    }
}

/// The popover's anchor: an invisible, non-activating panel at the word, which can be neither key nor main and lets
/// every click through to the reader's app beneath it.
public final class PopoverAnchor: NSPanel {
    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityElement(false)
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}
