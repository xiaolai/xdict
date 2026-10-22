import Foundation
import Observation
import XDictAI
import XDictCapture
import XDictClient
import XDictContract

/// **What the reader chose as the source** (ADR-0021 d.3, d.4): the kind, the address it talks to, the disclosure switch
/// that governs every source alike, the language the answer is written in and an edited instruction template. The key is
/// held in memory only and never written to a defaults database; Settings keeps it in the Keychain (WI-6).
public struct MeaningSettings: Sendable, Equatable {
    /// The chosen source; nil when the reader has set none, and the ask then says so.
    public var source: AIProviderKind?
    /// An `http` source's address: a cloud endpoint or a server the reader runs. The app promises nothing about it.
    public var endpoint: URL?
    public var model: String
    public var key: String?
    /// **Whether the key belongs to the chosen endpoint row**: true only for the cloud endpoint (ADR-0021 d.3). A key left
    /// from the cloud row is never sent to a server selected as local — the audit's finding, 2026-10-20.
    public var usesKey: Bool
    /// **The reader's switch** (ADR-0021 d.4): may the entry's text leave XDict? Off by default, and one rule for every
    /// source — a loopback address is not an exemption.
    public var sendEntryText: Bool
    /// The language the explanation is written in, as a BCP 47 tag.
    public var language: String
    /// The reader's edited templates, by question kind; a kind absent here uses the shipped default for `language`
    /// (ADR-0021 d.13). One template per kind: a grounded edit carries `{entry}`, a sentence-only one may not, and the
    /// chosen-sense one carries `{entry}` and `{sense}` (contract 3).
    public var templates: [AIMode: String]

    public init(source: AIProviderKind? = nil, endpoint: URL? = nil, model: String = "", key: String? = nil,
                usesKey: Bool = false, sendEntryText: Bool = false, language: String = "en",
                templates: [AIMode: String] = [:]) {
        self.source = source
        self.endpoint = endpoint
        self.model = model
        self.key = key
        self.usesKey = usesKey
        self.sendEntryText = sendEntryText
        self.language = language
        self.templates = templates
    }

    /// The template an ask of `mode` uses: the reader's edit, else the shipped default of this language, else English's.
    public func template(for mode: AIMode) -> String? {
        templates[mode] ?? AITemplates.defaultTemplate(language: language, mode: mode)
            ?? AITemplates.defaultTemplate(language: "en", mode: mode)
    }

    /// No source chosen: an ask is refused with `noSource`, and nothing is sent anywhere.
    public static let off = MeaningSettings()
}

/// **Where an ask came from**: the capture request and generation of the presentation it belongs to (ADR-0014 d.4),
/// carried so the instruments can name it. Memory only, like everything else here.
public struct MeaningOrigin: Hashable, Sendable {
    public let request: Int
    public let generation: Int

    public init(request: Int, generation: Int) {
        self.request = request
        self.generation = generation
    }
}

/// **The sentence, handed from one presentation to the next** (I5, ADR-0021 d.4): the popover's captured term, its
/// sentence and the term's range, handed to the window it expands into — explicitly, once, owned by that presentation.
/// Never persisted and never in the trail: a `Visit` is stored, this is not.
public struct MeaningHandoff: Sendable {
    public let term: String
    public let sentence: String
    /// The term's range in the sentence, in UTF-16 units; nil when the capture carried none.
    public let range: NSRange?
    /// The ends of the sentence the capture may have cut — the history's own `cut` bits (ADR-0023).
    public let cut: CutEnds
    public let origin: MeaningOrigin

    public init(term: String, sentence: String, range: NSRange?, cut: CutEnds = [], origin: MeaningOrigin) {
        self.term = term
        self.sentence = sentence
        self.range = range
        self.cut = cut
        self.origin = origin
    }
}

/// The bounds a meaning ask works under (ADR-0021 d.2, d.5). The core's ceiling is `Limits.maxTextBytes`; this is the
/// pane's own, smaller budget: 256 KiB keeps a large real entry whole inside the composer's 1 MiB question ceiling, and a
/// cut entry is sent with `complete: false`, which the answer's rules honour (`noMatchingSense` never over a cut).
public enum MeaningBudget {
    public static let entryTextBytes: UInt64 = 256 << 10
}

/// **The composed question as it was sent** (ADR-0021 d.13): the exact bytes, the mode, and whether the entry was cut
/// before it went. Kept in memory for the presentation only, so the answer pane's View the prompt shows what was really
/// sent, never a re-render that may differ.
public struct MeaningSent: Sendable, Equatable {
    public let text: String
    public let mode: AIMode
    /// **The source the request was composed for**, so an answer is never relabelled after the reader switches sources.
    public let source: AIProviderKind?
    /// False when the entry's budget cut it (`entry_text`'s `complete`); always true in `sentenceOnly` mode.
    public let complete: Bool
    public let cutAt: UInt64
    /// **The chosen sense**, in `explainSense` mode only: what the request named, and what the answer is validated
    /// against. Kept with the request so the pane shows the sense that was sent, not the one selected since.
    public let sense: AISense?
    /// The dictionary the chosen sense was clicked in, as the reader knows it: on the All page the frame's own, never
    /// the one that happens to be shown (plan-explain-sense WI-5).
    public let dictionaryName: String?

