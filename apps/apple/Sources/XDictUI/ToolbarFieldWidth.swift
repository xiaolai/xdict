import AppKit

/// **The search field's width, given to the toolbar in a form it keeps following** (P5; owner, 2026-10-19: stretching the
/// window slid the speaker over the field and ran the field past the window's edge). SwiftUI's toolbar measures a hosted
/// item once and keeps that slot: a `.frame(width:)` that changed with the window grew the field inside a slot that did
/// not, centred on it, over its neighbour and out of the window (`ToolbarFitTests`; measured: the slot stayed 267 pt while
/// the field reached 420). The toolbar does follow Auto Layout, so the item holding the field carries one width
/// constraint, P5's width for the window; SwiftUI's `minWidth`/`maxWidth` on the field stay the bounds.
///
/// **One per window, kept by the window, watching the window** (verifier, 2026-10-19): a watcher on the field itself
/// went away when a jump to a much narrower window sent the field to the overflow, and the width it left behind kept the
/// field there. This one lives as long as its window and follows every resize whether the field is shown or not; it also
/// sets which items the toolbar gives up first (`ToolbarPriority`) and names them (`ToolbarLabels`).
///
/// A full-screen window's toolbar lives in a window of its own, with no toolbar of its own: the field arriving there
/// changes nothing, and the main window's watcher goes on following the main window (not checked offscreen: only a window
/// on screen goes full screen).
@MainActor
final class ToolbarFieldWidth: NSObject {
    static let identifier = "xdict.toolbar.searchFieldWidth"
    /// Above `fittingSizeCompression`, which the toolbar sizes its items by (below it the field stayed at its least,
    /// measured); below required, so SwiftUI's bounds on the field win, and below the window's own drag, so the
    /// preferred width never holds the window open.
    static let priority = NSLayoutConstraint.Priority.dragThatCannotResizeWindow
    /// **The expand/collapse animation** (owner, 2026-10-24: 200 ms): the item's width moves over this, the field's
    /// frame following it inside the item.
    static let expandDuration: TimeInterval = 0.2

    private weak var field: NSView?
    private weak var window: NSWindow?
    /// The item's view, which this watcher last widened, so a collapse can give the item its natural width back.
    private weak var itemView: NSView?

    private init(field: NSView, window: NSWindow) {
        self.field = field
        self.window = window
        super.init()
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
        }
    }

    /// The field arrived in a window (first, and again each time it comes back from the overflow). A window with a
    /// toolbar gets its one watcher, kept by the window and released with it; a window without one changes nothing.
    static func attach(_ field: NSView) {
        guard let window = field.window, window.toolbar != nil else { return }
        let fit = watcher(of: window) ?? ToolbarFieldWidth(field: field, window: window)
        fit.field = field
        objc_setAssociatedObject(window, &key, fit, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        fit.update()
    }

    /// The window's watcher, if it has one.
    static func watcher(of window: NSWindow) -> ToolbarFieldWidth? {
        objc_getAssociatedObject(window, &key) as? ToolbarFieldWidth
    }

    nonisolated(unsafe) private static var key: UInt8 = 0

    @objc private func windowChanged(_ notification: Notification) {
        update()
    }

    /// The item holding the field gets the window's width for it, whether the field is shown or in the overflow.
    /// Collapsed, the field has left the toolbar and its item is the SwiftUI button again: the item takes itself back
    /// to its natural width.
    func update() {
        guard let field, let window, let toolbar = window.toolbar else { return }
        ToolbarPriority.apply(field, in: toolbar)
        ToolbarLabels.apply(field, in: toolbar)
        guard let item = toolbar.items.lazy.compactMap(\.view).first(where: { field.isDescendant(of: $0) }) else { return }
        itemView = item
        guard (field as? KeyboardSearchField)?.searchControl?.expanded == true else {
            releaseWidth()
            return
        }
        widen(item, to: ToolbarLayout.searchFieldWidth(window: window.frame.width))
    }

    /// The editor was removed from its item: deactivate the width it asked for so the button sizes naturally.
    static func release(_ field: NSView) {
        guard let window = field.window, let watcher = watcher(of: window) else { return }
        watcher.releaseWidth()
    }

    private func releaseWidth() {
        guard let itemView else { return }
        for constraint in itemView.constraints where constraint.identifier == Self.identifier && constraint.isActive {
            constraint.isActive = false
        }
        self.itemView = nil
    }

    /// The item view's preferred width, set (or restored) over `expandDuration` (owner, 2026-10-24).
    private func widen(_ itemView: NSView, to width: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.expandDuration
            context.allowsImplicitAnimation = true
            if let preferred = itemView.constraints.first(where: { $0.identifier == Self.identifier }) {
                preferred.constant = width
                if !preferred.isActive { preferred.isActive = true }
            } else {
                let preferred = itemView.widthAnchor.constraint(equalToConstant: width)
                preferred.priority = Self.priority
                preferred.identifier = Self.identifier
                preferred.isActive = true
            }
            itemView.superview?.layoutSubtreeIfNeeded()
        }
    }
}
