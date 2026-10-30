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
/// Two lists, one meaning each: what the chosen list shows (drag to order, untick to take out) and what it does not. A
/// dictionary unticked stays here, so it is one click to bring back; a new import joins at the end of its library order,
/// and is named here from the first moment.
public struct HoverPopupSheet: View {
    private let library: Library
    private let size: CGSize
    private let done: () -> Void
    /// **Which list is being edited**: hover opens first — it is the one this sheet was asked for.
    @State private var editing: PopupPreferences.List = .hover
    /// The chosen list's dictionaries, in its order.
    @State private var shown: [UUID] = []
    /// The rest of the library's enabled dictionaries, in the library's order.
    @State private var hidden: [UUID] = []

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
            List {
                Section {
                    ForEach(shown, id: \.self) { id in
                        row(id, inPopup: true)
                    }
                    .onMove { from, to in
                        shown.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                } header: {
                    Text("Shown")
                }
                if !hidden.isEmpty {
                    Section {
                        ForEach(hidden, id: \.self) { id in
                            row(id, inPopup: false)
                        }
                    } header: {
                        Text("Not shown")
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            Divider()
            SheetFooter([FooterAction(.primary, title: Text("Done"), perform: done)], closeOnEscape: done)
                .padding(Tokens.Space.m)
        }
        .frame(width: size.width, height: size.height)
        .onAppear(perform: load)
        .onChange(of: library.entries.map(\.id)) { load() }
        .onChange(of: editing) { load() }
    }

    /// One dictionary: a tick for whether the popup shows it, its name for what it is.
    private func row(_ id: UUID, inPopup: Bool) -> some View {
        Toggle(isOn: Binding(get: { inPopup }, set: { on in take(id, on: on) })) {
            Text(verbatim: name(of: id))
        }
        .accessibilityIdentifier("hoverPopup.\(id.uuidString)")
    }

    /// A tick adds the dictionary at the end of the popup's order; an untick takes it out and leaves it in the list below.
    private func take(_ id: UUID, on: Bool) {
        if on {
            guard !shown.contains(id) else { return }
            shown.append(id)
            hidden.removeAll { $0 == id }
        } else {
            shown.removeAll { $0 == id }
            guard !hidden.contains(id) else { return }
            hidden = enabled.filter { $0 == id || hidden.contains($0) }
        }
        save()
    }

    private var enabled: [UUID] {
        library.entries.filter(\.enabled).map(\.id)
    }

    private func name(of id: UUID) -> String {
        library.entries.first { $0.id == id }?.displayName ?? ""
    }

    private func load() {
        let all = enabled
        shown = PopupPreferences.ordered(all, list: editing)
        hidden = all.filter { !shown.contains($0) }
    }

    private func save() {
        PopupPreferences.set(shown, available: enabled, list: editing)
    }
}
