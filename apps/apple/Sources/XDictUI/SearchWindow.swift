import AppKit
import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictTokens

/// **The main window, as Apple's Dictionary has it** (parity ledger P1–P14; owner's decisions of 2026-10-17, with the
/// 2026-10-24 changes): the toolbar holds Back/Forward, the title "XDict" with "N found" under it and the search field;
/// the text-size pair and the answer pane's toggle left it (View menu and ⌘I). The sidebar of matching headwords
/// appears only after a search. **The search field is SwiftUI's `.searchable`**: the system places it at the trailing
/// end, collapses it in a narrow window, and draws its focus ring; its scopes (P6, P7) are the picker below the
/// toolbar. The answer pane is its own window beside this one. The menus (`SearchCommands`) carry every toolbar
/// command, and XDict's own: Return to Original Word, Pronounce.
public struct SearchWindow: View {
    @Bindable private var state: SearchWindowState
    /// The content column's width: the title over it yields when it is narrow (P8).
    @State private var column: CGFloat = Tokens.Window.initialColumn
    /// The native window grows before the inspector opens; no reading space is taken for the answer.
    @State private var presentation: MeaningPlacement = .hidden
    /// **The pane's width, observed, not read once** (owner, 2026-10-24): `@AppStorage` so a change in Settings reaches
    /// an open window, and the stored value held to the range before it becomes geometry.
    @AppStorage(MeaningPanePreferences.widthKey) private var paneWidthStored = MeaningPanePreferences.defaultWidth
    /// **SwiftUI's own search field** (owner, 2026-10-24: try `.searchable`): the system draws and focuses it.
    @FocusState private var searchFocused: Bool

    public init(state: SearchWindowState) {
        self.state = state
    }

    /// Two expressions, not one (audit follow-up, 2026-10-20): the whole chain in a single body exceeded the compiler's
    /// type-check time. The split view is `pane`; `body` adds the meaning session's watchers.
    public var body: some View {
        pane
            // **Open on the reader's action, not on every state change**: an answer arriving after the reader closed the
            // pane must not reopen it. The first transition out of idle is the action's; a preview always opens.
            .onChange(of: state.meaning.state) { old, new in
                if old == .idle { state.panes.meaningAsked() }
                if case .preview = new { state.panes.meaningAsked() }
            }
            // A lookup the reader typed or followed replaces the presentation: its captured sentence is dropped.
            .onChange(of: state.model.lookup) { state.lookupDidChange() }
            // The chosen sense is marked in its frame, and unmarked when the choice goes (UI21).
            .onChange(of: state.meaning.selection) { state.markSelection() }
            .onDisappear { state.clearMeaning() }
    }

    /// **The pane in a sheet** (a screen with no room beside the window): its own question tabs, because a sheet has no
    /// toolbar to hold the pane window's (audit 2026-10-27), and Done closes it.
    private var paneSheet: some View {
        let done = {
            state.panes.meaningClosed(by: .sheet, current: .sheet)
            state.panes.examplesClosed()
        }
        return VStack(spacing: 0) {
            MeaningAnswerPane(state: state, showsHeader: true, tabs: true)
            Divider()
            SheetFooter([FooterAction(.primary, title: Text("Done"), perform: done)], closeOnEscape: done)
                .padding(Tokens.Space.m)
        }
        .frame(width: Tokens.Window.meaningPaneIdeal, height: Tokens.Window.meaningSheetHeight)
    }

