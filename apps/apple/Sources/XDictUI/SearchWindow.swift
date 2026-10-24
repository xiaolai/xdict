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
    /// The content column's width: the title over it yields when it is narrow (P8).
    @State private var column: CGFloat = Tokens.Window.initialColumn
    /// The window's content width, which decides where the answer is shown (`MeaningPlacement`); nil until the first
    /// layout measures it.
    @State private var width: CGFloat?

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

    private var pane: some View {
        // **Where the answer is shown** (`MeaningPlacement`): beside the entry where it fits, else in a sheet; the
        // window's width and the results list stay the reader's.
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
            EntryDetail(state: state, openMeaning: { state.panes.meaningAsked() })
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
                // **The answer pane** (ADR-0021 d.1): opened by an ask, closed by the reader. On the detail, not the
                // split view: there its least was counted twice, the pane's column's and the split view's, so a 400 pt
                // window opening it grew and aborted in a recursive constraint update (`MeaningPaneFitTests`).
                // Nested in the navigation's detail, the inspector sits under the window's shared toolbar, level with
                // the reading area (WWDC23 10161). Its content is the pane alone: toolbar content declared inside an
                // inspector gives it a toolbar section of its own, so its toggle is the window's (`toolbar`).
                .inspector(isPresented: meaningShown(in: .inspector, now: shown)) {
                    MeaningAnswerPane(state: state)
                        .inspectorColumnWidth(min: Tokens.Window.meaningPaneMin, ideal: Tokens.Window.meaningPaneIdeal,
                                              max: Tokens.Window.meaningPaneMax)
                }
        }
        // **The answer in a sheet** where the pane does not fit beside the entry and the list the reader shows: the
        // pane's own scrolling body over Done (R3), Escape closing it too. Modal, so the window's search is back after
        // Done.
        .sheet(isPresented: meaningShown(in: .sheet, now: shown)) {
            let done = { state.panes.meaningClosed(by: .sheet, current: .sheet) }
            VStack(spacing: 0) {
                MeaningAnswerPane(state: state)
                Divider()
                SheetFooter([FooterAction(.primary, title: Text("Done"), perform: done)], closeOnEscape: done)
                    .padding(Tokens.Space.m)
            }
            .frame(width: Tokens.Window.meaningPaneIdeal, height: Tokens.Window.meaningSheetHeight)
        }
        .toolbar { toolbar }
        // Narrow, the title gives way so the search field stays (P8: Apple's slides under the field). Keyed on the content
        // column, not the window: a search's sidebar widened a 400 pt window to 583 pt, past the threshold, and brought
        // the title back over a 400 pt column (UI tour `main.narrow`, 2026-10-18).
        .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
        // A window is titled by the word it shows (UI08): Mission Control and the Window menu tell windows apart.
        .navigationTitle(Text(verbatim: ToolbarLayout.windowTitle(word: state.shownWord)))
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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

    /// Where the answer is shown now, from the reader's choices and the window's width (`MeaningPlacement`).
    private var presentation: MeaningPlacement {
        MeaningPlacement.at(width: width, results: state.panes.resultsVisible(listed: state.model.listing != nil),
                               meaning: state.panes.meaningShown)
    }

    /// The answer pane (plan-ai-meaning WI-6) in one of its presentations: opened by an ask, by View ▸ Show Meaning in
    /// Context and by the toolbar's toggle; closed by the reader (UI02, UI05). A dismissal is weighed against where the
    /// answer is shown when it arrives, so the one a resize just left does not close the answer (`meaningClosed`).
    private func meaningShown(in place: MeaningPlacement, now: MeaningPlacement) -> Binding<Bool> {
        Binding { now == place } set: { shown in
            guard !shown else { return }
            state.panes.meaningClosed(by: place, current: presentation)
        }
    }

    /// The window's one shared toolbar (P3, `SearchToolbar`), wired to this window's search, entry and speaker, then
    /// **the inspector's toggle** (HIG audit UI05): at the toolbar's trailing end, where a Mac window's inspector button
    /// is, after Apple's items in their order (P3, P8). The inspector owns no toolbar section, so the whole toolbar's
    /// width is the field's (P5); View ▸ Show Meaning in Context (⌃⌘I) brings a closed pane back.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        SearchToolbar(canGoBack: state.model.canGoBack, canGoForward: state.model.canGoForward,
                      canPronounce: state.canPronounce, back: { state.model.back() },
                      forward: { state.model.forward() }, smaller: { state.entry.zoomOut() },
                      bigger: { state.entry.zoomIn() }, pronounce: { state.pronounceSelectionOrShown() },
                      field: Self.searchField(text: state.model.text, known: state.model.known,
                                              scope: state.model.scope, focus: state.searchFocus,
                                              onScope: { state.model.setScope($0) },
                                              onChange: { state.typedText($0) }, onSubmit: { state.submit() },
                                              onMove: { state.move($0) }, onCancel: { state.cancel() }))
        MeaningPaneToggle(shown: state.panes.meaningShown) { state.panes.toggleMeaning() }
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

