import AppKit
import SwiftUI
import XDictContract
import XDictSearch
import XDictTokens

/// **How a card marks its word** (plan-history-and-learning §1, "Card layout"): the sentence split by the capture's UTF-16
/// span, and the capture's cut ends shown as ellipses. Pure text, so a CJK sentence and an emoji one are tests, not a look.
public enum HistoryRuns {
    public enum Run: Equatable, Sendable {
        case text(String)
        case word(String)
    }

    public static func runs(sentence: String, span: LedgerSpan?, cut: UInt8) -> [Run] {
        var runs: [Run] = []
        if cut & 1 != 0 { runs.append(.text("…")) }
        if let range = wordRange(sentence: sentence, span: span) {
            let before = String(sentence[..<range.lowerBound])
            let word = String(sentence[range])
            let after = String(sentence[range.upperBound...])
            if !before.isEmpty { runs.append(.text(before)) }
            if !word.isEmpty { runs.append(.word(word)) }
            if !after.isEmpty { runs.append(.text(after)) }
        } else if !sentence.isEmpty {
            runs.append(.text(sentence))
        }
        if cut & 2 != 0 { runs.append(.text("…")) }
        return runs
    }

    /// **The runs as the one string a screen reader hears**: the preview and the opened sentence are styled runs, but
    /// their accessibility text is the sentence itself, ellipses included.
    public static func plain(_ runs: [Run]) -> String {
        var text = ""
        for run in runs {
            switch run {
            case .text(let part), .word(let part): text += part
            }
        }
        return text
    }

    /// **The span as a validated range** (audit 2026-10-31): clamped to the sentence's UTF-16 length, and nil when it
    /// names nothing or does not fall on a character boundary — a corrupt record produces no word run, never a trap or a
    /// split grapheme. The one conversion both the expanded sentence and the collapsed window use.
    public static func wordRange(sentence: String, span: LedgerSpan?) -> Range<String.Index>? {
        guard let span else { return nil }
        let units = sentence.utf16.count
        let start = min(max(0, Int(span.start)), units)
        let end = min(start + max(0, Int(span.len)), units)
        guard end > start else { return nil }
        guard let valid = Range(NSRange(location: start, length: end - start), in: sentence) else { return nil }
        // **The conversion keeps an offset that falls inside a Character** — a surrogate pair, a combining mark — so the
        // landed indices are checked against the string's own Character boundaries: a corrupt span names no word rather
        // than half of one.
        let boundaries = sentence.indices
        let isBoundary = { (index: String.Index) in index == sentence.endIndex || boundaries.contains(index) }
        guard isBoundary(valid.lowerBound), isBoundary(valid.upperBound) else { return nil }
        return valid
    }
}

/// **The reading history's drawer** (plan-history-and-learning §1, WI-4; ported from XiaolaiDict's docked drawer): the
/// display's right edge, full height, glass — the list scrolling under the header bar the way system panels do, with the
/// corners against the screen edge square. The core grouped, collapsed and labelled; the drawer draws, and its language
/// filter shows a subset of what is stored — never rewriting it. The window is already at its docked rect; only this
/// content moves, and only when the drawer opens or closes.
public struct HistoryView: View {
    @State private var model: HistoryModel
    private let study: StudyModel?
    private let onReview: (() -> Void)?
    private let presentation: HistoryDrawerPresentation
    /// Opens the menu-bar item's own menu (UI42): the same menu a right click opens, reachable from the drawer.
    private let onShowMenu: (() -> Void)?
    /// The card whose note is being written, and what that note says already.
    @State private var noting: LedgerReading?
    /// The card the pointer is over: its controls show while it is there, or while the card has keyboard focus.
    @State private var hovered: LedgerCard?
    @FocusState private var focused: LedgerCard?
    /// **The cards whose whole sentence is open** (ADR-0037), keyed by the reading rather than the card: a repeat on
    /// the same day changes `times`, not the reading, and the disclosure must survive that. Closing the drawer folds
    /// them, so the next open starts as a list.
    @State private var expanded: Set<LedgerReading> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialDraft = ""
    /// A card whose notes could not be read: its editor stays shut rather than open empty over the reader's words.
    @State private var notesUnreadable: LedgerReading?
    /// A card whose entry could not be opened, and why.
    @State private var unopened: Unopened?

