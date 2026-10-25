import AppKit
import SwiftUI
import XDictAnywhere
import XDictCaptureMac
import XDictContract
import XDictLibrary
import XDictSearch
import XDictTokens

/// What the panel shows besides an entry: the selection being read, or why nothing could be looked up.
public enum PanelNotice: Equatable, Sendable {
    case none
    case reading
    case refused(SelectionRefusal)
}

/// **The lookup panel's content** (plan-macos-v1 WI-8): the word, every dictionary's entry for it stacked under its name
/// (the All page, P41), "Open in XDict" to expand into the main window. Laid out as
/// the system Look Up popover (P41): a title row over the entry, footer rows under it (PanelLook). **The panel never takes the keyboard** (it must not
/// swallow the reader's next keystroke), so everything here is for the pointer; the keyboard has Escape, and the lookup
/// shortcut pressed again, which expands it (`help` says so).
public struct LookupPanelView: View {
    let state: SearchWindowState
    let notice: PanelNotice
    let shortcut: String?
    let expand: () -> Void
    let showDictionaries: () -> Void
    /// **"Meaning here"** (ADR-0021 d.1): the panel is too small for an answer, so it hands the sentence to the window it
    /// expands into, which asks there. A capture with no sentence offers no ask.
    let askMeaning: () -> Void