    public init(text: String, mode: AIMode, source: AIProviderKind?, complete: Bool, cutAt: UInt64,
                sense: AISense? = nil, dictionaryName: String? = nil) {
        self.text = text
        self.mode = mode
        self.source = source
        self.complete = complete
        self.cutAt = cutAt
        self.sense = sense
        self.dictionaryName = dictionaryName
    }
}

/// **One entry an operation is about** (plan-explain-sense WI-5): the dictionary's handle and the entry's reference, in
/// the frame the reader is reading. Carried as a value, so an operation's target cannot drift with the window.
public struct MeaningTarget: Equatable, Sendable {
    public let dictionary: DictId
    public let entry: EntryRef

    public init(dictionary: DictId, entry: EntryRef) {
        self.dictionary = dictionary
        self.entry = entry
    }
}

/// **The sense the reader chose, and the entry it was clicked in** (plan-explain-sense WI-5; ADR-0029 d.6): an
/// operation's target, immutable once chosen. The window validates the click against the frame it presents; the session
/// reads the sense's text from the core's projection at compose time, never from the page (ADR-0029 d.2).
public struct MeaningSelection: Equatable, Sendable {
    public let dictionary: DictId
    public let entry: EntryRef
    /// The core's ordinal, as `data-xdict-sense` writes it.
    public let sense: UInt32
    /// The dictionary as the reader knows it, for the pane's label; nil when the window has no name.
    public let dictionaryName: String?

    public init(dictionary: DictId, entry: EntryRef, sense: UInt32, dictionaryName: String? = nil) {
        self.dictionary = dictionary
        self.entry = entry
        self.sense = sense
        self.dictionaryName = dictionaryName
    }
}

/// **One "meaning here" ask** (plan-ai-meaning WI-5): the reader's term and its sentence, the entry's text only under the
/// switch, one source, one answer — and nothing else. Its states are total: idle, asking, an answer, an invalid answer,
/// an unavailable one, or cancelled. It keeps no history: the next ask replaces the last, and `clear()` (the
/// presentation's end) drops the sentence.
///
/// **One ask at a time, one source** (ADR-0021 d.3): a newer ask, Escape or the presentation's end cancels the one in
/// flight and nothing it returns is shown. The provider is the reader's chosen one; a failure is reported as typed, never
/// retried on another source.
@MainActor
@Observable
public final class MeaningSession {
    /// Why no answer came: no source chosen, no captured sentence, no entry drawn (or it could not be read), or the
    /// source's own typed failure.
    public enum Unavailable: Equatable, Sendable {
        case noSource
        case noContext
        case noEntry
        case entryUnreadable
        /// **The disclosure switch (or so the mode) changed while the ask was being prepared** (plan-explain-sense
        /// WI-2, ADR-0029 d.5): nothing was sent. The switch is re-read after the entry fetch and after the queue's
        /// permit, immediately before the provider call — not only at the tap.
        case consentChanged
        /// **The chosen sense is not in the entry's projection** (plan-explain-sense WI-5): the page named an ordinal
        /// the core did not write, so nothing is sent and no sense is guessed.
        case noSense
        /// The chosen-sense question needs the reader's entry-text switch: it has no sentence-only variant.
        case entryTextOff
        case provider(AIProviderError)
    }

    public enum State: Equatable, Sendable {
        case idle
        case asking
        /// A validated answer, with the mode it was asked in: `sentenceOnly` answers are shown as ungrounded.
        case answer(AIAnswer, mode: AIMode)
        /// **The request as it would be sent**, composed but not sent (ADR-0021 d.13's preview before the first send).
        case preview(MeaningSent)
        /// The template could not compose the question (a dropped placeholder, an unknown one, over its bound).
        case template(AIComposeError)
        /// The model's answer failed validation. Shown as a failure, never repaired into a plausible one.
        case invalid(AIAnswerError)
        case unavailable(Unavailable)
        case cancelled
    }

    /// **The entry a held sentence belongs to**, as the presentation drew it. Opaque to the session: it is only ever
    /// compared, so the sentence survives exactly the entry its presentation drew first.
    public struct Subject: Hashable, Sendable {
        public let dictionary: UUID
        public let key: String
        public let occurrence: UInt32

        public init(dictionary: UUID, key: String, occurrence: UInt32) {
            self.dictionary = dictionary
            self.key = key
            self.occurrence = occurrence
        }
    }

