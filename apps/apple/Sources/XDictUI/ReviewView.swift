import SwiftUI
import XDictContract
import XDictTokens

/// **The review window** (plan-history-and-learning §5): the card in front — its word, the reader's own note — and the
/// four answers, with an undo for the grade just made. The core decides what is due and what a grade does; this view
/// carries the taps and says what came back.
public struct ReviewView: View {
    @State private var model: StudyModel
    @State private var editing = false

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
            case .failed:
                notice(String(localized: "The review list could not be read."))
            case .ready:
                if !model.conflicts.isEmpty {
                    conflictsView
                }
                if let card = model.current {
                    cardView(card)
                } else if model.conflicts.isEmpty {
                    notice(model.summary?.nextDue.map {
                        String(localized: "Nothing is due. The next card falls due at \(Self.time($0)).")
                    } ?? String(localized: "Nothing is due."))
                }
            }
        }
        .padding(Tokens.Space.xl)
        .frame(minWidth: Tokens.Window.reviewWidth, minHeight: Tokens.Window.reviewMinHeight)
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
        model.current.map {
            EntryRef(edition: Edition(rawValue: $0.target.edition), key: $0.target.entryKey,
                     occurrence: $0.target.occurrence)
        }
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
                Button("Note…") { editing = true }
                if !card.head.isEmpty {
                    Button("Undo") { Task { await model.undo(card) } }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer()
    }

    private func notice(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(verbatim: text)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
    private let width: CGFloat?
    private let done: () -> Void
    @State private var draft: String
    @State private var saving = false
    @State private var failed = false

    /// `entry` nil disables Save: a note needs a target. `width` nil fills its container (the drawer), and a sheet
    /// passes one, as a sheet sizes to its content.
    public init(study: StudyModel?, entry: EntryRef?, name: String, initial: String = "", width: CGFloat? = nil,
                done: @escaping () -> Void) {
        self.study = study
        self.entry = entry
        self.name = name
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
            if failed {
                Text("The note could not be saved.")
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(Color(nsColor: Tokens.Colour.secondaryLabel.nsColor))
            }
            SheetFooter([
                FooterAction(.cancel, title: Text("Cancel")) { done() },
                FooterAction(.primary, title: Text("Save"), isDisabled: isDisabled) { save() },
            ])
        }
        .padding(Tokens.Space.l)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var isDisabled: Bool {
        saving || entry == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        saving = true
        failed = false
        Task {
            let saved = if let study, let entry {
                await study.saveNote(entry: entry, text: draft, name: name) != nil
            } else {
                false
            }
            saving = false
            if saved {
                done()
            } else {
                failed = true
            }
        }
    }
}
