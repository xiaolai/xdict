import AppKit

/// **What the toolbar gives up first at a narrow width** (Apple parity P8, P48): Apple's keeps the search field and
/// sends Back/Forward and the text-size pair to the » overflow. XDict's speaker outlasts both pairs (owner, 2026-10-19:
/// the speaker must not be the item that disappears), the field outlasts everything. SwiftUI's `visibilityPriority` alone
/// did not hold (measured at 400 pt, 2026-10-18), so the bridged `NSToolbar`'s items are set directly.
@MainActor
enum ToolbarPriority {
    /// What a toolbar item holds, as far as its priority goes.
    enum Role: Equatable {
        case searchField
        case speaker
        /// Back/Forward, or the text-size pair: a segmented control.
        case pair
        /// A space or anything else without a view.
        case other
    }

    static func priority(_ role: Role) -> NSToolbarItem.VisibilityPriority {
        switch role {
        case .searchField: .user
        case .speaker: .high
        case .pair, .other: .low
        }
    }

    /// The item's role: the one holding the field, a pair (its view holds a segmented control), else the speaker, the
    /// toolbar's only other item with a view.
    static func role(of item: NSToolbarItem, field: NSView) -> Role {
        guard let view = item.view else { return .other }
        if field.isDescendant(of: view) { return .searchField }
        return holdsSegmentedControl(view) ? .pair : .speaker
    }

    static func apply(_ field: NSView, in toolbar: NSToolbar) {
        let roles = toolbar.items.map { role(of: $0, field: field) }
        // No item found holding the field: change nothing rather than demote the field with the rest.
        guard roles.contains(.searchField) else { return }
        for (item, role) in zip(toolbar.items, roles) {
            let wanted = priority(role)
            if item.visibilityPriority != wanted { item.visibilityPriority = wanted }
        }
    }

    private static func holdsSegmentedControl(_ view: NSView) -> Bool {
        view is NSSegmentedControl || view.subviews.contains(where: holdsSegmentedControl)
    }
}