    public private(set) var state: State = .idle
    /// What the reader chose, read at each ask: a change in Settings applies to the next one.
    public var settings: MeaningSettings = .off
    /// **Where the reader's choices really live** (WI-6): Settings ▸ AI's store, read at each ask so a change applies to
    /// the next one. Nil in tests, which set `settings` directly.
    @ObservationIgnored public var settingsProvider: (@MainActor () -> MeaningSettings)?
    /// The question the last ask composed and sent, for View the prompt; nil before one and dropped with the sentence.
    public private(set) var sent: MeaningSent?
    /// The presentation's sentence while one is presented: memory only, replaced by the next presentation and dropped
    /// by `clear()`. Never logged, never stored.
    public private(set) var held: MeaningHandoff?
    /// The entry the held sentence belongs to: bound by the first `drawn` after the hold.
    public private(set) var subject: Subject?
    /// **What was drawn when the subject was bound**: the ask compares the window's presentation with it, so a
    /// presentation that moved between the draw and the ask is refused rather than sent (verification finding, 2026-10-20).
    @ObservationIgnored private var boundTarget: (DictId, EntryRef)?
    /// **An adoption is under way and its presentation has not been seen**: a queued presentation of the window's previous
    /// place may still equal the model's current value, so nothing but the adoption's own lookup may bind the sentence
    /// (verification finding, 2026-10-20).
    @ObservationIgnored private var awaitsAdoptedPlace = false
    /// The lookup the adoption itself began, reported with the hand-off it belongs to; nil until then.
    @ObservationIgnored private var adoptionSerial: Int?
    /// **Which hand-off the sentence is**: a callback from an adoption a newer hand-off superseded must not name the
    /// lookup for the sentence now held (verification finding, 2026-10-20).
    public private(set) var handoffToken = 0
    /// The settings a preview was composed with: Send refuses if they have changed, so what is sent is what was shown.
    @ObservationIgnored private var previewSettings: MeaningSettings?
    /// A hand-off's ask waits for the entry its sentence belongs to (audit finding, 2026-10-20): asking at the hand-off
    /// used the window's previous entry, or none in a new window.
    @ObservationIgnored private var askWhenDrawn = false
    /// The entry the deferred ask waits for: a stale presentation's draw must not start it.
    @ObservationIgnored private var askWhenDrawnExpected: Subject?
    /// The composition a preview showed: Send transmits exactly these bytes, not a recomposition.
    @ObservationIgnored private var previewEntry: AIEntryText?
    /// **The sense the reader chose in this presentation** (plan-explain-sense WI-5): set by `select`, dropped with the
    /// sentence or a different entry. The window has already matched it to the frame it was clicked in.
    public private(set) var selection: MeaningSelection?
    /// The operation a preview showed: its mode and its sense, so Send refuses a different one and Ask Again repeats
    /// this one rather than the switch's mode read again.
    @ObservationIgnored private var previewOperation: Operation?
    /// The operation whose result is shown: what Ask Again repeats.
    @ObservationIgnored private var lastOperation: Operation?
    /// The operation a deferred ask (a hand-off before its entry drew) will run.
    @ObservationIgnored private var askWhenDrawnOperation: Operation?

    @ObservationIgnored private let fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>
    @ObservationIgnored private let presented: @MainActor () -> (DictId, EntryRef)?
    @ObservationIgnored private let makeProvider: @Sendable (MeaningSettings) throws(AIProviderError) -> any AIProvider
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by every ask, cancel and clear: a task finishing after one of them changes nothing.
    @ObservationIgnored private var generation = 0

    /// - `fetchEntryText` is `entry_text` through the service (contract 8), under a text budget.
    /// - `presented` is the entry drawn now: the ask's edition-qualified target.
    /// - `makeProvider` builds the source `settings` names (a fake in the tests).
    public init(fetchEntryText: @escaping @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>,
                presented: @escaping @MainActor () -> (DictId, EntryRef)?,
                makeProvider: @escaping @Sendable (MeaningSettings) throws(AIProviderError) -> any AIProvider) {
        self.fetchEntryText = fetchEntryText
        self.presented = presented
        self.makeProvider = makeProvider
    }

    /// Whether the ask button has something to ask about. The source is the settings' business; a missing one says so
    /// only when the reader asks.
    public var canAsk: Bool { held != nil }

    /// **The row's chosen-sense button has a sense to explain**: a sentence is held and the reader selected one of its
    /// entry's senses (plan-explain-sense WI-5).
    public var hasSenseSelection: Bool { held != nil && selection != nil }

    /// Whether the chosen-sense ask may send the entry: its one consent rule, the reader's switch. The button is shown
    /// disabled with the reason when this is false, never silently absent (ADR-0021 d.4).
    public var senseExplainAllowed: Bool { (settingsProvider?() ?? settings).sendEntryText }

    /// Whether a tap's ask is still waiting for the entry to draw: the window answers a lookup that settles with nothing
    /// drawn through `noEntry()`, rather than dropping the ask. (Verification finding, 2026-10-20.)
    public var isWaitingToAsk: Bool { askWhenDrawn }

    public var isAsking: Bool { state == .asking }

