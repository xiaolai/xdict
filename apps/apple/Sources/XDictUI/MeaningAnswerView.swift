import AppKit
import SwiftUI
import XDictAI
import XDictCapture
import XDictSearch
import XDictTokens

/// **The answer to one "meaning here" tap** (plan-ai-meaning WI-6; ADR-0021 d.1, d.2; HIG audit 2026-10-23): the task's
/// title, the sentence the request was about, the explanation first, then the dictionary text it quotes with the
/// dictionary named, and the request's and an error's technical details behind disclosures. Plain text only: the
/// model's words are never rendered as markup.
public struct MeaningAnswerPane: View {
    let state: SearchWindowState
    /// The sheet shows the pane's title and source above the answer; the pane window does not (owner, 2026-10-24:
    /// its own top area is redundant — ⌘I toggles it).
    let showsHeader: Bool
    @State private var promptShown = false
    @State private var detailsShown = false
    /// The visible column's width, measured (UI04); nil until the first measurement.
    @State private var visible: CGFloat?
    /// A reveal that found nothing on the page shown now (UI11).
    @State private var revealFailed: String?
    /// The reveal whose answer may still change the pane: a later reveal, or a new answer, supersedes it (audit round 1).
    @State private var revealSerial = 0
    /// How the answer's Save as Note ended (plan-companion WI-9): one action, replaced by its outcome.
    @State private var noteState: NoteSaveState = .idle
    /// A note already on the entry: the save asks before replacing it.
    @State private var noteReplaceAsked = false
    /// **The save being run, and the payload it writes** (audit round 4, 2026-10-25): captured before the existence check, so
    /// a new answer cannot re-pair the old explanation with a newer source, and Retry keeps the same bytes.
    @State private var noteOperation = 0
    @State private var pendingNote: NotePayload?

    /// The payload one save writes, frozen from the presentation at the tap.
    struct NotePayload: Equatable {
        let text: String
        let target: MeaningTarget
    }

    /// The save's own state; the pane offers one control at a time.
    enum NoteSaveState: Equatable {
        case idle
        case checking
        case saving
        case saved
        case failed
    }

    public init(state: SearchWindowState, showsHeader: Bool = true) {
        self.state = state
        self.showsHeader = showsHeader
    }

    public var body: some View {
        // **The content follows the visible column** (UI04). macOS 27 proposes the inspector's content a container wider
        // than the visible column, so content laid out to the proposal was drawn past the pane's edge and clipped (tour
        // `main.meaningPreview`, 2026-10-20); the fix then capped it at the inspector's minimum, which left a widened
        // pane's room empty. The width is now measured where it is drawn — the part of the pane the window shows — and
        // held within the inspector's declared bounds.
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                // **The Examples section lives in this pane** (ADR-0031's owner decision, plan-reverse-examples
                // WI-5): above the Meaning answer when both are shown, alone when only a Chinese query opened it.
                if state.panes.examplesShown {
                    ExamplesSection(state: state)
                }
                if state.panes.meaningShown || !state.panes.examplesShown {
                    if showsHeader { header }
                    // **Question, sentence, answer — read top to bottom** (owner, 2026-10-26, after ../sonovo's
                    // inspector): each part of the pane has its own small heading, so the controls, the sentence they are
                    // about and the answer are not one unbroken column.
                    // **No heading over the question** (owner, 2026-10-26): the group is self-evident, and a title above
                    // it left the pane's top an empty band.
                    if state.meaning.canAsk {
                        questionControls
                    }
                    if let context = state.meaning.held.map(MeaningContext.init) {
                        PaneSection("In This Sentence") {
                            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                                MeaningContextView(context: context, speak: {
                                    state.pronounceTerm(context.term,
                                                        for: state.meaning.askingTarget ?? state.meaning.sent?.target)
                                })
                                phraseOffer
                            }
                        }
                    }
                    content
                }
            }
            .padding(Tokens.Space.l)
            .frame(width: MeaningPaneWidth.content(visible: visible), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background { VisibleWidth { visible = $0 } }
        .accessibilityIdentifier("meaning.pane")
        // **The answer's own entry supplies the sense list** (plan-companion WI-8): one fetch per edition-qualified
        // entry, made only while a request with an entry is shown.
        .task(id: state.meaning.sent) {
            if let sent = state.meaning.sent, sent.mode.carriesEntry, let target = sent.target {
                state.meaning.loadSenses(for: target)
            }
        }
        // **A reveal's failure belongs to the answer it was tried on** (audit round 1, 2026-10-25): a new answer, or a
        // new request, clears it and supersedes any reveal still pending.
        .onChange(of: state.meaning.state) {
            revealSerial += 1
            revealFailed = nil
            // **A save belongs to the answer it was made from** (audit round 4, 2026-10-25): a new answer ends the old
            // operation, so its existence check or write cannot paint its outcome under this answer.
            noteOperation += 1
            pendingNote = nil
            noteState = .idle
            noteReplaceAsked = false
        }
    }

    private var settings: MeaningSettings {
        state.meaning.settingsProvider?() ?? state.meaning.settings
    }