    private var pane: some View {
        // The answer opens outside the existing reading area; a screen with no room uses the sheet.
        let listed = state.model.listing != nil
        let shown = presentation
        return NavigationSplitView(columnVisibility: columns(listed: listed)) {
            SearchSidebar(state: state)
                // Apple's window has no sidebar button: the sidebar comes with a search (P3, P9).
                .toolbar(removing: .sidebarToggle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                max: ToolbarLayout.sidebar.max)
        } detail: {
            // The entry claims none of the window's least: it takes what the panes leave. Its content's own
            // ideal — the meaning row's controls on one line — held a 400 pt window at over 1000 pt (measured,
            // `MeaningPaneFitTests`).
            EntryDetail(state: state)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
        }
        // **The answer in a sheet** where the pane does not fit beside the entry and the list the reader shows: the
        // pane's own scrolling body over Done (R3), Escape closing it too. Modal, so the window's search is back after
        // Done.
        .sheet(isPresented: paneShown(in: .sheet, now: shown)) { paneSheet }
        .toolbar { toolbar }
        // Narrow, the title gives way so the search field stays (P8: Apple's slides under the field). Keyed on the content
        // column, not the window: a search's sidebar widened a 400 pt window to 583 pt, past the threshold, and brought
        // the title back over a 400 pt column (UI tour `main.narrow`, 2026-10-18).
        .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
        // A window is titled by the word it shows (UI08): Mission Control and the Window menu tell windows apart.
        .navigationTitle(Text(verbatim: ToolbarLayout.windowTitle(word: state.shownWord)))
        .navigationSubtitle(ToolbarLayout.subtitle(found: state.model.found).map { Text($0) } ?? Text(verbatim: ""))
        // **The search field, SwiftUI's** (owner, 2026-10-24): the system's toolbar search field, its own focus ring.
        .searchable(text: searchText, placement: .toolbar, prompt: Text(verbatim: searchPrompt))
        // **Scopes, SwiftUI's way**: the only scope UI `.searchable` has — a picker below the field, not the
        // magnifier's menu (P6); with 24 dictionaries it is the experiment, not the design yet.
        .searchScopes(searchScope) {
            Text(verbatim: String(localized: SearchSentences.allDictionaries)).tag(SearchScope.all)
            ForEach(state.model.known.filter(\.enabled)) { source in
                Text(verbatim: source.name).tag(SearchScope.one(source.id))
            }
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { state.submit() }
        .onChange(of: state.searchFocus) { searchFocused = true }
        .focusedSceneValue(\.searchWindow, state)
        .background(TabTitle(title: ToolbarLayout.tabTitle(word: state.shownWord)))
        .onChange(of: state.library.searchSources, initial: true) {
            state.model.sourcesDidChange()
            state.lookupDidChange()
            // The place may have arrived before the dictionaries could answer for it.
            state.placeCanBeDrawn()
        }
        // The examples section (ADR-0031): opens when a Chinese query's pairs arrive, and asks again when a
        // dictionary's store finishes building. The revision, not `hasContent`: two queries that both found pairs
        // leave `hasContent` true, and the second one's section must still open (audit, 2026-10-24).
        .onChange(of: state.examples.revision) { state.examplesContentChanged() }
        .onChange(of: state.library.examples) { state.examplesLibraryChanged() }
        // **The entry the model already shows is drawn when the window appears** (owner, 2026-10-26: the captured word
        // was in the search field and the window stayed blank): a window the expansion made receives its adopted place
        // — query, scope and entry — before its view exists, so a change-only observer never saw the entry and the
        // reading column drew nothing. `initial` draws what is already shown at mount.
        .onChange(of: state.model.shown, initial: true) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        // The All page grows as each dictionary answers (P15).
        .onChange(of: state.pageResults) { state.pageResultsChanged() }
        .onChange(of: state.placeholder) { state.placeholderChanged() }
        // **The answer pane is its own window** (owner, 2026-10-24): full height, its toggle at its top-left, beside
        // the main window — which keeps its frame, its reading width and SwiftUI's `.searchable` at its own trailing
        // edge. A screen with no room beside it uses the sheet below.
        .background(MeaningPaneWindow(shown: state.panes.meaningShown || state.panes.examplesShown,
                                      width: paneWidth, presentation: $presentation, state: state))
    }

    /// **The results list, as the reader left it** (P9; HIG audit UI07): none before a search, the first search brings
    /// it, and a reader who hid it keeps it hidden across searches until View ▸ Show Results. Nothing else shows or
    /// hides it.
    private func columns(listed: Bool) -> Binding<NavigationSplitViewVisibility> {
        Binding {
            state.panes.resultsVisible(listed: listed) ? .all : .detailOnly
        } set: { visibility in
            state.panes.setResults(visible: visibility != .detailOnly, listed: listed)
        }
    }

    /// The right pane in one of its presentations: opened by an ask, by a Chinese query's examples, by View ▸ Show
    /// Meaning in Context and by the toolbar's toggle; closed by the reader (UI02, UI05). A dismissal is weighed
    /// against where the pane is shown when it arrives, so the one a resize just left does not close it.
    private func paneShown(in place: MeaningPlacement, now: MeaningPlacement) -> Binding<Bool> {
        Binding { now == place } set: { shown in
            guard !shown, presentation == place else { return }
            state.panes.meaningClosed(by: place, current: presentation)
            state.panes.examplesClosed()
        }
    }

    /// The window's one shared toolbar (P3, `SearchToolbar`), wired to this window's entry and speaker. **The answer
    /// pane's toggle left the toolbar** (owner, 2026-10-24): ⌘I (View ▸ Show/Hide Meaning in Context) toggles it, and an
    /// open pane carries the same toggle at its own top-left. The search field is SwiftUI's `.searchable`, placed by the
    /// system.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let window = state
        SearchToolbar(canGoBack: state.model.canGoBack, canGoForward: state.model.canGoForward,
                      canPronounce: state.canPronounce, back: { state.model.back() },
                      forward: { state.model.forward() }, pronounce: { state.pronounceSelectionOrShown() },
                      explore: window.explore, exploreWord: { window.exploreWord }, exploreDicts: { window.exploreDicts },
                      exploreOpen: { window.openExplored($0) })
    }