    /// **The presentation holds a sentence**: a delivery, or a hand-off from an expanding popover. Cancels any ask in
    /// flight — it was about the previous presentation — and drops its answer, which was about the last one's.
    public func hold(_ handoff: MeaningHandoff, asking: Bool = false, expecting: Subject? = nil,
                     adopted: Bool = false) {
        abandon()
        held = handoff
        subject = nil
        boundTarget = nil
        awaitsAdoptedPlace = adopted
        adoptionSerial = nil
        handoffToken += 1
        sent = nil
        previewSettings = nil
        previewEntry = nil
        selection = nil
        previewOperation = nil
        lastOperation = nil
        askWhenDrawnOperation = nil
        askWhenDrawn = asking
        // The entry the sentence belongs to is remembered even without an ask owed: a manual ask before it draws must
        // wait for it, not ground in whatever the window shows (verification finding, 2026-10-20).
        askWhenDrawnExpected = expecting
        state = .idle
    }

    /// **The reader selected a sense** (plan-explain-sense WI-5; ADR-0029 d.6): the choice is this presentation's, and
    /// a new one makes the last request and answer about another sense — they are dropped, and an ask in flight is
    /// cancelled, so a late answer to the old one is never shown as this selection's.
    public func select(_ selection: MeaningSelection) {
        guard held != nil else { return }
        guard self.selection != selection else { return }
        abandon()
        // A tap that was still waiting for its entry is the old operation's: a selection is the reader moving on.
        askWhenDrawn = false
        askWhenDrawnOperation = nil
        self.selection = selection
        sent = nil
        previewSettings = nil
        previewEntry = nil
        previewOperation = nil
        state = .idle
    }

    /// **An entry was drawn**: the first one after the hold is the sentence's. Any other drops the sentence, so an ask
    /// after the reader moved on answers `noContext` rather than sending an entry the sentence is not about.
    /// **The adoption's own lookup began**: only a callback carrying the current hand-off names it; one from a superseded
    /// hand-off is ignored.
    public func adopted(_ serial: Int, handoff: Int) {
        guard awaitsAdoptedPlace, handoff == handoffToken else { return }
        adoptionSerial = serial
    }

    public func drawn(_ subject: Subject, target: (DictId, EntryRef)? = nil, lookup: Int? = nil) {
        guard held != nil else { return }
        // **The sentence's own lookup**: while an adoption is under way, a presentation queued before it — or one an
        // earlier navigation produced — may be on screen (and even equal the model's value); it may be shown, never bound.
        if awaitsAdoptedPlace, self.subject == nil {
            guard let adoptionSerial, lookup == adoptionSerial else { return }
        }
        // **The sentence's own entry**: until it draws, no other presentation binds it, ask owed or not.
        if let expected = askWhenDrawnExpected, subject != expected { return }
        if askWhenDrawn {
            // A deferred ask waits for its own entry; another presentation's draw is not the one the reader asked about.
            // (Without an expected subject — a caller with none — the first draw is the one.)
            askWhenDrawn = false
            awaitsAdoptedPlace = false
            // Bound now: the bound target guards later presentations, so the expectation has done its work.
            askWhenDrawnExpected = nil
            self.subject = subject
            boundTarget = target
            // The operation is the one the tap chose, not the switch read again at the draw.
            let operation = askWhenDrawnOperation
            askWhenDrawnOperation = nil
            if let operation {
                ask(operation: operation)
            } else {
                ask()
            }
            return
        }
        guard let bound = self.subject else {
            self.subject = subject
            boundTarget = target
            awaitsAdoptedPlace = false
            // **The expectation has done its work once the sentence's entry binds** (audit finding, 2026-10-23): left
            // standing, it would make every later presentation return here instead of dropping the sentence.
            askWhenDrawnExpected = nil
            return
        }
        if bound != subject { clear() }
    }

    /// **The reader asked, but the adopted lookup drew nothing**: the sentence is held, and the pane says why no ask can
    /// be grounded. (Verification finding, 2026-10-20: the tap used to be lost.)
    public func noEntry() {
        abandon()
        state = .unavailable(.noEntry)
    }

    /// **The presentation ended**: the sentence goes, and so does the ask in flight and its answer.
    public func clear() {
        abandon()
        held = nil
        subject = nil
        boundTarget = nil
        awaitsAdoptedPlace = false
        adoptionSerial = nil
        sent = nil
        previewSettings = nil
        previewEntry = nil
        selection = nil
        previewOperation = nil
        lastOperation = nil
        askWhenDrawnOperation = nil
        askWhenDrawn = false
        askWhenDrawnExpected = nil
        state = .idle
    }

