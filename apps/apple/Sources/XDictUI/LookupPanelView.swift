import AppKit
import SwiftUI
import XDictAnywhere
import XDictContract
import XDictLibrary
import XDictSearch

/// What the panel shows besides an entry: the selection being read, or why nothing could be looked up.
public enum PanelNotice: Equatable, Sendable {
    case none
    case reading
    case refused(SelectionRefusal)
}

/// **The lookup panel's content** (plan-macos-v1 WI-8): the word, the dictionary whose entry is shown — a pop-up of every
/// result, grouped by dictionary, to read another — "Open in XDict" to expand into the main window, and the entry. Plain
/// macOS: a header bar over the entry, like a Quick Look panel. **The panel never takes the keyboard** (it must not
/// swallow the reader's next keystroke), so everything here is for the pointer; the keyboard has Escape, and the lookup
/// shortcut pressed again, which expands it (`help` says so).
public struct LookupPanelView: View {
    let state: SearchWindowState
    let notice: PanelNotice
    let shortcut: String?
    let expand: () -> Void

    public init(state: SearchWindowState, notice: PanelNotice, shortcut: String?, expand: @escaping () -> Void) {
        self.state = state
        self.notice = notice
        self.shortcut = shortcut
        self.expand = expand
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EntryHost(controller: state.entry)
                .overlay { placeholder }
        }
        .onChange(of: state.model.shown) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        .onChange(of: state.library.searchSources, initial: true) { state.model.sourcesDidChange() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: state.model.lookup?.query ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("panel.query")
            Spacer(minLength: 4)
            ResultPicker(state: state)
            Button(action: expand) {
                Label("Open in XDict", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(state.model.lookup == nil)
            .help(expandHelp)
            .accessibilityIdentifier("panel.expand")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// System Settings › Privacy & Security › Accessibility.
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private var expandHelp: Text {
        if let shortcut { Text("Open in XDict (or press \(shortcut) again)") } else { Text("Open in XDict") }
    }

    @ViewBuilder private var placeholder: some View {
        let model = state.model
        switch notice {
        case .reading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        case .refused(let refusal):
            ContentUnavailableView {
                Label("Nothing to Look Up", systemImage: "text.cursor")
            } description: {
                Text(AnywhereSentences.refusal(refusal))
            } actions: {
                if refusal == .notTrusted {
                    Button("Open Accessibility Settings") { NSWorkspace.shared.open(Self.accessibilityPane) }
                        .accessibilityIdentifier("panel.openAccessibility")
                }
            }
            .background(.background)
            .accessibilityIdentifier("panel.refusal")
        case .none:
            if state.library.entries.isEmpty, state.library.unreadable == nil {
                ContentUnavailableView {
                    Label("No Dictionaries", systemImage: "books.vertical")
                } description: {
                    Text("XDict reads the MDict dictionaries you have. Add them in the Library, then look words up here.")
                }
                .background(.background)
            } else if model.selection == nil, model.isSearching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            } else if model.selection == nil, let lookup = model.lookup {
                ContentUnavailableView {
                    Label {
                        Text("No Results for “\(lookup.query)”")
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                } description: {
                    Text("None of your dictionaries has this word.")
                }
                .background(.background)
            }
        }
    }
}

/// Every result of the panel's lookup, grouped by dictionary, the shown one checked: choosing one shows its entry.
struct ResultPicker: View {
    let state: SearchWindowState

    var body: some View {
        let sections = state.model.sections.compactMap { section -> (ResultSection, [ResultID])? in
            guard case .results(let results) = section.status, !results.hits.isEmpty else { return nil }
            return (section, results.hits.map { ResultID(dictionary: section.id, entry: $0.entry) })
        }
        Picker(selection: Binding(get: { state.model.selection }, set: { state.model.select($0) })) {
            // The dictionary's name with each result, so the closed pop-up names the shown entry's source (R11).
            ForEach(Array(sections.enumerated()), id: \.element.0.id) { index, element in
                if index > 0 { Divider() }
                ForEach(element.1, id: \.self) { id in
                    Text(verbatim: "\(element.0.name) — \(state.model.hit(id)?.headword ?? id.entry.key)")
                        .tag(Optional(id))
                }
            }
        } label: {
            Text("Dictionary")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(sections.isEmpty)
        .help(Text("The entry shown, and every other result"))
        .accessibilityIdentifier("panel.results")
    }
}
