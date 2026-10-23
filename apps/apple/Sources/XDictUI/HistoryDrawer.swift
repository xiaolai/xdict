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
        if let span {
            // A span outside the sentence is clamped, never a crash: the capture validates it, and a corrupt record must
            // not take the drawer down with it.
            let units = sentence.utf16.count
            let start = min(max(0, Int(span.start)), units)
            let end = min(start + max(0, Int(span.len)), units)
            let first = String.Index(utf16Offset: start, in: sentence)
            let second = String.Index(utf16Offset: end, in: sentence)
            let before = String(sentence[..<first])
            let word = String(sentence[first..<second])
            let after = String(sentence[second...])
            if !before.isEmpty { runs.append(.text(before)) }
            if !word.isEmpty { runs.append(.word(word)) }
            if !after.isEmpty { runs.append(.text(after)) }
        } else if !sentence.isEmpty {
            runs.append(.text(sentence))
        }
        if cut & 2 != 0 { runs.append(.text("…")) }
        return runs
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
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            // Selectable text, and only that: copying the sentence never navigates (UI46).
            sentence(card.reading)
                .font(Tokens.TextRole.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Tokens.Space.xs) {
                Text(card.reading.dictionaryName.isEmpty
                     ? String(localized: "Unknown dictionary") : card.reading.dictionaryName)
                Text(verbatim: "·")
                Text(Date(timeIntervalSince1970: card.reading.at), style: .time)
                if card.times > 1 {
                    Text(verbatim: "×\(card.times)")
                }
            }
            .font(Tokens.TextRole.caption.font)
            .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
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
            // **Neutral** (UI45): a colour per card meant nothing and could be read as a category or a status.
            RoundedRectangle(cornerRadius: Tokens.Radius.cardShadow, style: .continuous)
                .stroke(HistoryCardStyle.border.color, lineWidth: Tokens.Line.hairline)
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
        .focusable()
        .focused($focused, equals: card)
        // Delete removes the focused card, as in a list; the undo stays reachable (UI43, UI44).
        .onDeleteCommand { perform(.remove, on: card) }
        // The card reads as one element; its note editor is its own, so a combined card would hide the field.
        .accessibilityElement(children: noting == card.reading ? .contain : .combine)
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(String(localized: action.title)) { perform(action, on: card) }  // placement: history-menu
            }
        }
        .accessibilityIdentifier("history.card")
        .contextMenu {
            ForEach(actions, id: \.self) { action in
                if action == .remove { Divider() }
                Button(String(localized: action.title)) { perform(action, on: card) }  // placement: history-menu
            }
        }
    }

    /// The actions this drawer can offer: Remove always; Note and Open Entry where the app wired them.
    private var actions: [HistoryCardAction] {
        HistoryCardAction.actions(canNote: study != nil, canOpen: model.entryLinks != nil)
    }

    private func glyph(_ symbol: String, _ action: HistoryCardAction, card: LedgerCard, id: String) -> some View {
        Button { perform(action, on: card) } label: {  // placement: glyph
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
        }
        .buttonStyle(.plain)
        .help(String(localized: action.title))
        .accessibilityLabel(Text(action.title))
        .accessibilityIdentifier(id)
    }

    private func perform(_ action: HistoryCardAction, on card: LedgerCard) {
        switch action {
        case .remove:
            Task { await model.remove(card) }
        case .openEntry:
            guard let links = model.entryLinks else { return }
            let link = links.resolve(EntryRef(reading: card.reading))
            if case .entry(let result) = link {
                unopened = nil
                links.open(HistoryEntryLink.visit(opening: result))
            } else {
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
    /// suggested interpolation cannot mark part of a string.
    private func sentence(_ reading: LedgerReading) -> Text {
        var text = AttributedString()
        for run in HistoryRuns.runs(sentence: reading.sentence, span: reading.span, cut: reading.cut) {
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
