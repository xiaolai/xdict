import AppKit
import SwiftUI
import XDictLibrary
import XDictTokens

/// **The lookup popup's dictionaries, chosen and ordered where the reader chooses everything else** (owner, 2026-10-29:
/// "鼠标取词 popup 里词典的选择与顺序, 是不是应该在 settings 里有设置啊？"; called the Lookup Popup since 2026-10-30 — one
/// list serves both its triggers, hover and the shortcut, and the row's old name said hover only). The window keeps its list and order in the pane
/// behind this sheet; the popover has its own (`HoverPopupPreferences`), and this is where it is edited.
///
/// Two lists, one meaning each: what the popup shows (drag to order, untick to take out) and what it does not. A
/// dictionary unticked stays here, so it is one click to bring back; a new import joins the popup at the end of its
/// library order, and is named here from the first moment.
public struct HoverPopupSheet: View {
    private let library: Library
    private let size: CGSize
    private let done: () -> Void
    /// The popup's dictionaries, in its order.
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
                Text("Dictionaries in the Lookup Popup")
                    .font(Tokens.TextRole.title3.font)
                Text("The popup shows these, in this order, whether hover or the shortcut opened it; the window keeps its own list in Settings ▸ Dictionaries.")
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
                    Text("In the popup")
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
        shown = HoverPopupPreferences.ordered(all)
        hidden = all.filter { !shown.contains($0) }
    }

    private func save() {
        HoverPopupPreferences.set(shown, available: enabled)
    }
}