    /// The pane's width now, clamped: Settings may hold any number, geometry takes only these.
    private var paneWidth: CGFloat {
        CGFloat(MeaningPanePreferences.clamped(paneWidthStored, in: MeaningPanePreferences.widthRange,
                                               fallback: MeaningPanePreferences.defaultWidth))
    }

    /// The searchable field's text, through the window's typing path (a search starts as the reader types).
    private var searchText: Binding<String> {
        Binding { state.model.text } set: { state.typedText($0) }
    }

    /// The searchable field's scope, through the model's scope (P6, P7).
    private var searchScope: Binding<SearchScope> {
        Binding { state.model.scope } set: {
            state.model.setScope($0)
        }
    }

    /// Its placeholder: "Search", or "Search in <name>" for the chosen scope (P6).
    private var searchPrompt: String {
        String(localized: SearchScopeMenu.prompt(known: state.model.known, scope: state.model.scope))
    }

}

/// The entry pane: the page's notices over the entry view, and a placeholder while there is nothing to read. The entry
/// starts right under the toolbar: the scope is the search field's menu (P6), not a row of its own.
struct EntryDetail: View {
    let state: SearchWindowState

    var body: some View {
        VStack(spacing: 0) {
            PageNotices(state: state)
            // **The AI controls live in the answer pane** (owner, 2026-10-26): the reading column is the dictionary's,
            // and a question and its answer share one surface. The pane opens when a sentence arrives
            // (`holdMeaning`), so the controls are never hidden behind a closed pane.
            EntryHost(controller: state.entry)
                .overlay { placeholder }
                .overlay(alignment: .bottom) { PronunciationBanner(pronunciation: state.pronunciation) }
        }
        .background { FindKeys(state: state) }
    }

    @ViewBuilder private var placeholder: some View {
        switch state.placeholder {
        case .noDictionaries:
            ContentUnavailableView {
                Label("No Dictionaries", systemImage: "books.vertical")
            } description: {
                Text("XDict reads the MDict dictionaries you have. Add them, then look words up here.")
            } actions: {
                EmptyStateActions {
                    Button("Add Dictionaries…") { SettingsRoute.shared.requestImport() }
                } secondary: {
                    Button("Open Dictionary Settings") { state.showDictionaries?(nil) }
                }
            }
            .coversPane()
        case .start:
            StartPage(names: state.model.known.filter(\.enabled).map(\.name)).coversPane()
        case .noResults, .noResultsIncomplete:
            // Which dictionaries could not look is said by the page's notices, above.
            NoEntriesFound().coversPane()
        case .searching:
            // **Never a blank sheet** (owner, 2026-10-26: the window drew a large empty page beside a full answer): a
            // lookup in flight says so, with the query it is for, so a search that stalls is visible rather than silent.
            VStack(spacing: Tokens.Space.s) {
                ProgressView().controlSize(.small)  // placement: spinner
                if let query = state.model.lookup?.query, !query.isEmpty {
                    Text("Looking up “\(query)”…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Looking this up…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("entry.searching")
            .coversPane()
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
                    // A strip's row (R2): the name and its sentence lead, the way on small at the trailing edge.
                    ActionRow(.strip) {
                        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                            Text(verbatim: section.name).fontWeight(.medium).lineLimit(1)
                            if let sentence = SearchSentences.status(section.status) {
                                ProblemStatus(sentence: sentence, compact: true)
                            }
                        }
                    } actions: {
                        if let next = section.next, SearchSentences.isButton(next) {
                            Button(SearchSentences.action(next)) { state.perform(next) }
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
        Button { state.pronounceShown() } label: { Label("Pronounce", systemImage: "speaker.wave.2") }  // placement: P41
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
