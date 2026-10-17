import AppKit
import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictSearch

/// **The main window** (plan-macos-v1 WI-6): the results in the sidebar, the entry beside them. Plain macOS: a split
/// view, a toolbar with Back, Forward and the original word (I8) on its leading side, the dictionaries a typed word is
/// looked up in in its middle (Q1: the scope is always in sight), the speak button and the search field at its trailing
/// end (M1; owner's choice of 2026-10-17, after Codex's refutation), and the Go, Dictionaries and View menus for the
/// keyboard (`SearchCommands`). The field is the AppKit one, so focus, Return, the arrows and Escape keep their
/// contract; what it suggests shows in the sidebar, which typing reveals when it is collapsed.
public struct SearchWindow: View {
    @Bindable private var state: SearchWindowState
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var width: CGFloat = 1_000

    public init(state: SearchWindowState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SearchSidebar(state: state)
                .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                max: ToolbarLayout.sidebar.max)
        } detail: {
            EntryDetail(state: state)
                .frame(minWidth: ToolbarLayout.detailMinimum)
        }
        .toolbar { toolbar }
        // The headword is shown beside its speaker in the toolbar's leading item; the window's own title says it
        // for the Window menu and VoiceOver (Codex §2).
        .toolbar(removing: .title)
        .navigationTitle(Text(verbatim: ToolbarLayout.windowTitle(headword: state.shownWord)))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusedSceneValue(\.searchWindow, state)
        .onChange(of: state.library.searchSources, initial: true) { state.model.sourcesDidChange() }
        .onChange(of: state.model.shown) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        .onChange(of: state.placeholder) { state.placeholderChanged() }
        // What the reader types shows in the sidebar: typing reveals it (Codex condition 2).
        .onChange(of: state.typed) { if columns == .detailOnly { columns = .all } }
    }

    private var compact: Bool { ToolbarLayout.isCompact(width: width) }

    /// sidebar toggle | Back, Forward, Return | speaker, headword · dictionary | space | scope | search (Codex §2, with
    /// the owner's speaker before the word kept in the title area). Search survives longest, then Back and Forward,
    /// then the scope; Return yields first, and keeps its Go menu command.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.model.back() } label: { Label("Back", systemImage: "chevron.backward") }
                .disabled(!state.model.canGoBack)
                .help(Text("Back"))
            Button { state.model.forward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .disabled(!state.model.canGoForward)
                .help(Text("Forward"))
            if !compact {
                Button { state.model.returnToOrigin() } label: {
                    Label("Return to Original Word", systemImage: "arrow.uturn.backward")
                }
                .disabled(!state.model.canReturnToOrigin)
                .help(Text("Return to the word you typed"))
            }
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .navigation) {
            EntryTitle(state: state)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ScopePicker(state: state, compact: compact)
        }
        ToolbarItem(placement: .primaryAction) {
            SearchField(text: state.model.text, prompt: String(localized: "Look Up"), focus: state.searchFocus,
                        onChange: { state.typedText($0) },
                        onSubmit: { state.submit() }, onMove: { state.move($0) }, onCancel: { state.cancel() })
                .frame(minWidth: ToolbarLayout.searchWidth.min, idealWidth: ToolbarLayout.searchWidth.ideal,
                       maxWidth: ToolbarLayout.searchWidth.max)
        }
        .visibilityPriority(.high)
    }
}

/// **The shown entry, named in the title area**: its speaker (a 28 pt target), 6 pt, the headword it says, then the
/// dictionary it is read from in secondary text — the displayed source, visible with the sidebar hidden (Codex §2, §5).
/// Plain, off the glass: information, not a control group.
struct EntryTitle: View {
    let state: SearchWindowState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PronounceButton(state: state)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            if let word = state.shownWord {
                Text(verbatim: word).font(.headline).lineLimit(1)
                    .accessibilityIdentifier("entry-title")
                if let source = state.shownSourceName {
                    Text(verbatim: source).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("entry-source")
                }
            }
        }
        .fixedSize()
    }
}

/// The speak button (WI-7, R8): the shown entry's word, by the system voice in its dictionary's declared language, as
/// written. Its help says so, and what is worth knowing about the voice that will speak.
struct PronounceButton: View {
    let state: SearchWindowState

    var body: some View {
        Button { state.pronounceShown() } label: { Label("Pronounce", systemImage: "speaker.wave.2") }
            .disabled(!state.canPronounce)
            .help(help)
            .accessibilityIdentifier("pronounce")
    }

    /// What the button does, in one short line that still claims no sense's pronunciation (R8; UI review M-11); a
    /// caveat about the voice belongs to the notice after speaking.
    private var help: Text {
        guard let word = state.shownWord else { return Text("Pronounce") }
        return Text(SpeechSentences.speakHelp(word: word))
    }
}

