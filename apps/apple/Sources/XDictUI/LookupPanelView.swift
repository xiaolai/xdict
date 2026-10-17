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
    let openLibrary: () -> Void

    public init(state: SearchWindowState, notice: PanelNotice, shortcut: String?, expand: @escaping () -> Void,
                openLibrary: @escaping () -> Void = {}) {
        self.state = state
        self.notice = notice
        self.shortcut = shortcut
        self.expand = expand
        self.openLibrary = openLibrary
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
        .onChange(of: state.placeholder) { state.placeholderChanged() }
    }

    /// The header's least height (Codex §3): one row, growing with its controls' own metrics.
    public static let headerHeight: CGFloat = 36

    /// One row: close (the panel's own) | speaker | headword | source | Open in XDict (Codex §3; P-04, P-05).
    private var header: some View {
        HStack(spacing: 6) {
            // The speaker first, then the word it says, as in the main window (owner, 2026-10-17).
            PronounceButton(state: state)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            Text(verbatim: state.shownWord ?? state.model.lookup?.query ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("panel.query")
            Spacer(minLength: 4)
            if state.model.sections.contains(where: { if case .results(let r) = $0.status { !r.hits.isEmpty } else { false } }) {
                ResultPicker(state: state)
                    .controlSize(.small)
            }
            Button("Open in XDict", action: expand)
                .controlSize(.small)
                .disabled(state.model.lookup == nil)
                .help(expandHelp)
                .accessibilityIdentifier("panel.expand")
        }
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .frame(minHeight: Self.headerHeight)
    }

    /// System Settings › Privacy & Security › Accessibility.
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private var expandHelp: Text {
        if let shortcut { Text("Open in XDict (or press \(shortcut) again)") } else { Text("Open in XDict") }
    }

    @ViewBuilder private var placeholder: some View {
        switch notice {
        case .reading:
            ProgressView().controlSize(.small).coversPane()
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
            .coversPane()
            .accessibilityIdentifier("panel.refusal")
        case .none:
            switch state.placeholder {
            case .noDictionaries:
                ContentUnavailableView {
                    Label("No Dictionaries", systemImage: "books.vertical")
                } description: {
                    Text("XDict reads the MDict dictionaries you have. Add them, then look words up here.")
                } actions: {
                    Button("Open Library") { openLibrary() }
                }
                .coversPane()
            case .searching:
                ProgressView().controlSize(.small).coversPane()
            case .noResults(let query):
                ContentUnavailableView.search(text: query).coversPane()
            case .noResultsIncomplete(let query, let unsearched):
                NoResultsIncomplete(query: query, unsearched: unsearched, openLibrary: openLibrary).coversPane()
            case .start, .none:
                EmptyView()
            }
        }
    }
}

/// Every result of the panel's lookup, grouped by dictionary, the shown one checked: choosing one shows its entry.
/// Closed, it names only the dictionary read from, 80–140 pt, truncated: the headword is beside it (Codex §3).
struct ResultPicker: View {
    let state: SearchWindowState

    var body: some View {
        let sections = state.model.sections.compactMap { section -> (ResultSection, [ResultID])? in
            guard case .results(let results) = section.status, !results.hits.isEmpty else { return nil }
            return (section, results.hits.map { ResultID(dictionary: section.id, entry: $0.entry) })
        }
        Menu {
            Picker(selection: Binding(get: { state.model.selection }, set: { state.model.select($0) })) {
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
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: state.shownSourceName ?? "").lineLimit(1).truncationMode(.tail)
        }
        .frame(minWidth: 80, maxWidth: 140)
        .help(Text("The entry shown, and every other result"))
        .accessibilityIdentifier("panel.results")
    }
}
