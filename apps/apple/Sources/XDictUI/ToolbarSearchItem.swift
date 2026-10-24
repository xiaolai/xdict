import SwiftUI
import XDictSearch

/// **The toolbar's search item**: idle and empty, the magnifier is a SwiftUI toolbar button — the same kind as the
/// speaker and the answer pane's toggle (owner, 2026-10-24: the toolbar's icons should all be SwiftUI toolbar buttons).
/// Asking for the field hands the same item to the AppKit editor, which keeps focus, Return, arrows, Escape, the scope
/// menu and the input method (SearchField). A nonempty query never collapses.
struct ToolbarSearchItem: View {
    let text: String
    let prompt: String
    /// The scope menu's lines; none, no menu.
    var scopes: [SearchScopeMenu.Item] = []
    /// A line of the scope menu chosen.
    var onScope: (SearchScope) -> Void = { _ in }
    /// The field takes the keyboard whenever this changes.
    let focus: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    /// ↓ (+1) or ↑ (-1); answers whether it was used.
    let onMove: (Int) -> Bool
    /// Escape; answers whether it was used.
    let onCancel: () -> Bool

    /// The reader asked for the field, and it is not yet closed; a nonempty query keeps it open regardless.
    @State private var editing = false
    /// Each ask is a new keyboard request: the editor takes the keyboard the moment it arrives.
    @State private var asks = 0

    private var expanded: Bool { editing || !text.isEmpty }

    var body: some View {
        Group {
            if expanded {
                SearchField(text: text, prompt: prompt, scopes: scopes, onScope: onScope, focus: focus + asks,
                            onChange: onChange, onSubmit: onSubmit, onMove: onMove, onCancel: onCancel,
                            onEditingEnded: { editing = false })
            } else {
                Button {
                    editing = true
                    asks += 1
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help(Text("Search"))
                .accessibilityIdentifier("toolbar.search")
            }
        }
        // The Search command (⌥⌘F) opens an empty idle field too; its focus change is the ask.
        .onChange(of: focus) { editing = true }
    }
}
