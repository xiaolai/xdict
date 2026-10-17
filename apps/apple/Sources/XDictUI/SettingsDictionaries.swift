import SwiftUI
import XDictEntryView
import XDictLibrary

/// **Settings ▸ Dictionaries, as Apple's Dictionary draws it** (parity ledger P39, P40; owner, 2026-10-17: follow
/// Apple). Apple's line "Drag reference sources into the order you prefer:", a bordered table with alternating rows —
/// a checkbox, the dictionary's full name and its languages, 20 pt rows — and under it, in a box, the selected
/// dictionary's own options. MDX dictionaries carry no preferences of their own (Apple's come from the dictionary's
/// `DCSDictionaryPrefsHTML`), so the box holds XDict's per-dictionary option, Original style, and a way to the
/// Library, where adding, removing, health and the style report (ADR-0010) stay.
public struct SettingsDictionaries: View {
    /// Apple's Settings window: 600 pt wide; its table's rows 20 pt (settings.ax.json, 2026-10-17).
    nonisolated public static let paneWidth: CGFloat = 600
    nonisolated public static let rowHeight: CGFloat = 20

    nonisolated public static let instruction = LocalizedStringResource("Drag reference sources into the order you prefer:")
    nonisolated public static let tableName = LocalizedStringResource("Dictionaries")
    nonisolated public static let noSelection = LocalizedStringResource("Select a dictionary to see its options.")
    nonisolated public static let showInLibrary = LocalizedStringResource("Show in Library…")

    @Bindable private var library: Library
    @State private var selection: UUID?
    private let openLibrary: () -> Void

    public init(library: Library, openLibrary: @escaping () -> Void) {
        self.library = library
        self.openLibrary = openLibrary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.instruction)
            table
            options
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: Self.paneWidth, height: 340)
    }

    /// An AppKit table, as Apple's is: SwiftUI's `Table` is an outline to Accessibility and its rows are 24 pt
    /// (the tour's capture of 2026-10-17), where Apple's are an AXTable's, 20 pt.
    private var table: some View {
        let rows = library.entries.map { entry in
            DictionaryTable.Row(id: entry.id, name: entry.displayName,
                                language: Self.language(entry.languages.pair, in: .current), enabled: entry.enabled,
                                // Not offered where it cannot work (UI review L-08).
                                usable: !(library.phases[entry.id].map(LibraryRow.isTrouble) ?? false))
        }
        return DictionaryTable(
            rows: rows, selection: $selection,
            name: String(localized: Self.tableName), checkboxName: String(localized: "Use in lookups"),
            setEnabled: { library.setEnabled($0, $1) },
            move: { dragged, index in
                if let move = Self.move(dragged: dragged, to: index, in: library.entries.map(\.id)) {
                    library.move(fromOffsets: move.offsets, toOffset: move.destination)
                }
            })
    }

    /// The box under the table: the selected dictionary's own options, as Apple's slot shows a dictionary's.
    private var options: some View {
        Group {
            if let id = selection, let entry = library.entries.first(where: { $0.id == id }) {
                DictionaryOptions(entry: entry, openLibrary: openLibrary).id(entry.preferencesKey)
            } else {
                Text(Self.noSelection).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
        .overlay { Rectangle().strokeBorder(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.dictionaryOptions")
    }

    /// The language column: one language once, two as "search-explanation", empty when neither is known.
    nonisolated public static func language(_ pair: LanguagePair, in locale: Locale) -> String {
        let names = [pair.search, pair.explanation].compactMap { $0 }
            .map { locale.localizedString(forIdentifier: $0) ?? $0 }
        guard let first = names.first else { return "" }
        return names.dropFirst().allSatisfy { $0 == first } ? first : names.joined(separator: "-")
    }

    /// Rows dragged (as their ids) onto `index`, in the library's own terms; nil when none of them is in the list.
    nonisolated public static func move(dragged: [String], to index: Int, in ids: [UUID])
        -> (offsets: IndexSet, destination: Int)? {
        let offsets = IndexSet(dragged.compactMap(UUID.init(uuidString:)).compactMap { ids.firstIndex(of: $0) })
        return offsets.isEmpty ? nil : (offsets, index)
    }
}

/// The selected dictionary's options: Original style, and the way to its full details in the Library.
private struct DictionaryOptions: View {
    @AppStorage private var originalStyle: Bool
    let entry: LibraryEntry
    let openLibrary: () -> Void

    init(entry: LibraryEntry, openLibrary: @escaping () -> Void) {
        self.entry = entry
        self.openLibrary = openLibrary
        _originalStyle = AppStorage(wrappedValue: false, EntryPreferences.originalStyleKey(entry.preferencesKey))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: $originalStyle) { Text("Original style") }
                .toggleStyle(.checkbox)
                .help(Text("Show this dictionary's entries as its own stylesheets draw them, instead of in XDict's reading style. Links and protections are the same either way."))
                .accessibilityIdentifier("original-style")
            Spacer()
            Button(action: openLibrary) { Text(SettingsDictionaries.showInLibrary) }
        }
    }
}
