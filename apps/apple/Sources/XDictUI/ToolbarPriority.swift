import AppKit

/// **What the toolbar gives up first at a narrow width** (Apple parity P8): Apple's keeps the search field and sends
/// Back/Forward and the text-size pair to the » overflow. SwiftUI's `visibilityPriority` alone did not hold (measured
/// at 400 pt, 2026-10-18), so the bridged `NSToolbar`'s items are set directly: the item
/// holding the search field `.user`, every other `.low`.
@MainActor
enum ToolbarPriority {
    static func priority(holdsSearch: Bool) -> NSToolbarItem.VisibilityPriority { holdsSearch ? .user : .low }

    static func apply(_ field: NSView, in toolbar: NSToolbar) {
        let holding = toolbar.items.map { item in item.view.map { field.isDescendant(of: $0) } ?? false }
        // No item found holding the field: change nothing rather than demote the field with the rest.
        guard holding.contains(true) else { return }
        for (item, holds) in zip(toolbar.items, holding) {
            let wanted = priority(holdsSearch: holds)
            if item.visibilityPriority != wanted { item.visibilityPriority = wanted }
        }
    }
}

