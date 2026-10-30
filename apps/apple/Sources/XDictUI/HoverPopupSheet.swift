import AppKit
import SwiftUI
import XDictLibrary
import XDictTokens

/// **The lookup popup's dictionaries and hover's, chosen and ordered where the reader chooses everything else** (owner,
/// 2026-10-29: "鼠标取词 popup 里词典的选择与顺序, 是不是应该在 settings 里有设置啊？"; split in two, owner, 2026-10-30:
/// "hover's own order (default to inherite from dictionary order, and users can change it for popup)" — the popup's list
/// and a hover's own, which until edited follows the dictionaries' order). The window keeps its list and order in the
/// pane behind this sheet; the popup and hover have theirs (`PopupPreferences`), and this is where they are edited.
///
/// **Apple's table, as the pane has** (owner, 2026-10-30: "dictionary list order cannot be drag and changed" — a SwiftUI
/// `List` with `.onMove` reordered by nothing on this macOS): the same `DictionaryTable` the Dictionaries pane uses, so a
/// drag reorders here exactly as it does there, ⌥⌘↑/⌥⌘↓ move and Space ticks.
///
/// Two lists, one meaning each: what the chosen list shows (drag to order, untick to take out) and what it does not. A
/// dictionary unticked stays here, so it is one click to bring back; a new import joins at the end of its library order,
/// and is named here from the first moment.
public struct HoverPopupSheet: View {
    private let library: Library
    private let size: CGSize
    private let done: () -> Void
    /// **Which list is being edited**: hover opens first — it is the one this sheet was asked for.
    @State private var editing: PopupPreferences.List = .hover
    /// Every enabled dictionary: the edited list's own first, in its order, then the rest in the library's.
    @State private var order: [UUID] = []
    /// The ones the edited list shows.
    @State private var ticked: Set<UUID> = []

    public init(library: Library, size: CGSize, done: @escaping () -> Void) {
        self.library = library
        self.size = size
        self.done = done
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Dictionaries in the Lookup Popup and on Hover")
                    .font(Tokens.TextRole.title3.font)
                Picker(selection: $editing) {
                    Text("Hover").tag(PopupPreferences.List.hover)
                    Text("Lookup Popup").tag(PopupPreferences.List.popup)
                } label: {
                    Text("List")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("popupList.picker")
                Text(editing == .hover
                     ? "A hovered word uses these dictionaries, in this order. Until you change them they follow the dictionaries' own order."
                     : "The Lookup Popup shows these, in this order — the shortcut, the Service and the menu. The window keeps its own list in Settings ▸ Dictionaries.")
                    .font(Tokens.TextRole.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], Tokens.Space.l)
            .padding(.bottom, Tokens.Space.sm)
            DictionaryTable(
                rows: rows, selection: .constant(nil), identifier: "popup.list",
                name: String(localized: "Dictionaries"), checkboxName: String(localized: "Show in this list"),
                setEnabled: { id, on in take(id, on: on) },
                move: { dragged, index in move(dragged, to: index) },
                importFiles: nil,
                key: { action, id in if action == .toggle { take(id, on: !ticked.contains(id)) } })
                .frame(maxHeight: .infinity)
                .padding(.horizontal, Tokens.Space.l)
            Divider()
            SheetFooter([FooterAction(.primary, title: Text("Done"), perform: done)], closeOnEscape: done)
                .padding(Tokens.Space.m)
        }
        .frame(width: size.width, height: size.height)
        .onAppear(perform: load)
        .onChange(of: library.entries.map(\.id)) { load() }
        .onChange(of: editing) { load() }
    }

    private var rows: [DictionaryTable.Row] {
        order.compactMap { id in
            library.entries.first { $0.id == id }.map { entry in
                DictionaryTable.Row(id: entry.id, name: entry.displayName,
                                    language: SettingsDictionaries.language(entry.languages.pair, in: .current),
                                    enabled: ticked.contains(id), usable: true)
            }
        }
    }

    /// A tick puts the dictionary in the list (at its place in the order shown); an untick takes it out and leaves it in
    /// the order below.
    private func take(_ id: UUID, on: Bool) {
        if on { ticked.insert(id) } else { ticked.remove(id) }
        save()
    }

    /// A drag of rows, by the pane's own arithmetic: the dragged ids land at `index` among the others, keeping their order.
    private func move(_ dragged: [String], to index: Int) {
        guard let move = SettingsDictionaries.move(dragged: dragged, to: index, in: order) else { return }
        var ids = order
        ids.move(fromOffsets: move.offsets, toOffset: move.destination)
        order = ids
        save()
    }

    private func load() {
        let all = enabled
        let chosen = PopupPreferences.ordered(all, list: editing)
        ticked = Set(chosen)
        order = chosen + all.filter { !ticked.contains($0) }
    }

    private func save() {
        // The stored list is the ticked dictionaries, in the order they are shown.
        PopupPreferences.set(order.filter { ticked.contains($0) }, available: enabled, list: editing)
    }

    private var enabled: [UUID] {
        library.entries.filter(\.enabled).map(\.id)
    }
}