/// **The answer pane's toggle** (HIG audit UI05), owned by the shared window toolbar and shown at its trailing end
/// whether the answer is beside the entry, in its sheet or closed. It says what it will do, as View ▸ Show/Hide Meaning
/// in Context does.
struct MeaningPaneToggle: ToolbarContent {
    /// The reader asked for the answer: beside the entry or in its sheet.
    let shown: Bool
    let toggle: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggle) {  // placement: P3
                Label(shown ? LocalizedStringKey("Hide Meaning in Context") : LocalizedStringKey("Show Meaning in Context"),
                      systemImage: "sidebar.trailing")
            }
            .help(shown ? Text("Hide the meaning of the captured word in its sentence") : Text("Show Meaning in Context"))
            .accessibilityIdentifier("toolbar.meaning")
        }
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
                // **One quiet primary action, the rest secondary** (HIG audit UI06, UI13, UI16): Meaning Here leads;
                // Preview is a plain secondary button; a chosen sense adds Explain This Sense and Clear Choice. When the
                // window is narrow the row stacks rather than clipping (UI03).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.sm) {
                        Spacer(minLength: 0)
                        chips
                    }
                    VStack(alignment: .trailing, spacing: Tokens.Space.xs) {
                        chips
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, Tokens.Inset.entryLeading)
                .padding(.vertical, Tokens.Space.xs)
                .background(.background)
                .overlay(alignment: .bottom) { Divider() }
                if state.meaning.hasSenseSelection, !state.meaning.senseExplainAllowed {
                    // **The reason, visible, with the way to change it** (UI16; ADR-0021 d.4): a disabled control's
                    // tooltip alone was the only explanation. The button opens Settings; it changes nothing itself.
                    ActionRow(.strip) {
                        Text(MeaningSentences.explainNeedsEntryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } actions: {
                        Button("AI Settings…") { SettingsRoute.shared.showPane(.ai) }
                            .accessibilityIdentifier("meaning.explain.settings")
                    }
                    .padding(.horizontal, Tokens.Inset.entryLeading)
                    .padding(.vertical, Tokens.Space.xs)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("meaning.explain.reason")
                }
            }
            EntryHost(controller: state.entry)
                .overlay { placeholder }
                .overlay(alignment: .bottom) { PronunciationBanner(pronunciation: state.pronunciation) }
        }
        .background { FindKeys(state: state) }
    }

    /// The meaning row's controls, in reading order: the primary ask, its preview, then the chosen sense's.
    @ViewBuilder private var chips: some View {
        MeaningAskButton(enabled: true) {
            openMeaning()
            state.meaning.ask()
        }
        Button("Preview the Request…") {  // placement: meaning-chip
            openMeaning()
            state.meaning.preview()
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("meaning.preview")
        // **The sense the reader picked can be the question** (plan-explain-sense WI-5): shown while a sentence is held
        // and a sense is selected; without the switch it stays visible, disabled, its reason in the row below.
        if state.meaning.hasSenseSelection {
            Button("Explain This Sense") {  // placement: meaning-chip
                openMeaning()
                state.meaning.explain()
            }
            .disabled(!state.meaning.senseExplainAllowed)
            .help(state.meaning.senseExplainAllowed
                  ? String(localized: "Ask what the sense you chose means in this sentence.")
                  : String(localized: MeaningSentences.explainNeedsEntryText))
            .accessibilityIdentifier("meaning.explain")
            Button("Clear Choice") { state.clearSense() }  // placement: meaning-chip
                .buttonStyle(.borderless)
                .accessibilityIdentifier("meaning.clear-sense")
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
