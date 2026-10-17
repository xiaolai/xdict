import AppKit

/// **What the toolbar gives up first at a narrow width** (Apple parity P8): Apple's keeps the search field and sends
/// Back/Forward and the text-size pair to the » overflow. SwiftUI's `visibilityPriority` alone did not hold (measured
/// at 400 pt, 2026-10-18), so the bridged `NSToolbar`'s items are set directly: the item
/// holding the search field `.user`, every other `.low`.
@MainActor
enum ToolbarPriority {
    static func priority(holdsSearch: Bool) -> NSToolbarItem.VisibilityPriority { holdsSearch ? .user : .low }

    static func apply(_ field: NSView) {
        guard let toolbar = field.window?.toolbar else { return }
        let holding = toolbar.items.map { item in item.view.map { field.isDescendant(of: $0) } ?? false }
        // No item found holding the field: change nothing rather than demote the field with the rest.
        guard holding.contains(true) else { return }
        for (item, holds) in zip(toolbar.items, holding) {
            let wanted = priority(holdsSearch: holds)
            if item.visibilityPriority != wanted { item.visibilityPriority = wanted }
        }
    }
}

/// **Narrow, the title and its count give way** (Apple parity P8): Apple's slide under the search field when the
/// content column is narrow. `.toolbar(removing: .title)` keyed on the window's width hid the title at 400 pt before a
/// search, but the search's sidebar widened the window to 583 pt, past the 560 pt threshold, so the title and "N found"
/// came back over a 400 pt column (UI tour `main.narrow`, 2026-10-18). The column's width is the window's less the
/// sidebar's, read here at each resize and each change of the split.
@MainActor
enum WindowTitle {
    static func apply(_ window: NSWindow) {
        let wanted: NSWindow.TitleVisibility = ToolbarLayout.titleYields(window: window.frame.width,
                                                                          sidebar: sidebarWidth(window)) ? .hidden : .visible
        if window.titleVisibility != wanted { window.titleVisibility = wanted }
    }

    /// The width of the window's sidebar while it shows: the first pane of its split view, 0 without one.
    static func sidebarWidth(_ window: NSWindow) -> CGFloat {
        guard let split = splitView(in: window.contentView), let first = split.arrangedSubviews.first,
              split.arrangedSubviews.count > 1, !split.isSubviewCollapsed(first), !first.isHidden else { return 0 }
        return first.frame.width
    }

    private static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.isVertical { return split }
        for child in view.subviews { if let found = splitView(in: child) { return found } }
        return nil
    }
}