    /// Escape, a newer ask, or closing: the ask in flight ends, and what it would have returned is not shown.
    public func cancel() {
        abandon()
        // **The sentence keeps the entry it belongs to** (verification finding, 2026-10-20): cancelling stops the ask, not
        // the binding; a second ask must still wait for that entry rather than sample whatever the window shows.
        askWhenDrawn = false
        askWhenDrawnOperation = nil
        if case .preview = state {
            // **Cancel on a preview means dismiss it** (audit finding, 2026-10-20); it used to change nothing.
            sent = nil
            previewSettings = nil
            previewEntry = nil
            previewOperation = nil
            state = .idle
            return
        }
        if state == .asking { state = .cancelled }
    }

    /// The reader asked ("Meaning Here"): the model chooses the sense. The chosen-sense ask is `explain()`.
    public func ask() {
        let chosen = settingsProvider?() ?? settings
        ask(operation: Operation(mode: chosen.sendEntryText ? .grounded : .sentenceOnly, selection: nil, target: nil))
    }

    /// **The reader asks about the sense they selected** (plan-explain-sense WI-5; ADR-0029 d.6): the entry's text and
    /// the chosen sense go to the source, and the answer says whether the sense fits. It has no sentence-only variant:
    /// with the switch off, the row says so and nothing is sent.
    public func explain() {
        let chosen = settingsProvider?() ?? settings
        guard chosen.sendEntryText else {
            state = .unavailable(.entryTextOff)
            return
        }
        guard let selection else {
            state = .unavailable(.noSense)
            return
        }
        ask(operation: Operation(mode: .explainSense, selection: selection, target: nil))
    }

    /// **Ask Again repeats the operation that produced what is shown**: its mode and its chosen sense, not the switch
    /// read again at the tap (plan-explain-sense WI-5). The send boundary still re-reads the switch, so a switched-off
    /// entry is never sent.
    public func askAgain() {
        guard let lastOperation else {
            ask()
            return
        }
        ask(operation: lastOperation)
    }

    /// **After a `doesNotFit` verdict**: ask the model which sense the sentence uses instead (plan-explain-sense WI-5).
    /// It is the ordinary grounded ask — the model selects — and needs the switch for the same reason.
    public func askSelection() {
        let chosen = settingsProvider?() ?? settings
        guard chosen.sendEntryText else {
            state = .unavailable(.entryTextOff)
            return
        }
        // **The frame the reader was reading** (plan-explain-sense WI-5): on the All page the chosen sense may be in a
        // dictionary other than the shown one, and the selection ask must ground in that frame's entry.
        let target = selection.map { MeaningTarget(dictionary: $0.dictionary, entry: $0.entry) }
        ask(operation: Operation(mode: .grounded, selection: nil, target: target))
    }

    /// One ask's kind and target, as an immutable value: the mode, the chosen sense when the mode has one, and an
    /// explicit entry when the ask is about a frame rather than the shown one.
    private struct Operation: Equatable {
        let mode: AIMode
        let selection: MeaningSelection?
        let target: MeaningTarget?
    }

    /// The operation a fresh ask would run from the reader's choices: the chosen sense only under the switch that lets
    /// the entry leave, since the chosen-sense question always sends it.
    private func operation(for chosen: MeaningSettings, selection: MeaningSelection?) -> Operation {
        if let selection, chosen.sendEntryText {
            return Operation(mode: .explainSense, selection: selection, target: nil)
        }
        return Operation(mode: chosen.sendEntryText ? .grounded : .sentenceOnly, selection: nil, target: nil)
    }

