import AppKit
import XDictTokens

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
    /// **The frosting, one surface with the arrow** (P41, 2026-10-18): the system's popover material under the whole
    /// popover, arrow included (`hasFullSizeContent`), blending what is behind the window, so the entry's text holds
    /// 4.5:1 over a busy desktop where the bare glass did not, and the arrow is never a second, clearer surface. Active
    /// always: the popover is never key, so following the window's state would draw it inactive, flat.
    let frost: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }()
    /// Told when the popover closed by itself (transient behaviour), not by `close()`.
    public var onClose: (() -> Void)?
    private var closing = false

    override public init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.hasFullSizeContent = true
        popover.delegate = self
    }

    public var isShown: Bool { popover.isShown }
    /// The popover's window frame, arrow and shadow included: what the instruments record.
    public var frame: CGRect? { popover.isShown ? popover.contentViewController?.view.window?.frame : nil }

    /// With full-size content the popover's size includes its arrow and its shadow's margins, 26 pt each way (measured:
    /// a 390 pt content showed a 364 pt body); the body keeps the measured 390 pt, its window 416 as Apple's.
    static let chrome = CGSize(width: Tokens.Control.popoverChrome, height: Tokens.Control.popoverChrome)
    static func outer(_ body: CGSize) -> CGSize { CGSize(width: body.width + chrome.width, height: body.height + chrome.height) }
    /// The body's size: what the reader sees, without the arrow and the shadow's margins.
    public var bodySize: CGSize {
        CGSize(width: popover.contentSize.width - Self.chrome.width, height: popover.contentSize.height - Self.chrome.height)
    }

    /// The anchor: the word, or a point at the pointer when no word could be read.
    public static func anchorRect(word: CGRect?, pointer: CGPoint) -> CGRect {
        word ?? CGRect(origin: pointer, size: Tokens.Size.pointAnchor)
    }

    /// Below the word (AppKit's `minY`, y up), above where the room below is short of the popover and above is larger.
    public static func edge(word: CGRect, height: CGFloat, visible: CGRect) -> NSRectEdge {
        let below = word.minY - visible.minY, above = visible.maxY - word.maxY
        return below >= height || below >= above ? .minY : .maxY
    }

    /// Shows `content` at `size` by the word (or the pointer), or resizes it in place when already shown.
    public func show(_ content: NSView, size: CGSize, word: CGRect?, pointer: CGPoint, visible: CGRect) {
        if content.superview !== frost {
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            frost.addSubview(content)
            let guide = frost.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
            let controller = NSViewController()
            controller.view = frost
            popover.contentViewController = controller
        }
        // The content's own fitting size is none (it fills the frost by constraints): the popover is sized here, its
        // full-size content holding the arrow and the shadow's margins too. Only through `contentSize`: setting the
        // frost's frame by hand as well left it out of step with the popover's size once the popover was reused, and
        // each later showing grew the window by the difference (586, 812, 978, then the whole screen, in the E2E of
        // 2026-10-18), its body at the bottom and the window over the word (`LookupPopoverTests`).
        let outer = Self.outer(size)
        popover.contentViewController?.preferredContentSize = outer
        popover.contentSize = outer
        let rect = Self.anchorRect(word: word, pointer: pointer)
        anchor.setFrame(rect, display: false)
        anchor.orderFrontRegardless()
        let edge = Self.edge(word: rect, height: size.height, visible: visible)
        guard let view = anchor.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
    }

    /// The entry's height arrived: the popover keeps its anchor and edge, AppKit moves the body.
    public func resize(height: CGFloat) {
        let size = CGSize(width: popover.contentSize.width, height: Self.outer(CGSize(width: 0, height: height)).height)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
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
        super.init(contentRect: CGRect(origin: .zero, size: Tokens.Size.pointAnchor), styleMask: [.borderless, .nonactivatingPanel],
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