    public init(state: SearchWindowState, notice: PanelNotice, shortcut: String?, expand: @escaping () -> Void,
                showDictionaries: @escaping () -> Void = {}, askMeaning: @escaping () -> Void = {}) {
        self.state = state
        self.notice = notice
        self.shortcut = shortcut
        self.expand = expand
        self.showDictionaries = showDictionaries
        self.askMeaning = askMeaning
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            phraseRow
            EntryHost(controller: state.entry)
                // The entry fades out above the footer, so scrolled text never runs into its hairline (P41).
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: PanelLook.entryFade)
                    }
                }
                .overlay { placeholder }
            footer
        }
        // The popover has no title bar: the title row starts 16 pt from the top, the hidden title bar only a drag area.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: state.model.shown) { _, shown in
            guard let shown else { return }
            Task { await state.present(shown) }
        }
        // Each dictionary that answers joins the stack in the reader's order (the All page, P15), as in the window.
        .onChange(of: state.pageResults) { state.pageResultsChanged() }
        .onChange(of: state.library.searchSources, initial: true) { state.model.sourcesDidChange() }
        .onChange(of: state.placeholder) { state.placeholderChanged() }
        .onChange(of: state.model.lookup) { state.lookupDidChange() }
    }

    /// Everything around the entry, in points: the title row under its space and over its gap, and the two footer rows,
    /// each under a gap and a hairline (PanelLook).
    public static let chromeHeight: CGFloat = PanelLook.topSpace + PanelLook.titleRow + PanelLook.footerGap
        + 2 * (PanelLook.footerGap + PanelLook.footerRow + 1) + PanelLook.bottomInset

    /// **The chrome of a panel showing this row** (audit round 4, 2026-10-26): the phrase row is above the entry, not
    /// inside it, so a panel fitted without it is one row too short.
    public static func chromeHeight(for row: PhraseRow) -> CGFloat {
        row == .hidden ? chromeHeight : chromeHeight + PanelLook.phraseRowHeight
    }

    /// The popover's title row (P41): its 20 pt title. Apple's runs a rule after it to the trailing inset; XDict's has none
    /// (owner, 2026-10-18). The popover's title is the dictionary's name; XDict's keeps the speaker before the headword
    /// (owner, 2026-10-17). No switcher: every
    /// dictionary is stacked below under its own name, as Apple's popover stacks them (owner, 2026-10-18).
    private var header: some View {
        HStack(spacing: Tokens.Inset.panelRuleGap) {
            PronounceButton(state: state)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: PanelLook.titleRow, height: PanelLook.titleRow)
                .contentShape(Rectangle())
            Text(verbatim: state.shownWord ?? state.model.lookup?.query ?? "")
                .font(Tokens.TextRole.panelTitle.font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityIdentifier("panel.query")
            Spacer(minLength: 0)
            if state.meaning.canAsk {
                MeaningAskButton(enabled: true, action: askMeaning)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: PanelLook.titleRow, height: PanelLook.titleRow)
                    .accessibilityIdentifier("panel.meaning")
            }
        }
        .frame(height: PanelLook.titleRow)
        .padding(.top, PanelLook.topSpace)
        .padding(.bottom, PanelLook.footerGap)
        .padding(.leading, PanelLook.leading)
        .padding(.trailing, PanelLook.trailing)
    }

    /// **The phrase the captured sentence holds around its term** (contract 15; plan-phrase-recognition WI-8): the
    /// dictionary's own spelling and the sentence with that span marked, above the word's entry — never merged into its
    /// results. A tap looks the phrase up in place, so Back returns to the word that found it. A store still being read,
    /// and one that could not be, are rows of their own: neither is drawn as "no phrase".
    @ViewBuilder private var phraseRow: some View {
        switch state.phrases.row {
        case .hidden:
            EmptyView()
        case .building:
            phraseLine(Text("Reading your dictionaries for phrases…"))
                .accessibilityIdentifier("panel.phrase.building")
        case .unavailable:
            phraseLine(Text("Phrases are not available for these dictionaries."))
                .accessibilityIdentifier("panel.phrase.unavailable")
        case let .found(candidate, total, _):
            Button {  // placement: P41
                state.openPhrase(candidate.phrase)
            } label: {
                VStack(alignment: .leading, spacing: PanelLook.footerGap) {
                    sentenceText(candidate)
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(Tokens.Colour.secondaryLabel.color)
                        .lineLimit(2)
                    // **One line, so the fit's reservation is the row's height** (audit round 4, 2026-10-26): a phrase or
                    // a label that wrapped would draw past the space the panel was fitted with.
                    HStack(spacing: PanelLook.footerGap) {
                        Text(verbatim: candidate.phrase)
                            .font(Tokens.TextRole.panelDictionaryName.font)
                            .foregroundStyle(Tokens.Colour.label.color)
                        separationText(candidate)
                            .font(Tokens.TextRole.caption.font)
                            .foregroundStyle(Tokens.Colour.secondaryLabel.color)
                        if total > 1 {
                            Text("The first of \(total)")
                                .font(Tokens.TextRole.caption.font)
                                .foregroundStyle(Tokens.Colour.secondaryLabel.color)
                        }
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.leading, PanelLook.leading)
                .padding(.trailing, PanelLook.trailing)
                .padding(.bottom, PanelLook.footerGap)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("panel.phrase")
        }
    }

    /// One quiet line of the phrase row's non-answers, laid out as the row above the entry.
    private func phraseLine(_ text: Text) -> some View {
        text
            .font(Tokens.TextRole.caption.font)
            .foregroundStyle(Tokens.Colour.secondaryLabel.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, PanelLook.leading)
            .padding(.trailing, PanelLook.trailing)
            .padding(.bottom, PanelLook.footerGap)
    }

    /// The captured sentence with the phrase's span in bold: the row shows where the phrase sits, not only what it is.
    private func sentenceText(_ candidate: PhraseRow.Candidate) -> Text {
        let sentence = state.phrases.sentence
        var text = AttributedString(sentence)
        if let range = PhrasesModel.span(candidate, in: sentence),
           let start = AttributedString.Index(range.lowerBound, within: text),
           let end = AttributedString.Index(range.upperBound, within: text) {
            text[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(text)
    }

    /// How the words sat together, in the reader's words: the publisher's mark is stated as one, and the matcher's own
    /// inference is called a candidate, never the dictionary's.
    private func separationText(_ candidate: PhraseRow.Candidate) -> Text {
        switch candidate.separation {
        case .none: Text("Written unbroken")
        case .marked: Text("With a gap the dictionary marks")
        case .inferred: Text("With a gap inferred — a candidate")
        }
    }

    /// The popover's footer rows (P41): "Open in Dictionary" with a book, "Configure Dictionaries" with a gear; here
    /// "Open in XDict" and Settings ▸ Dictionaries.
    private var footer: some View {
        VStack(spacing: 0) {
            FooterRow(title: Text("Open in XDict"), symbol: "character.book.closed", action: expand)
                .disabled(state.model.lookup == nil)
                .help(expandHelp)
                .accessibilityIdentifier("panel.expand")
            FooterRow(title: Text("Configure Dictionaries"), symbol: "gearshape", action: showDictionaries)
                .accessibilityIdentifier("panel.configure")
        }
        .padding(.bottom, PanelLook.bottomInset)
    }

    /// System Settings › Privacy & Security › Device Control and Data Access (macOS 27's name; `PrivacySettings`).
    /// The URL lives in `SettingsLink`, the one place the setup board's buttons take theirs from too.
    static let accessibilityPane = SettingsLink.accessibility.url
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private var expandHelp: Text {
        if let shortcut { Text("Open in XDict (or press \(shortcut) again)") } else { Text("Open in XDict") }
    }

    @ViewBuilder private var placeholder: some View {
        switch notice {
        case .reading:
            ProgressView().controlSize(.small).coversPane()  // placement: spinner
        case .refused(let refusal):
            ContentUnavailableView {
                Label("Nothing to Look Up", systemImage: "text.cursor")
            } description: {
                Text(AnywhereSentences.refusal(refusal))
            } actions: {
                if refusal == .notTrusted {
                    EmptyStateActions {
                        Button("Open Accessibility Settings") { NSWorkspace.shared.open(Self.accessibilityPane) }
                            .accessibilityIdentifier("panel.openAccessibility")
                    }
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
                    EmptyStateActions {
                        Button("Open Dictionary Settings") { showDictionaries() }
                    }
                }
                .coversPane()
            case .searching:
                ProgressView().controlSize(.small).coversPane()  // placement: spinner
            case .noResults(let query):
                ContentUnavailableView.search(text: query).coversPane()
            case .noResultsIncomplete(let query, let unsearched):
                NoResultsIncomplete(query: query, unsearched: unsearched, showDictionaries: showDictionaries).coversPane()
            case .start, .none:
                EmptyView()
            }
        }
    }
}

/// One footer row of the popover (P41): an 8 pt gap, a hairline across the insets, then 26 pt of a semibold 13 pt title
/// 26 pt in and its symbol at the trailing inset, the whole row one button.
private struct FooterRow: View {
    let title: Text
    let symbol: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.leading, PanelLook.leading)
                .padding(.trailing, PanelLook.trailing)
                .padding(.top, PanelLook.footerGap)
            Button(action: action) {  // placement: P41
                HStack {
                    title.font(Tokens.TextRole.panelFooter.font)
                    Spacer(minLength: Tokens.Space.sm)
                    Image(systemName: symbol).imageScale(.large).accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, PanelLook.footerLeading)
                .padding(.trailing, PanelLook.trailing)
                .frame(height: PanelLook.footerRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