    /// One operation: compose, fetch the entry under the switch, ask the one source, validate. A preview's Send takes
    /// its bytes from the preview, never a recomposition.
    private func ask(operation: Operation) {
        // **Any early return still ends the previous work** (audit finding, 2026-10-20): an ask refused for lack of a
        // source must not leave the last task running to overwrite this state.
        abandon()
        if case .preview(let previewed) = state {
            let current = settingsProvider?() ?? settings
            // **The same operation, not only the same settings**: a new selection makes another request, while a
            // sentence-only preview ignores the selection and is still the one shown.
            guard current == previewSettings, self.operation(for: current, selection: selection) == previewOperation else {
                // The prompt, the switch or the chosen sense changed after the preview: sending would differ from what
                // was shown.
                sent = nil
                previewSettings = nil
                previewEntry = nil
                previewOperation = nil
                state = .cancelled
                return
            }
            // **Send transmits the previewed bytes themselves**: no refetch, no recomposition, so a dictionary that
            // changed between Preview and Send cannot change what leaves (audit follow-up, 2026-10-20).
            let operation = previewOperation
                ?? Operation(mode: previewed.mode, selection: nil, target: nil)
            let entry = previewEntry
            previewSettings = nil
            previewEntry = nil
            previewOperation = nil
            generation += 1
            let mine = generation
            sent = previewed
            state = .asking
            lastOperation = operation
            let makeProvider = self.makeProvider
            let recheck = Self.consentReader(self)
            running = Task { [weak self] in
                let outcome = await Self.performSent(sent: previewed, entry: entry, settings: current,
                                                     makeProvider: makeProvider, recheck: recheck)
                guard let self, self.generation == mine else { return }
                self.running = nil
                self.state = outcome.state
                self.sent = outcome.sent
            }
            return
        }
        guard let handoff = held else {
            state = .unavailable(.noContext)
            return
        }
        let chosen = settingsProvider?() ?? settings
        guard chosen.source != nil else {
            state = .unavailable(.noSource)
            return
        }
        // **The switch is the mode**, in both directions: the chosen-sense ask never settles for the sentence alone.
        if operation.mode == .explainSense, !chosen.sendEntryText {
            state = .unavailable(.entryTextOff)
            return
        }
        // The entry is read on the main actor, now: the entry drawn at the tap, never one sampled after an await.
        var target: (DictId, EntryRef)?
        switch operation.mode {
        case .sentenceOnly:
            break
        case .explainSense:
            guard let selection = operation.selection else {
                state = .unavailable(.noSense)
                return
            }
            // **The frame's own entry** (plan-explain-sense WI-5): on the All page this is the dictionary whose frame
            // the reader clicked in, not the one shown; the window matched it to that frame's results before selecting.
            target = (selection.dictionary, selection.entry)
        case .grounded:
            if let explicit = operation.target {
                target = (explicit.dictionary, explicit.entry)
            } else if let bound = boundTarget {
                // **The entry must still be the one the sentence was bound to** (verification finding, 2026-10-20): between
                // a draw and the ask, the window can present another entry, and sending that one would answer about the
                // wrong sense. Refused, never sent.
                guard let drawn = presented(), drawn == bound else {
                    state = .unavailable(.noContext)
                    return
                }
                target = drawn
            } else if subject == nil {
                // **The sentence has not drawn its entry yet** (verification finding, 2026-10-20): the window may still show
                // the entry from before the hand-off — and a capture whose popover had not resolved yet names no entry at
                // all — so the tap waits for the first draw and asks then. `drawn` binds the adopted presentation; the
                // placeholder settles a tap that never gets one through `noEntry`.
                askWhenDrawn = true
                askWhenDrawnOperation = operation
                state = .asking
                return
            } else {
                guard let drawn = presented() else {
                    state = .unavailable(.noEntry)
                    return
                }
                target = drawn
            }
        }
        generation += 1
        let mine = generation
        sent = nil
        previewSettings = nil
        previewOperation = nil
        state = .asking
        lastOperation = operation
        let fetchEntryText = self.fetchEntryText
        let makeProvider = self.makeProvider
        let recheck = Self.consentReader(self)
        running = Task { [weak self] in
            let outcome = await Self.perform(handoff: handoff, mode: operation.mode, target: target,
                                             selection: operation.selection, settings: chosen,
                                             fetchEntryText: fetchEntryText, makeProvider: makeProvider,
                                             recheck: recheck)
            guard let self, self.generation == mine else { return }
            self.running = nil
            self.state = outcome.state
            self.sent = outcome.sent
        }
    }

    /// **Preview the request without sending it** (ADR-0021 d.13): the same composition an ask would send — the reader's
    /// template, the sentence, the entry, its cut if there is one, and the chosen sense when one is selected — and no
    /// provider is built or called. The pane offers Send from here.
    public func preview() {
        abandon()
        guard let handoff = held else {
            state = .unavailable(.noContext)
            return
        }
        let chosen = settingsProvider?() ?? settings
        guard chosen.source != nil else {
            state = .unavailable(.noSource)
            return
        }
        let operation = operation(for: chosen, selection: selection)
        var target: (DictId, EntryRef)?
        switch operation.mode {
        case .sentenceOnly:
            break
        case .explainSense:
            guard let selection = operation.selection else {
                state = .unavailable(.noSense)
                return
            }
            target = (selection.dictionary, selection.entry)
        case .grounded:
            if let explicit = operation.target {
                target = (explicit.dictionary, explicit.entry)
            } else if let bound = boundTarget {
                // The previewed request must be the ask's: the same binding check as `ask()`.
                guard let drawn = presented(), drawn == bound else {
                    state = .unavailable(.noContext)
                    return
                }
                target = drawn
            } else if subject == nil {
                // A preview before the sentence's own entry draws would show another entry: nothing to preview yet.
                state = .unavailable(.noEntry)
                return
            } else {
                guard let drawn = presented() else {
                    state = .unavailable(.noEntry)
                    return
                }
                target = drawn
            }
        }
        generation += 1
        let mine = generation
        sent = nil
        previewSettings = nil
        previewOperation = nil
        state = .idle
        let fetchEntryText = self.fetchEntryText
        running = Task { [weak self] in
            let composed = await Self.compose(handoff: handoff, mode: operation.mode, target: target,
                                              selection: operation.selection, settings: chosen,
                                              fetchEntryText: fetchEntryText)
            guard let self, self.generation == mine else { return }
            self.running = nil
            self.sent = composed.sent
            if let failure = composed.failure {
                self.state = failure
            } else if let sent = composed.sent {
                self.previewSettings = chosen
                self.previewEntry = composed.entry
                self.previewOperation = operation
                self.state = .preview(sent)
            }
        }
    }