/// Which dictionaries a typed word is looked up in (Q1, Q2): every enabled one, or one. Always in the toolbar, so the
/// scope is evident without opening anything; below 820 pt a 32 pt book symbol whose tooltip and VoiceOver value name
/// the scope, filled when it is not All Dictionaries (Codex §1).
struct ScopePicker: View {
    let state: SearchWindowState
    var compact = false

    var body: some View {
        if compact {
            Menu {
                picker.pickerStyle(.inline)
            } label: {
                Image(systemName: state.model.scope == .all ? "books.vertical" : "books.vertical.fill")
            }
            .menuIndicator(.hidden)
            .frame(width: 32)
            .disabled(state.model.known.isEmpty)
            .help(Text(scopeName))
            .accessibilityLabel(Text("Dictionaries"))
            .accessibilityValue(Text(scopeName))
            .accessibilityIdentifier("scope")
        } else {
            picker
                .pickerStyle(.menu)
                .frame(minWidth: 110, maxWidth: 180)
                .disabled(state.model.known.isEmpty)
                .accessibilityLabel(Text("Dictionaries"))
                .accessibilityIdentifier("scope")
                .help(Text("The dictionaries a typed word is looked up in"))
        }
    }

    private var scopeName: LocalizedStringResource {
        if case .one(let id) = state.model.scope, let name = state.model.known.first(where: { $0.id == id })?.name {
            return LocalizedStringResource("Look up in \(name)")
        }
        return SearchSentences.allDictionaries
    }

    private var picker: some View {
        Picker(selection: Binding(get: { state.model.scope }, set: { state.model.setScope($0) })) {
            Text(SearchSentences.allDictionaries).tag(SearchScope.all)
            let enabled = state.model.known.filter(\.enabled)
            if !enabled.isEmpty { Divider() }
            ForEach(enabled) { source in
                // One that cannot answer is shown, not offered (UI review M-13).
                Text(verbatim: source.name).tag(SearchScope.one(source.id))
                    .disabled(source.handle == nil)
            }
        } label: {
            Text("Dictionaries")
        }
    }
}

/// The entry pane: the entry view, under a placeholder while there is nothing to read.
struct EntryDetail: View {
    let state: SearchWindowState

    var body: some View {
        EntryHost(controller: state.entry)
            .overlay { placeholder }
            .overlay(alignment: .bottom) { PronunciationBanner(pronunciation: state.pronunciation) }
    }

    @ViewBuilder private var placeholder: some View {
        switch state.placeholder {
        case .noDictionaries:
            ContentUnavailableView {
                Label("No Dictionaries", systemImage: "books.vertical")
            } description: {
                Text("XDict reads the MDict dictionaries you have. Add them, then look words up here.")
            } actions: {
                Button("Add Dictionaries…") {
                    LibraryRequests.shared.requestImport()
                    state.openLibrary?(nil)
                }
                .buttonStyle(.borderedProminent)
                Button("Open Library") { state.openLibrary?(nil) }
            }
            .coversPane()
        case .start:
            ContentUnavailableView {
                Label("Look Up a Word", systemImage: "character.book.closed")
            } description: {
                Text("Type a word and press Return.")
            }
            .coversPane()
        case .noResults(let query):
            ContentUnavailableView.search(text: query).coversPane()
        case .noResultsIncomplete(let query, let unsearched):
            NoResultsIncomplete(query: query, unsearched: unsearched) { state.openLibrary?(nil) }.coversPane()
        case .searching:
            ProgressView().controlSize(.small).coversPane()
        case .none:
            EmptyView()
        }
    }
}

/// The entry view, as AppKit made it, in the SwiftUI window.
struct EntryHost: NSViewControllerRepresentable {
    let controller: EntryViewController

    func makeNSViewController(context: Context) -> EntryViewController { controller }
    func updateNSViewController(_ controller: EntryViewController, context: Context) {}
}

/// The focused main window, for the menus.
public struct SearchWindowKey: FocusedValueKey {
    public typealias Value = SearchWindowState
}

extension FocusedValues {
    public var searchWindow: SearchWindowState? {
        get { self[SearchWindowKey.self] }
        set { self[SearchWindowKey.self] = newValue }
    }
}

/// No result while some dictionaries could not look: said as such, not as an absence (Codex §5).
struct NoResultsIncomplete: View {
    let query: String
    let unsearched: Int
    let openLibrary: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Results in Available Dictionaries", systemImage: "magnifyingglass")
        } description: {
            Text(SearchSentences.noResultsIncomplete(query: query, unsearched: unsearched))
        } actions: {
            Button("Show in Library", action: openLibrary)
        }
        .accessibilityIdentifier("no-results-incomplete")
    }
}
