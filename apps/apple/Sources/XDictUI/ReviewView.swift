import SwiftUI
import XDictContract
import XDictTokens

/// **The review window** (plan-history-and-learning §5): the card in front — its word, the reader's own note — and the
/// four answers, with an undo for the grade just made. The core decides what is due and what a grade does; this view
/// carries the taps and says what came back.
public struct ReviewView: View {
    @State private var model: StudyModel
    @State private var editing = false
    @State private var unopened: Unopened?

    /// An entry Open Entry could not open, and why (UI48).
    private struct Unopened {
        let entry: EntryRef
        let why: LocalizedStringResource
    }

    public init(model: StudyModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            header
            switch model.state {
            case .idle, .loading:
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)  // placement: spinner
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .failed, .ready:
                if let notice = ReviewNotice.of(model.state, hasCard: model.current != nil,
                                                hasConflicts: !model.conflicts.isEmpty) {
                    noticeView(notice)
                } else {
                    // **Long content scrolls** (UI47): a long note or many conflicts stay inside the window, and the
                    // grades below stay in reach rather than being pushed off the screen.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Tokens.Space.l) {
                            if !model.conflicts.isEmpty {
                                conflictsView
                            }
                            if let card = model.current {
                                cardView(card)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    if let card = model.current {
                        grades(card)
                    }
                }
            }
        }
        .padding(Tokens.Space.xl)
        // The ideal height is the minimum: the window opens at its default size and never sizes itself to the content.
        .frame(minWidth: Tokens.Window.reviewWidth, minHeight: Tokens.Window.reviewMinHeight,
               idealHeight: Tokens.Window.reviewMinHeight)
        .task { await model.refresh() }
        .sheet(isPresented: $editing) {
            if let entry {
                // A sheet sizes to its content: the editor is given the review window's width.
                StudyNoteEditor(study: model, entry: entry, name: "", initial: model.current?.note.text ?? "",
                                width: Tokens.Window.reviewWidth) { editing = false }
            }
        }
    }

    private var entry: EntryRef? {
        model.current.map { EntryRef(target: $0.target) }
    }

    private var header: some View {
        ActionRow {
            Text("Review")
                .font(Tokens.TextRole.title3.font)
        } actions: {
            if let summary = model.summary {
                Text(summary.due > 0 ? String(localized: "\(summary.due) due") : String(localized: "Nothing due"))
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
        }
    }

    /// **The cards two devices answered** (ADR-0027): one row per answer, and the reader says which stands. The choice
    /// is an event, so the other device learns it as soon as the two logs meet.
    private var conflictsView: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            ForEach(model.conflicts, id: \.target.key) { conflict in
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    Text(verbatim: conflict.note.target.entryKey)
                        .font(Tokens.TextRole.headline.font)
                    Text("Two devices answered this card. Keep one.")
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                    ForEach(conflict.candidates, id: \.id) { candidate in
                        ActionRow {
                            Text(verbatim: Self.describe(candidate))
                                .font(Tokens.TextRole.callout.font)
                        } actions: {
                            Button("Keep") { Task { await model.resolve(conflict, keep: candidate) } }
                        }
                    }
                }
            }
        }
        .padding(.bottom, Tokens.Space.m)
    }

    static func describe(_ candidate: ConflictCandidate) -> String {
        let when = Date(timeIntervalSince1970: candidate.at).formatted(date: .abbreviated, time: .shortened)
        return "\(title(candidate.grade)) · \(when) · \(candidate.device)"
    }

    @ViewBuilder private func cardView(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            ActionRow {
                Text(verbatim: card.note.target.entryKey)
                    .font(Tokens.TextRole.title3.font)
            } actions: {
                if model.entryLinks != nil {
                    Button("Open Entry") { open(card) }
                        .accessibilityIdentifier("review.openEntry")
                }
                Button("Note…") { editing = true }
                if !card.head.isEmpty {
                    Button("Undo") { Task { await model.undo(card) } }
                }
            }
            if let unopened, unopened.entry == EntryRef(target: card.target) {
                EntryLinkFallback(why: unopened.why, key: card.target.entryKey, links: model.entryLinks) {
                    self.unopened = nil
                }
            }
            if card.note.text.isEmpty {
                Text("No note yet.")
                    .font(Tokens.TextRole.body.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            } else {
                Text(verbatim: card.note.text)
                    .font(Tokens.TextRole.body.font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **The four answers**, under the scrolling content and never scrolled away (UI47).
    @ViewBuilder private func grades(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            ActionRow {
                Text("How well did you know it?")
                    .font(Tokens.TextRole.callout.font)
            } actions: {
                ForEach(StudyGrade.allCases, id: \.self) { grade in
                    Button(Self.title(grade)) { Task { await model.grade(card, grade) } }
                }
            }
            if let outcome = model.lastOutcome, outcome.card.target.key == card.target.key {
                Text(Self.describe(outcome.outcome))
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
        }
    }

    /// **Open Entry** (UI48): the card's own edition and record in the main window, or why it cannot be opened.
    private func open(_ card: StudyCard) {
        guard let links = model.entryLinks else { return }
        let entry = EntryRef(target: card.target)
        let link = links.resolve(entry)
        if case .entry(let result) = link {
            unopened = nil
            links.open(HistoryEntryLink.visit(opening: result))
        } else if let why = link.explanation {
            unopened = Unopened(entry: entry, why: why)
        }
    }

    /// **What the window says instead of a card**; a failed read offers the read again (UI50).
    private func noticeView(_ notice: ReviewNotice) -> some View {
        VStack(spacing: Tokens.Space.m) {
            Spacer()
            Text(verbatim: noticeText(notice))
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .multilineTextAlignment(.center)
            if notice.offersRetry {
                EmptyStateActions {
                    Button("Try Again") { Task { await model.refresh() } }
                        .accessibilityIdentifier("review.retry")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func noticeText(_ notice: ReviewNotice) -> String {
        switch notice {
        case .failed:
            String(localized: "The review list could not be read.")
        case .nothingDue:
            model.summary?.nextDue.map {
                String(localized: "Nothing is due. The next card falls due at \(Self.time($0)).")
            } ?? String(localized: "Nothing is due.")
        }
    }

    private static func time(_ seconds: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }

    static func title(_ grade: StudyGrade) -> String {
        switch grade {
        case .again: String(localized: "Again")
        case .hard: String(localized: "Hard")
        case .good: String(localized: "Good")
        case .easy: String(localized: "Easy")
        }
    }

    static func describe(_ outcome: LedgerRecordOutcome) -> LocalizedStringResource {
        switch outcome {
        case .recorded: "Graded."
        case .duplicate: "Already recorded."
        case .uncertain: "Recorded, but not yet flushed to disk."
        case .skippedLanguage: "Not recorded: outside your languages."
        case .ineligible: "The card had moved or was not due."
        }
    }
}

/// **The note editor** (plan §5.1): the reader's own words about an entry, saved as a note whose evidence the core
/// computes. Used from the review window as a sheet and from a history card inside the drawer.
public struct StudyNoteEditor: View {
    private let study: StudyModel?
    private let entry: EntryRef?
    private let name: String
    private let initial: String
    private let width: CGFloat?
    private let done: () -> Void
    @State private var draft: String
    @State private var saving = false
    @State private var failure: LocalizedStringResource?
    @State private var confirmingClear = false
    /// The wording a clear replaced, kept for Undo while the editor is open.
    @State private var cleared: String?

    /// `entry` nil disables Save: a note needs a target. `width` nil fills its container (the drawer), and a sheet
    /// passes one, as a sheet sizes to its content.
    public init(study: StudyModel?, entry: EntryRef?, name: String, initial: String = "", width: CGFloat? = nil,
                done: @escaping () -> Void) {
        self.study = study
        self.entry = entry
        self.name = name
        self.initial = initial
        self.width = width
        self.done = done
        _draft = State(initialValue: initial)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Note")
                .font(Tokens.TextRole.headline.font)
            TextEditor(text: $draft)
                .font(Tokens.TextRole.body.font)
                .frame(minHeight: Tokens.Window.reviewMinHeight / 2)
            if let failure {
                Text(failure)
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
            if confirmingClear {
                // **Said before it is done** (UI49): the core keeps every revision, so clearing is an empty revision,
                // not an erasure, and the word stays in Review.
                ActionRow {
                    Text("Clear this note? The word stays in Review, and the earlier wording stays in your exported data until you erase it.")
                        .font(Tokens.TextRole.caption.font)
                        .fixedSize(horizontal: false, vertical: true)
                } actions: {
                    Button("Keep Note") { confirmingClear = false }
                    Button("Clear Note", role: .destructive) { clear() }
                        .accessibilityIdentifier("note.confirmClear")
                }
            }
            if let cleared {
                ActionRow {
                    Text("Note cleared.")
                        .font(Tokens.TextRole.caption.font)
                } actions: {
                    Button("Undo") { restore(cleared) }
                        .accessibilityIdentifier("note.undoClear")
                }
            }
            SheetFooter(footer)
        }
        .padding(Tokens.Space.l)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var footer: [FooterAction] {
        var actions = [
            FooterAction(.cancel, title: Text("Cancel")) { done() },
            FooterAction(.primary, title: Text("Save"), isDisabled: isDisabled) { save() },
        ]
        if canClear {
            actions.insert(FooterAction(.destructive, title: Text("Clear Note…"), identifier: "note.clear",
                                        isDisabled: saving) { confirmingClear = true }, at: 0)
        }
        return actions
    }

    /// Only a note that was saved can be cleared; clearing nothing would enrol a card the reader never asked for.
    private var canClear: Bool {
        study != nil && entry != nil && cleared == nil && !confirmingClear
            && !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDisabled: Bool {
        saving || entry == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        saving = true
        failure = nil
        Task {
            let saved = if let study, let entry {
                if case .saved = await study.saveNote(entry: entry, text: draft, name: name) { true } else { false }
            } else {
                false
            }
            saving = false
            if saved {
                done()
            } else {
                failure = "The note could not be saved."
            }
        }
    }

    private func clear() {
        guard let study, let entry else { return }
        confirmingClear = false
        saving = true
        failure = nil
        Task {
            let outcome = await study.clearNote(entry: entry, name: name)
            saving = false
            switch outcome {
            case .cleared(let previous):
                cleared = previous
                draft = ""
            case .nothingToClear:
                draft = ""
            case .failed:
                failure = "The note could not be cleared."
            }
        }
    }

    /// **Undo a clear**: the earlier wording saved again, as a new revision.
    private func restore(_ previous: String) {
        guard let study, let entry else { return }
        saving = true
        failure = nil
        Task {
            let saved = if case .saved = await study.saveNote(entry: entry, text: previous, name: name) {
                true
            } else {
                false
            }
            saving = false
            if saved {
                cleared = nil
                draft = previous
            } else {
                failure = "The note could not be restored."
            }
        }
    }
}