    /// **The switch as it is now**, read on the main actor at each send boundary (plan-explain-sense WI-2): the ask
    /// re-reads it after the entry fetch and after the queue's permit, so a switch turned off during either wait stops
    /// the entry text leaving.
    private nonisolated static func consentReader(_ session: MeaningSession) -> @Sendable () async -> MeaningSettings {
        { [weak session] in
            await MainActor.run { session?.settingsProvider?() ?? session?.settings ?? .off }
        }
    }

    /// Whether the reader's switch still stands for this question's mode: the mode is the switch, so a change in either
    /// direction makes the composed question the wrong one. The switch is on exactly when the mode sends an entry —
    /// `grounded` and `explainSense` both do (contract 3), only `sentenceOnly` does not.
    private nonisolated static func consentHolds(_ settings: MeaningSettings, mode: AIMode) -> Bool {
        settings.sendEntryText == (mode != .sentenceOnly)
    }

    /// Cancels the ask in flight and makes it unable to report. The state keeps whatever it showed, unless the caller
    /// sets it.
    private func abandon() {
        generation += 1
        running?.cancel()
        running = nil
    }

    /// What composition produced: a failure state, the request as it would be sent, or both (a failure after composing
    /// keeps the prompt, so the reader can see what the refused ask was about).
    struct Composed: Sendable {
        let failure: State?
        let sent: MeaningSent?
        let entry: AIEntryText?
        /// The chosen sense, in the explain-sense mode only; the validator binds an answer to it.
        let sense: AISense?
    }

    /// **Composition alone**: the entry under the budget, the chosen sense, the question, the template. No provider,
    /// no send — shared by an ask and a preview, so the prompt a preview shows is byte for byte the prompt an ask sends.
    private nonisolated static func compose(
        handoff: MeaningHandoff, mode: AIMode, target: (DictId, EntryRef)?, selection: MeaningSelection?,
        settings: MeaningSettings,
        fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>
    ) async -> Composed {
        // A source is required to have come this far (`ask` refuses without one).
        guard settings.source != nil else {
            return Composed(failure: .unavailable(.noSource), sent: nil, entry: nil, sense: nil)
        }
        var entry: AIEntryText?
        var sense: AISense?
        if mode != .sentenceOnly {
            guard let target else { return Composed(failure: .unavailable(.noEntry), sent: nil, entry: nil, sense: nil) }
            let fetched = await fetchEntryText(target.0, target.1, MeaningBudget.entryTextBytes)
            guard !Task.isCancelled else { return Composed(failure: .cancelled, sent: nil, entry: nil, sense: nil) }
            guard case .success(let projected) = fetched else {
                return Composed(failure: .unavailable(.entryUnreadable), sent: nil, entry: nil, sense: nil)
            }
            entry = AIEntryText(text: projected.text, complete: projected.complete, cutAt: projected.cutAt,
                                ref: AIEntryRef(edition: projected.entry.edition.rawValue, key: projected.entry.key,
                                                occurrence: projected.entry.occurrence))
            if mode == .explainSense {
                // **The sense's text is the core's projection**, never the page's: an ordinal the projection does not
                // hold names nothing, and the panel is refused rather than sent about a guessed sense.
                guard let selection,
                      let chosen = projected.senses.first(where: { $0.id == selection.sense }),
                      let text = senseText(of: chosen, in: projected.text) else {
                    return Composed(failure: .unavailable(.noSense), sent: nil, entry: entry, sense: nil)
                }
                sense = AISense(id: chosen.id, start: chosen.start, len: chosen.len, text: text,
                                label: chosen.label, section: chosen.section, whole: chosen.whole)
            }
        }
        let range = handoff.range.map { AITermRange.range(start: $0.location, length: $0.length) } ?? .notFound
        let question = AIQuestion(term: handoff.term, termRange: range, sentence: handoff.sentence, entry: entry,
                                  sense: sense, language: settings.language, mode: mode)
        let template = settings.template(for: mode) ?? ""
        let composed: String
        do {
            composed = try AIComposer.compose(template: template, question: question)
        } catch {
            return Composed(failure: .template(error), sent: nil, entry: entry, sense: nil)
        }
        return Composed(failure: nil,
                        sent: MeaningSent(text: composed, mode: mode, source: settings.source,
                                          complete: entry?.complete ?? true, cutAt: entry?.cutAt ?? 0,
                                          sense: sense, dictionaryName: selection?.dictionaryName),
                        entry: entry, sense: sense)
    }

    /// The chosen sense's text, as the entry's own bytes at its range: nil when the range is out of the text or is not
    /// valid UTF-8, which the core's own projection never produces (a forged one is refused, never repaired).
    private nonisolated static func senseText(of sense: Sense, in text: String) -> String? {
        let bytes = Array(text.utf8)
        guard let start = Int(exactly: sense.start), let len = Int(exactly: sense.len),
              start <= bytes.count, len <= bytes.count - start else { return nil }
        return String(bytes: bytes[start..<(start + len)], encoding: .utf8)
    }

