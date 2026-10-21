import AppKit
import SwiftUI
import XDictContract
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
    /// The card whose note is being written, and what that note says already.
    @State private var noting: LedgerReading?
    @State private var initialDraft = ""

    public init(model: HistoryModel, study: StudyModel? = nil, onReview: (() -> Void)? = nil,
                presentation: HistoryDrawerPresentation = HistoryDrawerPresentation()) {
        _model = State(initialValue: model)
        self.study = study
        self.onReview = onReview
        self.presentation = presentation
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
    }

    private var header: some View {
        ActionRow(.strip) {
            Text("History")
                .font(Tokens.TextRole.headline.font)
        } actions: {
            if let onReview {
                Button("Review") { onReview() }
            }
            languageMenu
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
        switch model.state {
        case .off:
            notice("The reading history is off. Turn it on in Settings ▸ Learning.")
        case .loading:
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)  // placement: spinner
                Spacer()
                Spacer()
            }
        case .failed:
            notice("The reading history could not be read.")
        case .loaded:
            if model.days.isEmpty {
                notice("Nothing yet. A word you look up is kept here, with its sentence.")
            } else {
                days
            }
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
            // **A card's note** (plan §5.1): the reader's own words about the entry, written where they met it.
            if let study, noting == card.reading {
                StudyNoteEditor(study: study, entry: reference(card.reading),
                                name: card.reading.dictionaryName, initial: initialDraft) { noting = nil }
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sidebarSelection)
                .stroke(Color(nsColor: Tokens.Colour.separator.nsColor), lineWidth: Tokens.Line.hairline)
        }
        // The card reads as one element; its note editor is its own, so a combined card would hide the field.
        .accessibilityElement(children: noting == card.reading ? .contain : .combine)
        .accessibilityIdentifier("history.card")
        .contextMenu {
            if let study {
                Button("Note…") {  // placement: history-menu
                    let entry = reference(card.reading)
                    Task {
                        await study.loadNotes()
                        initialDraft = study.note(for: entry)?.text ?? ""
                        noting = card.reading
                    }
                }
            }
        }
    }

    private func reference(_ reading: LedgerReading) -> EntryRef {
        EntryRef(edition: Edition(rawValue: reading.edition), key: reading.entryKey,
                 occurrence: reading.occurrence)
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

    private func notice(_ text: LocalizedStringResource) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .multilineTextAlignment(.center)
                .padding(Tokens.Space.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
