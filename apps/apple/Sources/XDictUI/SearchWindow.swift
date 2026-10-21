import AppKit
import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictTokens

/// **The main window, as Apple's Dictionary has it** (parity ledger P1–P14; owner's decisions of 2026-10-17): the
/// toolbar holds Back/Forward, the title "XDict" with "N found" under it, the Smaller/Bigger Text pair and the
/// search field at its trailing edge, whose magnifier holds the scope menu (P6, XDict's own); the sidebar of matching
/// headwords appears only after a search. The field is the AppKit one, so focus, Return, the arrows and Escape keep
/// their contract. The menus (`SearchCommands`) carry every toolbar command, and XDict's own: Return to Original Word,
/// Pronounce.
public struct SearchWindow: View {
    @Bindable private var state: SearchWindowState
    @State private var columns = NavigationSplitViewVisibility.detailOnly
    /// The content column's width: the title over it yields when it is narrow (P8).
    @State private var column: CGFloat = Tokens.Window.initialColumn
    /// **The answer pane** (plan-ai-meaning WI-6): shown when an ask starts, closable, and never modal — the entry stays
    /// readable beside it.
    @State private var meaningShown = false

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
                if old == .idle { meaningShown = true }
                if case .preview = new { meaningShown = true }
            }
            // A lookup the reader typed or followed replaces the presentation: its captured sentence is dropped.
            .onChange(of: state.model.lookup) { state.lookupDidChange() }
            .onDisappear { state.clearMeaning() }
    }

    private var pane: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SearchSidebar(state: state)
                // Apple's window has no sidebar button: the sidebar comes with a search (P3, P9).
                .toolbar(removing: .sidebarToggle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                max: ToolbarLayout.sidebar.max)
        } detail: {
            EntryDetail(state: state, openMeaning: { meaningShown = true })
                .frame(minWidth: ToolbarLayout.minimumWindow.width / 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
        }
        .toolbar { toolbar }
        // **The answer pane** (ADR-0021 d.1): opened by an ask, closed by the reader; the entry keeps its width's room.
        .inspector(isPresented: $meaningShown) {
            MeaningAnswerPane(state: state)
                .inspectorColumnWidth(min: Tokens.Window.meaningPaneMin, ideal: Tokens.Window.meaningPaneIdeal,
                                      max: Tokens.Window.meaningPaneMax)
        }
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

    /// The toolbar (P3, `SearchToolbar`), wired to this window's search, entry and speaker.
    private var toolbar: some ToolbarContent {
        SearchToolbar(canGoBack: state.model.canGoBack, canGoForward: state.model.canGoForward,
                      canPronounce: state.canPronounce, back: { state.model.back() },
                      forward: { state.model.forward() }, smaller: { state.entry.zoomOut() },
                      bigger: { state.entry.zoomIn() }, pronounce: { state.pronounceSelectionOrShown() },
                      field: Self.searchField(text: state.model.text, known: state.model.known,
                                              scope: state.model.scope, focus: state.searchFocus,
                                              onScope: { state.model.setScope($0) },
                                              onChange: { state.typedText($0) }, onSubmit: { state.submit() },
                                              onMove: { state.move($0) }, onCancel: { state.cancel() }))
    }

    /// The toolbar's search field for the model's scope: its placeholder ("Search", or "Search in <name>"), and the
    /// scope menu's lines, which also set the magnifier (P6).
    static func searchField(text: String, known: [SearchSource], scope: SearchScope, focus: Int,
                            onScope: @escaping (SearchScope) -> Void, onChange: @escaping (String) -> Void,
                            onSubmit: @escaping () -> Void, onMove: @escaping (Int) -> Bool,
                            onCancel: @escaping () -> Bool) -> SearchField {
        SearchField(text: text, prompt: String(localized: SearchScopeMenu.prompt(known: known, scope: scope)),
                    scopes: SearchScopeMenu.items(known: known, scope: scope), onScope: onScope, focus: focus,
                    onChange: onChange, onSubmit: onSubmit, onMove: onMove, onCancel: onCancel)
    }
}

/// The entry pane: the page's notices over the entry view, and a placeholder while there is nothing to read. The entry
/// starts right under the toolbar: the scope is the search field's menu (P6), not a row of its own.
struct EntryDetail: View {
    let state: SearchWindowState
    /// The window's answer pane: the Ask and Preview controls open it before the session changes state, so an ask refused
    /// without a transition out of idle (no source) still shows its sentence.
    let openMeaning: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageNotices(state: state)
            // **"Meaning here" sits on the presented term** (ADR-0021 d.1), and only while a capture's sentence is held:
            // a typed lookup has nothing to ask about. A row of its own, not an overlay: over the notices it drew on
            // top of "Show in Settings" and both read as one smear (tour `panel.expand`, 2026-10-20).
            if state.meaning.canAsk {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button("Preview the Request…") {  // placement: meaning-chip
                        openMeaning()
                        state.meaning.preview()
                    }
                    .accessibilityIdentifier("meaning.preview")
                    MeaningAskButton(enabled: true) {
                        openMeaning()
                        state.meaning.ask()
                    }
                }
                .padding(.horizontal, Tokens.Inset.entryLeading)
                .padding(.vertical, Tokens.Space.xs)
                .background(.background)
                .overlay(alignment: .bottom) { Divider() }
            }
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