/// **One section of the answer pane** (owner, 2026-10-26, learned from `../sonovo`'s inspector): a small uppercase
/// heading over its content, in the system's tertiary label, so the pane reads as question, sentence, answer.
struct PaneSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text(title)
                .font(Tokens.TextRole.caption.font.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Tokens.Colour.tertiaryLabel.color)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// **The pane's purpose before any answer** (UI17): the task's title; the source is secondary.
    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(MeaningSentences.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let source = MeaningSentences.source(state.meaning.sent?.source ?? settings.source, model: settings.model, endpoint: settings.endpoint) {
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("meaning.title")
    }

    /// **The question and its controls in the pane** (contract 6; owner, 2026-10-26): the group is the action — a tab
    /// asks for its question, or shows the answer it already has — and the only other controls the chosen sense's. The
    /// identifiers are the ones the tour and the E2E read.
    /// **The group sits where the pane's column starts, in the toolbar's own size** (owner, 2026-10-26: "remove tab
    /// groups' realignment … why these icons are smaller than mainwindow's navigate icons"): the spacers that centred it
    /// were re-layout the reader had not asked for, and its glyphs were drawn smaller than the toolbar pair it imitates.
    @ViewBuilder private var questionControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            if state.meaning.hasSenseSelection {
                HStack(spacing: Tokens.Space.s) {
                    Button("Explain This Sense") { state.meaning.explain() }  // placement: inspector-row
                        .buttonStyle(.borderless)
                        .disabled(!state.meaning.senseExplainAllowed)
                        .help(state.meaning.senseExplainAllowed
                              ? String(localized: "Ask what the sense you chose means in this sentence.")
                              : String(localized: MeaningSentences.explainNeedsEntryText))
                        .accessibilityIdentifier("meaning.explain")
                    Button("Clear Choice") { state.clearSense() }  // placement: inspector-row
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("meaning.clear-sense")
                }
                if !state.meaning.senseExplainAllowed {
                    // **The reason, visible, with the way to change it** (UI16; ADR-0021 d.4): the pane says what the
                    // disabled control needs, and its button opens Settings.
                    ActionRow(.strip) {
                        Text(MeaningSentences.explainNeedsEntryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } actions: {
                        Button("AI Settings…") { SettingsRoute.shared.showPane(.ai) }
                            .accessibilityIdentifier("meaning.explain.settings")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("meaning.explain.reason")
                }
            }
        }
    }

    /// **The phrase the captured sentence holds, in the first step and every state of the search** (AI contract 5;
    /// plan-phrase-recognition WI-9; owner, 2026-10-27: "在第一步，sense in current context 里，就应该直接显示短语检测，并且，
    /// 还得有把某个短语放入卡片的功能"): the detection is drawn beside the sentence it was made for, not only when it finds
    /// something — a reader can see that the dictionaries were asked and what came back. With a phrase found, one tap
    /// asks about it and the same control as the popover's row writes it to a card. A phrase ask already made is not
    /// offered again.
    @ViewBuilder private var phraseOffer: some View {
        switch state.phrases.row {
        case .hidden:
            EmptyView()
        case .building:
            phraseLine("Reading your dictionaries for phrases…", identifier: "meaning.phrase.building")
        case .unavailable:
            phraseLine("Phrases are not available for these dictionaries.", identifier: "meaning.phrase.unavailable")
        case let .found(candidate, total, _, _, _):
            if state.meaning.held?.phrase == nil {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    HStack(spacing: Tokens.Space.sm) {
                        Button {  // placement: inspector-row
                            Task { await state.askAboutPhrase(candidate) }
                        } label: {
                            Text("Ask about “\(candidate.phrase)”")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("meaning.phrase")
                        // **The same keep the row offers** (plan-context-tools WI-4): one action, two surfaces, one state.
                        PhraseKeepControl(state: state, candidate: candidate, identifier: "meaning.phrase")
                    }
                    if total > 1 {
                        Text("The first of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One line of the phrase detection that is not a candidate: what was read, and what it found.
    private func phraseLine(_ text: LocalizedStringKey, identifier: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Tokens.Colour.secondaryLabel.color)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var content: some View {
        switch state.meaning.state {
        case .idle:
            ContentUnavailableView {
                Label("No Answer Yet", systemImage: "sparkles")
            } description: {
                // **What to do next depends on what is held** (owner, 2026-10-26): with no capture the pane says how to
                // make one; with a sentence in hand and no question asked, it points at the question above.
                if state.meaning.held == nil {
                    Text("Nothing captured yet. Hover over a word, or press ⌃⌥D, and its sentence appears here.")
                } else {
                    Text("Choose a question above.")
                }
            }
        case .asking:
            asking
        case .preview(let sent):
            preview(sent)
        default:
            if let presentation = MeaningPresenter.present(state.meaning.state, settings: settings,
                                                           sent: state.meaning.sent,
                                                           selection: state.meaning.selection) {
                answer(presentation)
            }
        }
    }

    /// **What the pane asks in the mode the reader chose** (contract 6; plan-context-tools D10): the idle copy names the
    /// button that is actually there, not the one the pane's first mode has.
    private var idleDescription: LocalizedStringKey {
        switch state.meaning.chosenMode {
        case .meaning:
            "Capture a word and choose Meaning Here beside it. XDict asks the source you chose what the word means in that sentence."
        case .translation:
            "Capture a word and choose Translate beside it. XDict asks the source you chose to translate the sentence into your language."
        case .grammar:
            "Capture a word and choose Grammar beside it. XDict asks the source you chose to explain the sentence's grammar."
        }
    }

    /// **What the ask will send, before it is sent** (ADR-0021 d.13; UI14): who receives it, the sentence, whether the
    /// entry goes, and a cut in the future tense (UI19); the exact bytes behind a disclosure, copyable. Send composes
    /// nothing new (the same bytes) and asks; Cancel sends nothing.
    private func preview(_ sent: MeaningSent) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Review before sending")
                .font(.subheadline.weight(.semibold))
            if let source = MeaningSentences.source(sent.source) {
                Text("To “\(source)”")
            }
            if let context = sent.questionContext {
                MeaningContextView(context: context, speak: { state.pronounceTerm(context.term, for: sent.target) })
            }
            Text(MeaningSentences.previewEntry(included: sent.mode.carriesEntry))
                .foregroundStyle(.secondary)
            if sent.mode == .translate, let language = sent.language {
                Text("Into \(MeaningSentences.languageName(language))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.translate.into")
            }
            senseList(previewing: true)
            if let sense = sent.sense {
                chosenSense(sense, dictionary: sent.dictionaryName)
            }
            if !sent.complete {
                Text(MeaningSentences.cut(at: sent.cutAt, sent: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $promptShown) {
                exactRequest(sent.text)
                    .accessibilityIdentifier("meaning.preview.text")
            } label: {
                Text("Exact Request")
            }
            HStack(spacing: Tokens.Space.sm) {
                Button("Send") { state.meaning.sendPreview() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.send")
                Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
            }
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.s) {
                ProgressView().controlSize(.small)  // placement: spinner
                if let source = MeaningSentences.source(state.meaning.askingSource ?? settings.source) {
                    Text("Asking “\(source)”…")
                } else {
                    Text("Asking…")
                }
            }
            if let context = state.meaning.held.map(MeaningContext.init) {
                // **The running request's own entry**, not the shown one (audit round 3): `sent` is nil until an ask
                // completes, so the frozen asking target names the dictionary whose language the term is spoken in.
                MeaningContextView(context: context, speak: {
                    state.pronounceTerm(context.term, for: state.meaning.askingTarget ?? state.meaning.sent?.target)
                })
            }
            Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
                .accessibilityIdentifier("meaning.cancel")
        }
    }

    @ViewBuilder private func answer(_ presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            answerHeader(presentation)
            explanation(presentation)
            // **The system's reading, beside the model's** (contract 6; plan-context-tools WI-10; ADR-0034 d.6): shown in
            // the grammar mode only, drawn from `NLTagger`, and never part of the question that was sent.
            systemReading()
            answerSense(presentation)
            // **The source row is shown for a grounded answer even with no quote** (owner, 2026-10-26): the dictionary a
            // does-not-fit verdict came from is the one the reader may want to change.
            if presentation.evidenceSource != nil || !presentation.quotes.isEmpty {
                evidence(presentation)
            }
            entryCoverage(presentation)
            doesNotFitOffer()
            requestDetails()
            answerActions(presentation)
        }
    }

    /// The sentence, a typed problem, a moved selection and the outcome word: what frames the answer.
    @ViewBuilder private func answerHeader(_ presentation: MeaningPresentation) -> some View {
        if let context = presentation.questionContext {
            MeaningContextView(context: context, speak: { state.pronounceTerm(context.term, for: state.meaning.sent?.target) })
        }
        if let problem = presentation.problem {
            problemView(problem, presentation: presentation)
        }
        if presentation.selectionMoved {
            Label { Text(MeaningSentences.selectionMoved) } icon: { Image(systemName: "arrow.uturn.backward") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meaning.selection-moved")
        }
        if let outcome = presentation.outcome {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(outcome).font(.subheadline.weight(.semibold))
                if let grounding = MeaningSentences.grounding(presentation.grounding) {
                    Text(grounding).font(.caption).foregroundStyle(.secondary)
                }
                // **A translation names its target** (contract 6): the language was asked for, so the pane says which one
                // was asked for even after a Settings change.
                if let sent = state.meaning.sent, sent.mode == .translate, let language = sent.language {
                    Text("Into \(MeaningSentences.languageName(language))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meaning.translate.into")
                }
            }
        }
    }

    /// **The grammar mode's evidence** (plan-context-tools WI-10): the system's tokens and tags, drawn only for a grammar
    /// answer and only for a language the coverage measurement covers; the sentence is the one the request was about.
    @ViewBuilder private func systemReading() -> some View {
        if let sent = state.meaning.sent, sent.mode == .explainGrammar,
           case .answer = state.meaning.state, let context = sent.questionContext {
            SystemReadingView(sentence: context.sentence)
        }
    }

    /// **The answer to the reader's question first** (UI10), then the source text it rests on; Copy Answer beside it.
    @ViewBuilder private func explanation(_ presentation: MeaningPresentation) -> some View {
        if !presentation.explanation.isEmpty {
            Text(verbatim: presentation.explanation)
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meaning.explanation")
            Label { Text(MeaningSentences.generated) } icon: { Image(systemName: "sparkles") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meaning.generated")
            // **Copy Answer** (plan-companion WI-10): the explanation and its quotes as text, nothing else.
            Button("Copy Answer") { copyAnswer(presentation) }  // placement: inspector-row
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("meaning.copy-answer")
        }
    }

    /// **Who answered, and the senses the answer is about** (plan-companion WI-8, WI-11): the source and model from the
    /// frozen request, the entry's rows, the chosen sense and its own cut.
    @ViewBuilder private func answerSense(_ presentation: MeaningPresentation) -> some View {
        if let sent = state.meaning.sent, sent.model != nil || !showsHeader {
            answeredBy(sent)
        }
        senseList(previewing: false)
        if let sense = presentation.chosenSense {
            chosenSense(sense, dictionary: presentation.dictionaryName)
        }
        if let coverage = presentation.senseCoverage {
            coverageLabel(coverage, identifier: "meaning.sense.coverage")
        }
    }

    /// The entry's cut, when it was sent cut: independent of whether the answer quotes anything.
    @ViewBuilder private func entryCoverage(_ presentation: MeaningPresentation) -> some View {
        if let coverage = presentation.coverage {
            coverageLabel(coverage, identifier: "meaning.coverage")
        }
    }

    /// **A cut, said the same way for the entry and the chosen sense** (audit round 3, 2026-10-25); its identifier tells
    /// the two facts apart.
    private func coverageLabel(_ text: LocalizedStringResource, identifier: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "scissors") }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier)
    }

    /// **The verdict is not the end of the question** (plan-explain-sense WI-5): the model can be asked which sense the
    /// sentence uses instead, on the same sentence and entry.
    @ViewBuilder private func doesNotFitOffer() -> some View {
        if case .answer(let answer, mode: .explainSense) = state.meaning.state, answer.outcome == .doesNotFit {
            Text(MeaningSentences.doesNotFitOffer)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Ask Which Sense It Is") {  // placement: inspector-row
                state.meaning.askSelection()
            }
            .accessibilityIdentifier("meaning.selection-ask")
        }
    }

    /// The request that produced the answer, verbatim, and its cut, behind a disclosure.
    @ViewBuilder private func requestDetails() -> some View {
        if let sent = state.meaning.sent {
            DisclosureGroup(isExpanded: $promptShown) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    exactRequest(sent.text)
                    if !sent.complete {
                        Text(MeaningSentences.cut(at: sent.cutAt, sent: true))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Request Details")
            }
            .accessibilityIdentifier("meaning.prompt")
        }
    }

    /// **An answer's actions are about the answer, never a re-sample of its question** (after tsundoku's panel; owner,
    /// 2026-10-26): tsundoku retries only a failure and asks every next question by name. XDict's next questions already
    /// have names — another sense's row, another dictionary's grounding, the ask button — and "Ask Again" sent an
    /// identical prompt to the same model for a different sample, which is a lottery, not a tool.
    /// **Save as Note** sits here when the shell wired a study model and the answer is about an entry (plan-companion WI-9).
    @ViewBuilder private func answerActions(_ presentation: MeaningPresentation) -> some View {
        if let target = state.meaning.sent?.target, state.noteSaver != nil, !presentation.explanation.isEmpty {
            saveNoteControl(presentation, target: target)
        }
    }

    /// **The reader's explicit save** (plan-companion WI-9; owner, 2026-10-25): one tap writes the explanation, its quotes
    /// and a provenance line on the entry the request was composed from. A note already there is replaced only after the
    /// pane asks; the outcome replaces the button, and a failure keeps the payload for Retry.
    @ViewBuilder private func saveNoteControl(_ presentation: MeaningPresentation, target: MeaningTarget) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            switch noteState {
            case .saved:
                Label { Text("Saved as a note.") } icon: { Image(systemName: "checkmark.circle") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.note.saved")
            case .failed:
                Label { Text("The note could not be saved.") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("meaning.note.failed")
                Button("Try Again") { retryNote() }  // placement: inspector-row
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("meaning.note.retry")
            case .checking:
                HStack(spacing: Tokens.Space.xs) {
                    ProgressView().controlSize(.small)  // placement: spinner
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            case .saving:
                HStack(spacing: Tokens.Space.xs) {
                    ProgressView().controlSize(.small)  // placement: spinner
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            case .idle:
                Button("Save as Note") {  // placement: inspector-row
                    saveNote(presentation, target: target)
                }
                .accessibilityIdentifier("meaning.note.save")
            }
        }
        .confirmationDialog("Replace the note on this entry?", isPresented: $noteReplaceAsked, titleVisibility: .visible) {
            Button("Replace", role: .destructive) {  // placement: inspector-row
                guard let payload = pendingNote else { return }
                startWrite(payload)
            }
            Button("Cancel", role: .cancel) {}  // placement: inspector-row
        }
    }

    /// Freezes the payload, then asks whether a note is already there; the button leaves `.idle` before any suspension, so a
    /// second tap cannot start a second save.
    private func saveNote(_ presentation: MeaningPresentation, target: MeaningTarget) {
        // **One save at a time** (audit round 4, 2026-10-25): a second tap that raced the first cannot start its own.
        guard noteState == .idle else { return }
        let payload = NotePayload(text: MeaningPresenter.noteText(presentation: presentation, date: Date()),
                                 target: target)
        noteOperation += 1
        checkThenWrite(payload)
    }

    /// **Every save asks first, Retry included** (audit round 4, 2026-10-25): a check that could not answer is never
    /// answered by writing straight away, which would replace a note without the question.
    private func retryNote() {
        guard let payload = pendingNote else { return }
        noteOperation += 1
        checkThenWrite(payload)
    }

    /// **The store checks and writes as one** (audit rounds 1–4, 2026-10-26): a save that would replace a note comes back
    /// asking, one saved in between is never replaced unseen, and the frozen payload is kept for a Retry either way.
    private func checkThenWrite(_ payload: NotePayload) {
        pendingNote = payload
        let mine = noteOperation
        noteState = .checking
        Task { @MainActor in
            let outcome = await state.saveNote(for: payload.target, text: payload.text, replacing: false)
            guard mine == noteOperation else { return }
            switch outcome {
            case .saved:
                noteState = .saved
            case .needsReplacement:
                noteState = .idle
                noteReplaceAsked = true
            case .failed:
                noteState = .failed
            }
        }
    }

    /// Writes the payload the reader confirmed; a newer operation's outcome is the only one the pane shows.
    private func startWrite(_ payload: NotePayload) {
        let mine = noteOperation
        noteState = .saving
        Task { @MainActor in
            let outcome = await state.saveNote(for: payload.target, text: payload.text, replacing: true)
            guard mine == noteOperation else { return }
            noteState = outcome == .failed ? .failed : .saved
        }
    }

    /// **The entry's senses, each a way into the chosen-sense question** (plan-companion WI-8): the core's own list,
    /// with the chosen one marked; a row selects its sense and asks about it in one tap. **Only the rows read for this
    /// request's entry** are shown (audit round 1, 2026-10-25): a previous answer's list never pairs its ordinal with
    /// another entry. With the entry-text switch off the rows are disabled and the pane says which switch turns them on,
    /// never hiding why; a failed read says so and can be asked again rather than passing for an entry with no senses.
    /// **`previewing` is how a tap reads** (audit round 2, 2026-10-25): in the unsent preview a row selects its sense
    /// and composes the request again; from an answer it asks about that sense.
    @ViewBuilder private func senseList(previewing: Bool) -> some View {
        switch senseDecision {
        case .hidden:
            EmptyView()
        case .failed(let target):
            senseFailure(target)
        case .rows(let target):
            senseRows(target, previewing: previewing)
        }
    }

    /// What the list shows, as one value: the view only draws it.
    var senseDecision: SenseListDecision {
        SenseListDecision.of(sentTarget: state.meaning.sent?.target, sensesTarget: state.meaning.sensesTarget,
                             status: state.meaning.sensesStatus, count: state.meaning.senses.count)
    }

    /// A failed read says so, and asks again on the reader's tap.
    private func senseFailure(_ target: MeaningTarget) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text("Senses in this entry").font(.caption).foregroundStyle(.secondary)
            Text("The senses could not be read.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try Again") { state.meaning.loadSenses(for: target) }  // placement: inspector-row
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("meaning.senses.retry")
        }
        .accessibilityIdentifier("meaning.senses.failed")
    }

    /// The projection's rows, the chosen one marked; with the entry-text switch off they are disabled and the reason is
    /// said rather than hidden.
    private func senseRows(_ target: MeaningTarget, previewing: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text("Senses in this entry").font(.caption).foregroundStyle(.secondary)
            ForEach(state.meaning.senses) { row in
                Button { askAbout(row, target: target, previewing: previewing) } label: {  // placement: inspector-row
                    senseRow(row, chosen: state.meaning.sent?.sense?.id == row.id)
                }
                .buttonStyle(.plain)
                .disabled(!settings.sendEntryText)
                .accessibilityIdentifier("meaning.senses.\(row.id)")
            }
            if !settings.sendEntryText {
                Text(MeaningSentences.explainNeedsEntryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("meaning.senses")
    }

    private func askAbout(_ row: MeaningSession.SenseRow, target: MeaningTarget, previewing: Bool) {
        state.meaning.select(MeaningSelection(dictionary: target.dictionary, entry: target.entry, sense: row.id,
                                              dictionaryName: state.source(for: target.dictionary)?.name))
        if previewing {
            state.meaning.preview()
        } else {
            state.meaning.explain()
        }
    }

    private func senseRow(_ row: MeaningSession.SenseRow, chosen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            if let label = row.label, !label.isEmpty {
                Text(verbatim: label).font(Tokens.TextRole.caption.font.monospaced())
            } else {
                Text(verbatim: "#\(row.id)").font(Tokens.TextRole.caption.font.monospaced())
            }
            if let section = row.section, !section.isEmpty {
                Text(verbatim: section).font(Tokens.TextRole.caption.font).foregroundStyle(.secondary)
            }
            Text(verbatim: row.snippet)
                .font(ReadingText.body.font)
                .lineLimit(1)
                .truncationMode(.tail)
            if !row.whole {
                Text("partial text").font(Tokens.TextRole.caption.font).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(chosen ? .primary : .secondary)
        .padding(.vertical, Tokens.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The source the request went to and, when it named one, the model it asked for.
    private func answeredBy(_ sent: MeaningSent) -> some View {
        var parts: [String] = []
        if let source = MeaningSentences.source(sent.source) { parts.append(String(localized: source)) }
        if let model = sent.model, !model.isEmpty { parts.append(model) }
        return Text(verbatim: parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("meaning.answered-by")
    }

    private func copyAnswer(_ presentation: MeaningPresentation) {
        copyToPasteboard(presentation.copyText)
    }

    /// The pasteboard, once: every copy control writes plain text the same way.
    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// **The plain problem, its next step, then the code** (UI15, UI20): an ordinary reader acts on the first two; the
    /// code is for support, behind a disclosure with Copy Details.
    private func problemView(_ problem: LocalizedStringResource, presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Label {
                Text(problem)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("meaning.problem")
            switch presentation.recovery {
            case .openAISettings:
                Button("Open AI Settings…") { SettingsRoute.shared.showPane(.ai) }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.recover.settings")
            case .retry:
                Button("Try Again") { state.askAgain() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.recover.retry")
            case nil:
                EmptyView()
            }
            if let code = presentation.code {
                DisclosureGroup(isExpanded: $detailsShown) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
                        Text(verbatim: code).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy Details") {  // placement: inspector-row
                            copyToPasteboard(MeaningSentences.errorDetails(code: code))
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                } label: {
                    Text("Error Details").font(.caption)
                }
                .accessibilityIdentifier("meaning.error-details")
            }
        }
    }

    /// **The dictionary text the answer quotes, with its dictionary** (UI10, UI11): after the explanation, each quote
    /// one step from its place in the entry; a reveal that finds nothing says so. **The dictionary is a choice when the
    /// page has more than one** (owner, 2026-10-26): choosing one asks the same question on that dictionary's entry,
    /// instead of the entry the page happened to show first.
    private func evidence(_ presentation: MeaningPresentation) -> some View {
        let choices = state.groundingChoices
        let choosing = choices.count > 1 && presentation.evidenceTarget != nil && settings.sendEntryText
        return VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            if let name = presentation.evidenceSource {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    Text(MeaningSentences.evidence)
                    if choosing {
                        Menu {  // placement: inspector-row
                            Picker(selection: Binding(get: { presentation.evidenceTarget },
                                                      set: { chosen in
                                                          if let chosen { state.askMeaning(in: chosen) }
                                                      })) {
                                ForEach(choices) { choice in
                                    Text(choice.name).tag(Optional(choice.target))
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(verbatim: "· \(name)")
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.visible)
                        .fixedSize()
                        .help("Choose the dictionary this answer is grounded in.")
                        .accessibilityIdentifier("meaning.evidence.dictionary")
                    } else {
                        Text(verbatim: "· \(name)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: choosing ? .contain : .combine)
                .accessibilityIdentifier("meaning.evidence.source")
            }
            ForEach(Array(presentation.quotes.enumerated()), id: \.offset) { _, quote in
                quoteRow(quote, target: presentation.evidenceTarget)
            }
        }
    }

    /// One quoted sense: its text, the way into the entry, and a failed reveal said beside it.
    private func quoteRow(_ quote: String, target: MeaningTarget?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text(verbatim: quote)
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meaning.quote")
            Button("Show in the Entry") {  // placement: inspector-row
                reveal(quote, in: target)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityIdentifier("meaning.show-in-entry")
            if revealFailed == quote {
                Text(MeaningSentences.revealFailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.reveal-failed")
            }
        }
    }

    private func reveal(_ quote: String, in target: MeaningTarget?) {
        revealSerial += 1
        let mine = revealSerial
        revealFailed = nil
        let found = state.revealEvidence(quote, target: target)
        Task { @MainActor in
            // **The verdict is read before the guard, never after it** (verification round 1, 2026-10-25): checking the
            // generation first let a reveal that finished later still write its failure.
            let nothing = await found.value == false
            guard mine == revealSerial else { return }
            if nothing { revealFailed = quote }
        }
    }

    /// The exact bytes, scrollable, and a Copy button: what a careful reader or support needs, one step away (UI14).
    private func exactRequest(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            PromptText(text: text)
            Button("Copy Request") {  // placement: inspector-row
                copyToPasteboard(text)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// **The sense as printed** (plan-explain-sense WI-5): its label and its text, verbatim from the core's projection,
    /// and the dictionary it was clicked in when that is not obvious.
    @ViewBuilder private func chosenSense(_ sense: AISense, dictionary: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text(MeaningSentences.chosenSense).font(.caption).foregroundStyle(.secondary)
            if let label = sense.label, !label.isEmpty {
                Text(verbatim: label).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(verbatim: sense.text)
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meaning.sense")
            if let dictionary {
                Text(verbatim: dictionary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// **What the sense list shows for one presentation** (audit round 2, 2026-10-25): the target gate and the failure state
/// as one pure decision, so they are tested without rendering a view. Rows are shown only for the entry they were read
/// from; a failed read says so; an entry with no senses shows nothing.
enum SenseListDecision: Equatable {
    case hidden
    case failed(MeaningTarget)
    case rows(MeaningTarget)

    static func of(sentTarget: MeaningTarget?, sensesTarget: MeaningTarget?,
                   status: MeaningSession.SensesStatus?, count: Int) -> SenseListDecision {
        guard let sentTarget, sentTarget == sensesTarget else { return .hidden }
        if status == .failed { return .failed(sentTarget) }
        return count > 0 ? .rows(sentTarget) : .hidden
    }
}

/// **The sentence a request is about, the word emphasized** (UI09): an ellipsis says where the capture cut it.
struct MeaningContextView: View {
    let context: MeaningContext
    /// **The pane's speaker** (plan-companion WI-7): the captured term in the answer's dictionary language. Nil where the
    /// context is shown without an ask (Settings' preview).
    var speak: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack(spacing: Tokens.Space.xs) {
                if let speak {
                    // A glyph beside the heading it speaks for, not a trailing action (plan-companion WI-7).
                    Button(action: speak) { Image(systemName: "speaker.wave.2") }  // placement: glyph
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Pronounce"))
                        .accessibilityIdentifier("meaning.pronounce")
                }
                Text(MeaningSentences.contextHeading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(Self.attributed(context))
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // **The dictionary's spelling of a phrase ask** (AI contract 5): the term is the reader's own words, and
            // this says which key the entry was looked up by.
            if let phrase = context.phrase {
                Text("The dictionary spells it “\(phrase)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meaning.context")
    }

    /// The sentence with the term strongly emphasized at its range, and an ellipsis at each end the capture cut.
    static func attributed(_ context: MeaningContext) -> AttributedString {
        var sentence = AttributedString(context.sentence)
        if let range = context.range, let found = Range(range, in: context.sentence),
           let marked = Range<AttributedString.Index>(found, in: sentence) {
            sentence[marked].inlinePresentationIntent = .stronglyEmphasized
        }
        var out = AttributedString()
        if context.cut.contains(.start) { out += AttributedString("…") }
        out += sentence
        if context.cut.contains(.end) { out += AttributedString("…") }
        return out
    }
}

/// **The answer pane's width** (UI04): the visible column's, within the inspector's declared bounds — the promised
/// minimum until it is measured, never wider than the declared maximum.
enum MeaningPaneWidth {
    static let minimum = Tokens.Window.meaningPaneMin
    static let maximum = Tokens.Window.meaningPaneMax

    static func content(visible: CGFloat?) -> CGFloat {
        guard let visible else { return minimum }
        return min(max(visible, minimum), maximum)
    }
}

/// **The width of the part of a view the window shows** (UI04): its frame clipped by its ancestors and by the window's
/// content, measured in AppKit, where the clipping happens, not taken from SwiftUI's proposal.
struct VisibleWidth: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: NSView {
        var changed: ((CGFloat) -> Void)?
        private var last: CGFloat?
        private var pending = false

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                // **The window's own resizes count** (owner, 2026-10-24): the drawer grows the pane window after this
                // view's layout, and without this the last width measured was a narrow intermediate one — the content
                // then sat at its minimum with a wide empty margin beside it.
                for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                                                           name: name, object: window)
                }
            }
            scheduleMeasurement()
        }

        @objc private func windowChanged(_ notification: Notification) { scheduleMeasurement() }

        private func scheduleMeasurement() {
            guard !pending else { return }
            pending = true
            // A synchronous callback mutates the SwiftUI state that sizes this very view during native layout.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.measure()
            }
        }

        private func measure() {
            guard let window, let content = window.contentView else { return }
            let inWindow = convert(visibleRect, to: nil)
            let shown = inWindow.intersection(content.convert(content.bounds, to: nil))
            guard !shown.isNull, shown.width > 0 else { return }
            let width = shown.width.rounded(.down)
            guard width != last else { return }
            last = width
            changed?(width)
        }
    }
}

/// **The exact request, scrollable and verbatim** (ADR-0021 d.13): the response contract's JSON line has no spaces to
/// wrap at, and the inspector proposes its content a container wider than the visible column, so plain `Text` was drawn
/// past the pane's edge and clipped (tour `main.meaningPreview`, 2026-10-20). Two scrollers keep every byte reachable
/// without changing it.
struct PromptText: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Tokens.Control.promptEditor)
        .accessibilityIdentifier("meaning.prompt.text")
    }
}

/// **The pane's one ask button on the presented term** (ADR-0021 d.1; contract 6): a tap, never automatic, and the
/// label says which question the chosen mode asks. The popover expands into the window it hands the sentence to; the
/// main window opens the answer pane in place.
struct MeaningAskButton: View {
    let enabled: Bool
    var mode: MeaningAskMode = .meaning
    let action: () -> Void

    var body: some View {
        Button {  // placement: meaning-chip
            action()
        } label: {
            switch mode {
            case .meaning: Label("Meaning Here", systemImage: "sparkles")
            case .translation: Label("Translate", systemImage: "character.bubble")
            case .grammar: Label("Grammar", systemImage: "text.magnifyingglass")
            }
        }
        .disabled(!enabled)
        .help(mode.help)
        .accessibilityIdentifier("meaning.ask")
    }
}

extension MeaningAskMode {
    /// The glyph the pane's question group draws (owner, 2026-10-26): the same three the ask button uses.
    var symbol: String {
        switch self {
        case .meaning: "sparkles"
        case .translation: "character.bubble"
        case .grammar: "text.magnifyingglass"
        }
    }

    /// The button's one line of help: what the tap sends and what comes back.
    var help: LocalizedStringKey {
        switch self {
        case .meaning: "Ask the source you chose what this word means in this sentence."
        case .translation: "Ask the source you chose to translate this sentence into your language."
        case .grammar: "Ask the source you chose to explain this sentence's grammar."
        }
    }

    /// The segmented control's short label (`meaning.mode`).
    var label: LocalizedStringKey {
        switch self {
        case .meaning: "Meaning"
        case .translation: "Translate"
        case .grammar: "Grammar"
        }
    }
}
