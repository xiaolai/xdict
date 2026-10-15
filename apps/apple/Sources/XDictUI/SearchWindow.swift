import AppKit
import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictSearch

/// **The main window** (plan-macos-v1 WI-6): the search field and the results in the sidebar, the entry beside them.
/// Plain macOS: a split view, a toolbar with Back, Forward and the original word (I8) on its leading side and the
/// dictionaries a typed word is looked up in in its middle (Q1: the scope is always in sight), and the Go, Dictionaries
/// and View menus for the keyboard (`SearchCommands`).
public struct SearchWindow: View {
    @Bindable private var state: SearchWindowState

    public init(state: SearchWindowState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView {
            SearchSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
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
                Text(verbatim: source.name).tag(SearchScope.one(source.id))
            }
        } label: {
            Text("Dictionaries")
        }
        .pickerStyle(.menu)
        .fixedSize()
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
    }

    @ViewBuilder private var placeholder: some View {
        let model = state.model
        if state.library.entries.isEmpty, state.library.unreadable == nil {
            ContentUnavailableView {
                Label("No Dictionaries", systemImage: "books.vertical")
            } description: {
                Text("XDict reads the MDict dictionaries you have. Add them in the Library, then look words up here.")
            } actions: {
                Button("Open Library") { state.openLibrary?(nil) }
            }
            .background(.background)
        } else if model.lookup == nil {
            ContentUnavailableView {
                Label("Look Up a Word", systemImage: "character.book.closed")
            } description: {
                Text("Type a word and press Return.")
            }
            .background(.background)
        } else if model.selection == nil, !model.isSearching, let lookup = model.lookup {
            ContentUnavailableView {
                Label {
                    Text("No Results for “\(lookup.query)”")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            } description: {
                Text("The list beside says what each dictionary found, or why it could not look.")
            }
            .background(.background)
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
