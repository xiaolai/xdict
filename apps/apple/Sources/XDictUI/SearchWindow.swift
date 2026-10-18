import AppKit
import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictTokens

/// **The main window, as Apple's Dictionary has it** (parity ledger P1–P14; owner's decisions of 2026-10-17): the
/// toolbar holds Back/Forward, the title "XDict" with "N found" under it, the Smaller/Bigger Text pair and the
/// search field at its trailing edge; the scope bar runs under it; the sidebar of matching headwords appears only after
/// a search. The field is the AppKit one, so focus, Return, the arrows and Escape keep their contract. The menus
/// (`SearchCommands`) carry every toolbar command, and XDict's own: Return to Original Word, Pronounce.
public struct SearchWindow: View {
    @Bindable private var state: SearchWindowState
    @State private var columns = NavigationSplitViewVisibility.detailOnly
    /// The content column's width: the title over it yields when it is narrow (P8).
    @State private var column: CGFloat = Tokens.Window.initialColumn
    /// The window's width: the search field follows it (P5). Apple's measured window until the first layout.
    @State private var window: CGFloat = Tokens.Window.searchFieldAtWindow

    public init(state: SearchWindowState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SearchSidebar(state: state)
                // Apple's window has no sidebar button: the sidebar comes with a search (P3, P9).
                .toolbar(removing: .sidebarToggle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                max: ToolbarLayout.sidebar.max)
        } detail: {
            EntryDetail(state: state)
                .frame(minWidth: ToolbarLayout.minimumWindow.width / 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { window = $0 }
        .toolbar { toolbar }
        // Narrow, the title gives way so the search field stays (P8: Apple's slides under the field). Keyed on the content
        // column, not the window: a search's sidebar widened a 400 pt window to 583 pt, past the threshold, and brought
        // the title back over a 400 pt column (UI tour `main.narrow`, 2026-10-18).
        .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
        .navigationTitle(Text(ToolbarLayout.windowTitle))
        .navigationSubtitle(ToolbarLayout.subtitle(found: state.model.found).map { Text($0) } ?? Text(verbatim: ""))
        .focusedSceneValue(\.searchWindow, state)
        .background(TabTitle(title: ToolbarLayout.tabTitle(word: state.shownWord)))
        .onChange(of: state.library.searchSources, initial: true) { state.model.sourcesDidChange() }
        .onChange(of: state.model.shown) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        // The All page grows as each dictionary answers (P15).
        .onChange(of: state.pageResults) { state.pageResultsChanged() }
        .onChange(of: state.placeholder) { state.placeholderChanged() }
        // No sidebar before a search; the first search brings it (P9).
        .onChange(of: state.model.listing != nil, initial: true) { _, listed in
            columns = listed ? .all : .detailOnly
        }
    }

    /// Back/Forward | title | space | Smaller/Bigger Text | search (P3). At the 400 pt minimum the two pairs go to the
    /// overflow before the search field does (P8).
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { state.model.back() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!state.model.canGoBack)
                    .help(Text("Show the previous result"))
                Button { state.model.forward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!state.model.canGoForward)
                    .help(Text("Show the next result"))
            }
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button { state.entry.zoomOut() } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    .help(Text("Decrease font size"))
                Button { state.entry.zoomIn() } label: { Label("Bigger Text", systemImage: "textformat.size.larger") }
                    .help(Text("Increase font size"))
            }
            // One two-segment control, as Apple's (P3), not two round buttons (owner, 2026-10-18): the same style
            // that joins Back and Forward.
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            Button { state.pronounceSelectionOrShown() } label: { Label("Pronounce", systemImage: "speaker.wave.2") }
                .disabled(!state.canPronounce)
                .help(Text("Read the selection aloud, or the entry’s word when nothing is selected"))
                .accessibilityIdentifier("toolbar.pronounce")
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            SearchField(text: state.model.text, prompt: String(localized: "Search"), focus: state.searchFocus,
                        onChange: { state.typedText($0) },
                        onSubmit: { state.submit() }, onMove: { state.move($0) }, onCancel: { state.cancel() })
                // A width that follows the window (P5: 327 pt at 859 pt), not a min/max range: the toolbar sizes a
                // hosted AppKit view by its ideal, and NSSearchField has none, so the range left it near its least
                // (owner, 2026-10-18). At the 400 pt minimum it is 152 pt, so the pairs still overflow first (P8).
                .frame(width: ToolbarLayout.searchFieldWidth(window: window))
        }
        .visibilityPriority(.high)
    }
}

/// The entry pane: the scope bar over the entry view, the page's notices, and a placeholder while there is nothing to
/// read.
struct EntryDetail: View {
    let state: SearchWindowState

    var body: some View {
        VStack(spacing: 0) {
            ScopeBar(state: state)
                .frame(height: ScopeBarLayout.height)
                .background { FindKeys(state: state) }
            PageNotices(state: state)
            EntryHost(controller: state.entry)
                .overlay { placeholder }
                .overlay(alignment: .bottom) { PronunciationBanner(pronunciation: state.pronunciation) }
        }
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
                    SettingsRoute.shared.requestImport()
                }
                .buttonStyle(.borderedProminent)
                Button("Open Dictionary Settings") { state.showDictionaries?(nil) }
            }
            .coversPane()
        case .start:
            StartPage(names: state.model.known.filter(\.enabled).map(\.name)).coversPane()
        case .noResults, .noResultsIncomplete:
            // Which dictionaries could not look is said by the page's notices, above.
            NoEntriesFound().coversPane()
        case .searching:
            Color.clear.coversPane()
        case .none:
            EmptyView()
        }
    }
}

/// **A dictionary that could not search says why, in the page** (P9: Apple's sidebar has no room for it; AGENTS: a
/// file XDict cannot read is never skipped silently): one line each — its name, the sentence, the way on — above the
/// entry, while a search is shown.
struct PageNotices: View {
    let state: SearchWindowState

    var body: some View {
        let troubled = state.model.sections.filter(Self.isTroubled)
        if !troubled.isEmpty {
            notices(troubled)
                // One group with its rule: where the entry below it starts is measured from its bottom.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("page.notices")
        }
    }

    private func notices(_ troubled: [ResultSection]) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                ForEach(troubled) { section in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                        Text(verbatim: section.name).fontWeight(.medium).lineLimit(1)
                        if let sentence = SearchSentences.status(section.status) {
                            ProblemStatus(sentence: sentence, compact: true)
                        }
                        Spacer(minLength: Tokens.Space.xs)
                        if let next = section.next, SearchSentences.isButton(next) {
                            Button(SearchSentences.action(next)) { state.perform(next) }
                                .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("status")
                }
            }
            .font(.callout)
            .padding(.horizontal, Tokens.Inset.entryLeading)
            .padding(.vertical, Tokens.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            Divider()
        }
    }

    /// Unavailable (not merely still opening) or failed.
    static func isTroubled(_ section: ResultSection) -> Bool {
        switch section.status {
        case .unavailable(.indexing): false
        case .unavailable, .failed: true
        default: false
        }
    }
}

/// The speak button (WI-7, R8), in the lookup panel: the shown entry's word, by the system voice in its dictionary's
/// declared language, as written. Its help says so. The main window speaks by Edit ▸ Pronounce (⌥⌘P), its toolbar
/// being Apple's (P3).
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