    struct Unopened: Equatable {
        let reading: LedgerReading
        let link: HistoryEntryLink
    }

    public init(model: HistoryModel, study: StudyModel? = nil, onReview: (() -> Void)? = nil,
                presentation: HistoryDrawerPresentation = HistoryDrawerPresentation(),
                onShowMenu: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.study = study
        self.onReview = onReview
        self.presentation = presentation
        self.onShowMenu = onShowMenu
    }

    public var body: some View {
        // No geometry means the drawer has not been laid out for a display; drawing nothing is right, since a guessed
        // size would be a window the reader can see and cannot explain.
        if let geometry = presentation.geometry {
            let parked = presentation.revealed ? CGSize.zero : geometry.hiddenOffset
            surface
                .frame(width: geometry.content.width, height: geometry.content.height)
                .clipShape(geometry.shape)
                // **Liquid Glass, not an `NSVisualEffectView`**: macOS 26 and later's material, with its own edge
                // treatment and its own shadow — so no hand-drawn border, and no `.shadow` stacked on the system's.
                .glassEffect(.regular, in: geometry.shape)
                .offset(x: geometry.contentOrigin.x + Motion.travel(parked.width),
                        y: geometry.contentOrigin.y + Motion.travel(parked.height))
                .opacity(presentation.revealed ? 1 : 0)
                .frame(width: geometry.window.width, height: geometry.window.height, alignment: .topLeading)
                .clipped()
                .ignoresSafeArea()
                .accessibilityIdentifier("history.drawer")
        }
    }

