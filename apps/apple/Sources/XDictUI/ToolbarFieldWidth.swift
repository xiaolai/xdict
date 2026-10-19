import AppKit

/// **The search field's width, given to the toolbar in a form it keeps following** (P5; owner, 2026-10-19: stretching the
/// window slid the speaker over the field and ran the field past the window's edge). SwiftUI's toolbar measures a hosted
/// item once and keeps that slot: a `.frame(width:)` that changed with the window grew the field inside a slot that did
/// not, centred on it, over its neighbour and out of the window (`ToolbarFitTests`; measured: the slot stayed 267 pt while
/// the field reached 420). The toolbar does follow Auto Layout, so the item holding the field carries one width
/// constraint, P5's width for the window, below required: SwiftUI's `minWidth`/`maxWidth` on the field stay the bounds,
/// and the toolbar gives way below the preferred width before it overlaps anything.
@MainActor
enum ToolbarFieldWidth {
    static let identifier = "xdict.toolbar.searchFieldWidth"
    /// Above the hosting view's own content size (hugging and compression at `.defaultLow`), below what AppKit's toolbar
    /// holds its items with, so the preferred width gives way when the toolbar needs the room.
    static let priority = NSLayoutConstraint.Priority.dragThatCannotResizeWindow

    static func apply(_ field: NSView) {
        guard let window = field.window, let toolbar = window.toolbar,
              let item = toolbar.items.lazy.compactMap(\.view).first(where: { field.isDescendant(of: $0) })
        else { return }
        let width = ToolbarLayout.searchFieldWidth(window: window.frame.width)
        if let preferred = item.constraints.first(where: { $0.identifier == identifier }) {
            if preferred.constant != width { preferred.constant = width }
            return
        }
        let preferred = item.widthAnchor.constraint(equalToConstant: width)
        preferred.priority = priority
        preferred.identifier = identifier
        preferred.isActive = true
    }
}