    /// One ask's result: its terminal state, and the question it sent when it composed one.
    struct Performed: Sendable {
        let state: State
        let sent: MeaningSent?
    }

    /// **One ask's send**, shared by a direct ask and a preview's Send (audit finding, 2026-10-23): the source, the
    /// queue permit, the send-boundary checks (consent and cancellation, re-read after each wait), the provider call and
    /// validation. One path means the consent rule cannot be fixed in one caller and left broken in the other.
    private nonisolated static func send(
        sent: MeaningSent, entry: AIEntryText?, sense: AISense?, settings: MeaningSettings,
        makeProvider: @Sendable (MeaningSettings) throws(AIProviderError) -> any AIProvider,
        recheck: @Sendable () async -> MeaningSettings
    ) async -> Performed {
        guard let source = settings.source else { return Performed(state: .unavailable(.noSource), sent: sent) }
        let provider: any AIProvider
        do {
            provider = try makeProvider(settings)
        } catch {
            return Performed(state: .unavailable(.provider(error)), sent: sent)
        }
        // **One ask per source at a time** (plan-ai-meaning WI-5): a second window's ask waits here; a cancelled one
        // leaves the queue without being asked.
        let ticket = UUID()
        guard await MeaningQueue.shared.acquire(source, id: ticket) else {
            return Performed(state: .cancelled, sent: sent)
        }
        // The queue may hand over a permit just as the task is cancelled; the provider must not be called then.
        guard !Task.isCancelled else {
            await MeaningQueue.shared.release(source)
            return Performed(state: .cancelled, sent: sent)
        }
        // **The send boundary**: the switch may have been turned off while the ask waited for the source, and the
        // cancellation may have arrived while the switch was being read on the main actor.
        guard Self.consentHolds(await recheck(), mode: sent.mode) else {
            await MeaningQueue.shared.release(source)
            return Performed(state: .unavailable(.consentChanged), sent: sent)
        }
        guard !Task.isCancelled else {
            await MeaningQueue.shared.release(source)
            return Performed(state: .cancelled, sent: sent)
        }
        let raw: String
        do {
            raw = try await provider.answer(to: sent.text)
        } catch {
            await MeaningQueue.shared.release(source)
            guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
            // A cancelled provider call is the session's own cancellation, not a source failure.
            if error == .cancelled { return Performed(state: .cancelled, sent: sent) }
            return Performed(state: .unavailable(.provider(error)), sent: sent)
        }
        await MeaningQueue.shared.release(source)
        guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
        do {
            let answer = try AIAnswerValidator.validate(json: Data(raw.utf8), mode: sent.mode, entry: entry,
                                                       sense: sense)
            return Performed(state: .answer(answer, mode: sent.mode), sent: sent)
        } catch {
            return Performed(state: .invalid(error), sent: sent)
        }
    }

    /// **The second half of an ask, for a preview's Send**: the composed text goes to the source as it was shown and is
    /// validated against the entry it was composed from.
    private nonisolated static func performSent(
        sent: MeaningSent, entry: AIEntryText?, settings: MeaningSettings,
        makeProvider: @Sendable (MeaningSettings) throws(AIProviderError) -> any AIProvider,
        recheck: @Sendable () async -> MeaningSettings
    ) async -> Performed {
        await send(sent: sent, entry: entry, sense: sent.sense, settings: settings, makeProvider: makeProvider,
                   recheck: recheck)
    }

    /// One ask, apart from the session's state so cancellation is decided by `generation` alone.
    private nonisolated static func perform(
        handoff: MeaningHandoff, mode: AIMode, target: (DictId, EntryRef)?, selection: MeaningSelection?,
        settings: MeaningSettings,
        fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>,
        makeProvider: @Sendable (MeaningSettings) throws(AIProviderError) -> any AIProvider,
        recheck: @Sendable () async -> MeaningSettings
    ) async -> Performed {
        guard settings.source != nil else { return Performed(state: .unavailable(.noSource), sent: nil) }
        let composed = await Self.compose(handoff: handoff, mode: mode, target: target, selection: selection,
                                          settings: settings, fetchEntryText: fetchEntryText)
        if let failure = composed.failure { return Performed(state: failure, sent: composed.sent) }
        guard let sent = composed.sent else { return Performed(state: .unavailable(.noEntry), sent: nil) }
        // **After the fetch**: the reader may have turned the switch off while the entry was read.
        guard Self.consentHolds(await recheck(), mode: mode) else {
            return Performed(state: .unavailable(.consentChanged), sent: sent)
        }
        guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
        return await send(sent: sent, entry: composed.entry, sense: composed.sense, settings: settings,
                          makeProvider: makeProvider, recheck: recheck)
    }
}
