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

    public init(state: SearchWindowState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SearchSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
                // The search field in the toolbar over the sidebar, beside what it suggests and finds: room for it at
                // every width, the detail's toolbar left to the title, the scope and Pronounce.
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        SearchField(text: state.model.text, prompt: String(localized: "Look Up"),
                                    focus: state.searchFocus, onChange: { state.typedText($0) },
                                    onSubmit: { state.submit() }, onMove: { state.move($0) },
                                    onCancel: { state.cancel() })
                            .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
                    }
                }
        } detail: {
            EntryDetail(state: state)
        }
        .toolbar { toolbar }
        .navigationTitle(Text(verbatim: state.model.lookup?.query ?? "XDict"))
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.model.back() } label: { Label("Back", systemImage: "chevron.backward") }
                .disabled(!state.model.canGoBack)
                .help(Text("Back"))
            Button { state.model.forward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .disabled(!state.model.canGoForward)
                .help(Text("Forward"))
            Button { state.model.returnToOrigin() } label: {
                Label("Return to Original Word", systemImage: "arrow.uturn.backward")
            }
            .disabled(!state.model.canReturnToOrigin)
            .help(Text("Return to the word you typed"))
        }
        ToolbarItem(placement: .principal) {
            ScopePicker(state: state)
        }
        ToolbarItem(placement: .primaryAction) {
            PronounceButton(state: state)
        }

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
/// scope is evident without opening anything.
struct ScopePicker: View {
    let state: SearchWindowState

    var body: some View {
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
        .pickerStyle(.menu)
        // Readable beside the field at the minimum width, a long name truncated rather than pushing search out.
        .frame(minWidth: 110, maxWidth: 180)
        .background(ToolbarPriorityProbe())
        .disabled(state.model.known.isEmpty)
        .accessibilityLabel(Text("Dictionaries"))
        .accessibilityIdentifier("scope")
        .help(Text("The dictionaries a typed word is looked up in"))
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