    private var surface: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **A bar, not a header above a rule**: the list scrolls under it, and the system's scroll edge effect is
            // what separates the two.
            .safeAreaBar(edge: .top, spacing: 0) {
                header
            }
            // **A bar, not an overlay** (UI44): the list ends above the notice, so it never covers the last card.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                removalToast
            }
            // A closed drawer is a fresh list: no card stays open behind the slide.
            .onChange(of: presentation.revealed) { _, revealed in
                if !revealed { expanded.removeAll() }
            }
    }

    /// **The notice a removal leaves behind** (E4: frequent reversible actions take undo, not a confirmation dialog). It
    /// goes when its time is up — the undo stays in the header until the next removal — or says the removal failed.
    @ViewBuilder private var removalToast: some View {
        if model.removalNoticeShown {
            ActionRow(.strip) {
                Text(model.removalFailed ? "The card could not be removed." : "Removed from the history.")
            } actions: {
                if model.lastRemoval != nil, !model.removalFailed {
                    Button("Undo") { Task { await model.restoreLast() } }
                        .accessibilityIdentifier("history.undoRemoval")
                }
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.s)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.removed")
            .task(id: model.lastRemoval?.eventIds) {
                try? await Task.sleep(for: .seconds(Tokens.Motion.removalUndoSeconds))
                model.dismissRemovalNotice()
            }
        }
    }

    private var header: some View {
        ActionRow(.strip) {
            Text("History")
                .font(Tokens.TextRole.headline.font)
        } actions: {
            // **Undo outlives its notice** (UI44): a reader who looks for it later still finds it here.
            if model.lastRemoval != nil, !model.removalNoticeShown {
                Button("Undo Remove") { Task { await model.restoreLast() } }
                    .accessibilityIdentifier("history.undoRemovalLater")
            }
            if let onReview {
                Button("Review") { onReview() }
            }
            languageMenu
            if let onShowMenu {
                // **The menu bar item's menu, from where the reader already is** (UI42): a primary click on the icon opens
                // this drawer and a secondary click the menu; this button is the visible way to the second.
                Button(action: onShowMenu) {  // placement: glyph
                    Label("Show Menu", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Show the XDict menu (also a right-click on the menu bar icon)")
                .accessibilityIdentifier("history.showMenu")
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m)
    }

    private var languageMenu: some View {
        Menu {  // placement: history-menu
            Button("All languages") { model.preferences.setDrawerLanguages([]) }
                .disabled(model.preferences.drawerLanguages.isEmpty)
            Divider()
            ForEach(model.storedLanguages, id: \.self) { language in
                Toggle(LearningSettings.name(language), isOn: Binding(
                    get: { model.preferences.drawerLanguages.contains(language) },
                    set: { on in
                        var next = model.preferences.drawerLanguages
                        if on, !next.contains(language) { next.append(language) }
                        if !on { next.removeAll { $0 == language } }
                        model.preferences.setDrawerLanguages(next)
                    }))
            }
        } label: {
            Label("Languages", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show only some languages")
        .accessibilityIdentifier("history.languages")
    }

    @ViewBuilder private var content: some View {
        if let notice = HistoryNotice.of(model.state, isEmpty: model.days.isEmpty) {
            VStack(spacing: Tokens.Space.m) {
                Spacer()
                Text(notice.text)
                    .font(Tokens.TextRole.callout.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                    .multilineTextAlignment(.center)
                if notice.offersRetry {
                    // **A failed read is not an empty history** (UI50): it says so and offers the read again.
                    EmptyStateActions {
                        Button("Try Again") { Task { await model.refresh() } }
                            .accessibilityIdentifier("history.retry")
                    }
                }
                Spacer()
            }
            .padding(Tokens.Space.xl)
            .frame(maxWidth: .infinity)
        } else if case .loading = model.state {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)  // placement: spinner
                Spacer()
                Spacer()
            }
        } else {
            days
        }
    }

    private var days: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Space.l) {
                ForEach(model.days, id: \.id) { day in
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        Text(dayName(day))
                            .font(Tokens.TextRole.caption.font)
                            .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                        ForEach(day.cards, id: \.self) { card in
                            cardView(card)
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.bottom, Tokens.Space.l)
            .padding(.top, Tokens.Space.xs)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder private func cardView(_ card: LedgerCard) -> some View {
        // **The card's content as one value** (ADR-0037): the word first, then the gloss the reader last got for this
        // reading (or the recorded edition's own), then one line of its context.
        let content = HistoryCardContent(card: card, answer: model.answer(for: card),
                                         dictionaryGloss: model.gloss(for: card))
        // **What a screen reader hears and may do** (plan item 7): the four lines as the card's label, and every card
        // operation as its custom action. A container's actions are never announced — the reader focuses its children —
        // and a written representation drops them too (both checked by the UI tour, 2026-11-01), so the card itself is
        // the leaf that carries them. A note editor or a status message makes it a container again, so those stay
        // reachable.
        let special = noting == card.reading || unopened?.reading == card.reading || notesUnreadable == card.reading
        let expandedNow = expanded.contains(card.reading)
        let contextText = HistoryRuns.plain(expandedNow
            ? HistoryRuns.runs(sentence: card.reading.sentence, span: card.reading.span, cut: card.reading.cut)
            : content.context)
        let spoken = content.spoken(context: contextText,
                                    time: Date(timeIntervalSince1970: content.at)
                                        .formatted(date: .omitted, time: .shortened))
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            wordLine(content)
            if let gloss = content.gloss {
                glossLine(gloss)
            }
            context(card, content)
            metadata(content)
            if let unopened, unopened.reading == card.reading, let why = unopened.link.explanation {
                unavailable(why, key: card.reading.entryKey)
            }
            if notesUnreadable == card.reading {
                ActionRow {
                    Text("The notes could not be read.")
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                } actions: {
                    Button("Try Again") { perform(.note, on: card) }
                }
            }
            // **A card's note** (plan §5.1): the reader's own words about the entry, written where they met it.
            if let study, noting == card.reading {
                StudyNoteEditor(study: study, entry: EntryRef(reading: card.reading),
                                name: card.reading.dictionaryName, initial: initialDraft) { noting = nil }
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            // **A tint from the card's own identity** (owner, 2026-10-31; supersedes UI45's neutral hairline): one of the
            // system's tints at border opacity — a border, never a fill, and the same one on every redraw and launch.
            RoundedRectangle(cornerRadius: Tokens.Radius.cardShadow, style: .continuous)
                .stroke(HistoryCardTint.colour(for: card.reading).color.opacity(Tokens.Opacity.cardBorder),
                        lineWidth: Tokens.Line.hairline)
        }
        .shadow(color: Tokens.Colour.shadow.color.opacity(Tokens.Opacity.cardShadow),
                radius: Tokens.Card.shadowRadius, y: Tokens.Card.shadowOffsetY)
        .overlay(alignment: .topTrailing) {
            // **The card's own controls** (owner, 2026-10-21: a misread word must be removable): shown where the pointer
            // is or where the keyboard is (UI43), so a card at rest stays only its sentence.
            if hovered == card || focused == card {
                HStack(spacing: Tokens.Space.xs) {
                    if model.entryLinks != nil {
                        glyph("arrow.up.forward.app", .openEntry, card: card, id: "history.open")
                    }
                    glyph("xmark.circle.fill", .remove, card: card, id: "history.remove")
                }
                .padding(Tokens.Space.xs)
            }
        }
        .onHover { inside in
            hovered = inside ? card : (hovered == card ? nil : hovered)
        }
        // **A visible card asks for its dictionary gloss once** (ADR-0037): the model caches it, limits how many run at
        // once, and asks again only for a failed edition, on the next drawer open.
        .task(id: HistoryModel.GlossRequest(reading: card.reading, revision: model.glossRevision)) {
            model.loadGloss(for: card)
        }
        .focusable()
        .focused($focused, equals: card)
        // Delete removes the focused card, as in a list; the undo stays reachable (UI43, UI44).
        .onDeleteCommand { perform(.remove, on: card) }
        // Space opens or folds the context; Return opens the entry. Both are list habits, and the pointer keeps its
        // own control — the card body stays free for selecting the open sentence.
        .onKeyPress(.space) { toggleContext(card.reading); return .handled }
        .onKeyPress(.return) { perform(.openEntry, on: card); return .handled }
        // **One card, one element, every operation on it** (plan item 7): its four lines are the label and its actions
        // are custom actions; a container or a representation would drop them (see `CardAccessibility`).
        .modifier(CardAccessibility(narrated: !special, label: spoken,
                                    contextTitle: contextActionTitle(card.reading), actions: actions,
                                    toggle: { toggleContext(card.reading) },
                                    perform: { perform($0, on: card) }))
        .accessibilityIdentifier("history.card")
        .contextMenu {
            Button(String(localized: contextActionTitle(card.reading))) { toggleContext(card.reading) }  // placement: history-menu
            Divider()
            ForEach(actions, id: \.self) { action in
                if action == .remove { Divider() }
                Button(String(localized: action.title)) { perform(action, on: card) }  // placement: history-menu
            }
        }
    }

    /// **The card's four lines, drawn from one value** (ADR-0037). The word is the card's title; the gloss says what it
    /// meant; the context is one line around the word; the metadata names where and when.
    private func wordLine(_ content: HistoryCardContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            Text(verbatim: content.word)
                .font(Tokens.TextRole.headline.font)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if let lemma = content.lemma {
                Text("as \(lemma)")
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if content.times > 1 {
                Text(verbatim: "×\(content.times)")
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
        }
    }

    /// **What the word meant** (ADR-0037): the reader's answer, marked AI, or the recorded edition's first sense. The
    /// part of speech leads when one is known; the AI mark says whose wording this is, never the dictionary's.
    private func glossLine(_ gloss: HistoryCardGloss) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            if let pos = gloss.pos, !pos.isEmpty {
                Text(verbatim: pos)
                    .font(Tokens.TextRole.callout.font)
                    .italic()
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
            if gloss.source == .ai {
                HStack(spacing: Tokens.Space.xxs) {
                    Image(systemName: "sparkles")
                    Text(verbatim: "AI")
                }
                .font(Tokens.TextRole.caption.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("AI answer"))
            }
            Text(verbatim: gloss.text)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// **The context, one line at rest and whole when opened** (ADR-0037): the resting line is the preview window, never
    /// selectable; the opened sentence is the full selectable text, and the control that folds it sits beside it, so a
    /// drag selects rather than toggles.
    @ViewBuilder private func context(_ card: LedgerCard, _ content: HistoryCardContent) -> some View {
        if expanded.contains(card.reading) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                sentence(HistoryRuns.runs(sentence: card.reading.sentence, span: card.reading.span,
                                          cut: card.reading.cut))
                    .font(Tokens.TextRole.body.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.label.nsColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button { toggleContext(card.reading) } label: {  // placement: history-card
                    HStack(spacing: Tokens.Space.xxs) {
                        Text(contextActionTitle(card.reading))
                        Image(systemName: "chevron.down")
                    }
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.expandContext")
                .help(Text("Hide context"))
            }
        } else {
            Button { toggleContext(card.reading) } label: {  // placement: history-card
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    sentence(content.context)
                        .font(Tokens.TextRole.callout.font)
                        .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history.expandContext")
            .accessibilityHint(Text("Show context"))
            .help(Text("Show context"))
        }
    }

    private func metadata(_ content: HistoryCardContent) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(verbatim: content.dictionaryName.isEmpty
                 ? String(localized: "Unknown dictionary") : content.dictionaryName)
            Text(verbatim: "·")
            Text(Date(timeIntervalSince1970: content.at), style: .time)
        }
        .font(Tokens.TextRole.caption.font)
        .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
    }

    /// A card opens and folds without a spring of its own: the system's default disclosure animation, and none when the
    /// reader has asked for reduced motion.
    private func toggleContext(_ reading: LedgerReading) {
        withAnimation(reduceMotion ? nil : .default) {
            if expanded.contains(reading) {
                expanded.remove(reading)
            } else {
                expanded.insert(reading)
            }
        }
    }

    private func contextActionTitle(_ reading: LedgerReading) -> LocalizedStringResource {
        expanded.contains(reading) ? "Hide context" : "Show context"
    }

    /// The actions this drawer can offer: Remove always; Note, Open Entry and Ask AI where the app wired them.
    private var actions: [HistoryCardAction] {
        HistoryCardAction.actions(canNote: study != nil, canOpen: model.entryLinks != nil,
                                  canAsk: model.entryLinks?.openMeaning != nil)
    }

    private func glyph(_ symbol: String, _ action: HistoryCardAction, card: LedgerCard, id: String) -> some View {
        Button { perform(action, on: card) } label: {  // placement: glyph
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
        }
        .buttonStyle(.plain)
        .help(String(localized: action.title))
        // **The glyphs are pointer controls** (plan item 7): their actions are the card's custom actions, so a screen
        // reader never meets a second, hover-only copy of them.
        .accessibilityHidden(true)
        .accessibilityIdentifier(id)
    }

    private func perform(_ action: HistoryCardAction, on card: LedgerCard) {
        switch action {
        case .remove:
            Task { await model.remove(card) }
        case .openEntry, .askAI:
            // **One resolution for both** (audit 2026-10-31): the two actions differ only in where a resolved entry
            // goes, so the guard, the lookup and the refusal are written once.
            guard let links = model.entryLinks else { return }
            let link = links.resolve(EntryRef(reading: card.reading))
            switch link {
            case .entry(let result):
                unopened = nil
                if action == .openEntry {
                    links.open(HistoryEntryLink.visit(opening: result))
                } else if let openMeaning = links.openMeaning {
                    openMeaning(result, card.reading)
                }
            case .dictionaryOff, .editionMissing:
                unopened = Unopened(reading: card.reading, link: link)
            }
        case .note:
            guard let study else { return }
            let entry = EntryRef(reading: card.reading)
            Task {
                guard await study.loadNotes() else {
                    notesUnreadable = card.reading
                    return
                }
                notesUnreadable = nil
                initialDraft = study.note(for: entry)?.text ?? ""
                noting = card.reading
            }
        }
    }

    /// **Why the entry did not open** (UI46), and the one thing the reader may choose instead: the recorded key looked up
    /// in every dictionary. Never a guess at another edition.
    private func unavailable(_ why: LocalizedStringResource, key: String) -> some View {
        EntryLinkFallback(why: why, key: key, links: model.entryLinks) { unopened = nil }
    }

    /// The sentence as one attributed run, the word in bold: `Text` concatenation is deprecated on macOS 26, and its
    /// suggested interpolation cannot mark part of a string. The preview and the whole sentence are the same runs,
    /// only windowed differently.
    private func sentence(_ runs: [HistoryRuns.Run]) -> Text {
        var text = AttributedString()
        for run in runs {
            switch run {
            case .text(let part):
                text.append(AttributedString(part))
            case .word(let word):
                var marked = AttributedString(word)
                marked.inlinePresentationIntent = .stronglyEmphasized
                text.append(marked)
            }
        }
        return Text(text)
    }

    private func dayName(_ day: LedgerDay) -> String {
        let date = Date(timeIntervalSince1970: day.start)
        switch day.label {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .weekday: return date.formatted(.dateTime.weekday(.wide))
        case .date: return date.formatted(.dateTime.year().month(.wide).day())
        }
    }
}

/// **A card as a screen reader hears and operates it** (plan item 7; the UI tour of 2026-11-01 found the derived
/// element spoke only its provenance): the four lines are its label and its operations are custom actions, because a
/// container's own actions are never announced — the reader focuses its children — and a written representation drops
/// them too (`AXCustomActions` read as a failure). A note editor or a status message makes the card a container again,
/// so the element the reader must reach there stays in the tree.
private struct CardAccessibility: ViewModifier {
    let narrated: Bool
    let label: String
    let contextTitle: LocalizedStringResource
    let actions: [HistoryCardAction]
    let toggle: () -> Void
    let perform: (HistoryCardAction) -> Void

    @ViewBuilder func body(content view: Content) -> some View {
        if narrated {
            view
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityActions {
                    Button(String(localized: contextTitle)) { toggle() }  // placement: history-menu
                    ForEach(actions, id: \.self) { action in
                        Button(String(localized: action.title)) { perform(action) }  // placement: history-menu
                    }
                }
        } else {
            view.accessibilityElement(children: .contain)
        }
    }
}

/// **Why a recorded entry did not open** (UI46, UI48), and the one thing the reader may choose instead: the recorded key
/// looked up in every dictionary. Never a guess at another edition. Shared by a history card and the review window.
struct EntryLinkFallback: View {
    let why: LocalizedStringResource
    let key: String
    let links: HistoryEntryLinks?
    let opened: () -> Void

    var body: some View {
        ActionRow {
            Text(why)
                .font(Tokens.TextRole.caption.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            if let visit = HistoryEntryLink.lookUp(key: key), let links {
                Button(String(localized: "Look Up “\(visit.query)”")) {
                    opened()
                    links.open(visit)
                }
                .accessibilityIdentifier("entry.lookUpKey")
            }
        }
    }
}
