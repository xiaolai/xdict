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
    /// **The service the address is** (2026-10-25), as `AIProviderProfile.known`'s id; `"custom"` when the reader
    /// supplies the address. It decides how the key travels and which token-limit field is sent first — never a secret.
    public var profile: String
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
    /// **Ask the reader before the first question of a sentence leaves** (owner, 2026-10-26): off, the tab's tap asks
    /// and the answer appears; on, the same tap shows the composed request with Send and Cancel.
    public var previewBeforeSending: Bool
    /// **The pane asks for its sentence as soon as it opens** (owner, 2026-10-26): a capture that brings the pane up is
    /// the reader's act, so the question it was captured for is asked without a second tap. Off, the reader chooses.
    public var askOnOpen: Bool
    /// **The language a translation is written into** (contract 6; plan-context-tools WI-8), as a BCP 47 tag. Its own
    /// choice, defaulting to the explanation's language: a reader may read meanings in one language and want sentences
    /// in another.
    public var translationLanguage: String
    /// The reader's edited templates, by question kind; a kind absent here uses the shipped default for `language`
    /// (ADR-0021 d.13). One template per kind: a grounded edit carries `{entry}`, a sentence-only one may not, the
    /// chosen-sense one carries `{entry}` and `{sense}` (contract 3), and the two contract-6 kinds carry neither.
    public var templates: [AIMode: String]

    public init(source: AIProviderKind? = nil, endpoint: URL? = nil, profile: String = MeaningProfiles.custom,
                model: String = "", key: String? = nil, usesKey: Bool = false, sendEntryText: Bool = false,
                language: String = "en", translationLanguage: String = "en", previewBeforeSending: Bool = false,
                askOnOpen: Bool = true, templates: [AIMode: String] = [:]) {
        self.source = source
        self.endpoint = endpoint
        self.profile = profile
        self.model = model
        self.key = key
        self.usesKey = usesKey
        self.sendEntryText = sendEntryText
        self.language = language
        self.translationLanguage = translationLanguage
        self.previewBeforeSending = previewBeforeSending
        self.askOnOpen = askOnOpen
        self.templates = templates
    }

    /// The template an ask of `mode` uses: the reader's edit, else the shipped default of this language, else English's.
    public func template(for mode: AIMode) -> String? {
        AITemplates.effective(language: language, mode: mode, stored: templates[mode])
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
    /// **The dictionary's spelling of the phrase this hand-off asks about** (AI contract 5; plan-phrase-recognition
    /// WI-9), when the reader chose a phrase: the lookup key and provenance, never the term. Nil for a word ask.
    public let phrase: String?

    public init(term: String, sentence: String, range: NSRange?, cut: CutEnds = [], origin: MeaningOrigin,
                phrase: String? = nil) {
        self.term = term
        self.sentence = sentence
        self.range = range
        self.cut = cut
        self.origin = origin
        self.phrase = phrase
    }
}

/// The bounds a meaning ask works under (ADR-0021 d.2, d.5). The core's ceiling is `Limits.maxTextBytes`; this is the
/// pane's own, smaller budget: 256 KiB keeps a large real entry whole inside the composer's 1 MiB question ceiling, and a
/// cut entry is sent with `complete: false`, which the answer's rules honour (`noMatchingSense` never over a cut).
public enum MeaningBudget {
    public static let entryTextBytes: UInt64 = 256 << 10
}

/// **What the pane's one ask button asks** (contract 6; plan-context-tools D10): the word's meaning here, the sentence
/// in another language, or what the sentence's grammar is doing. One control, three questions, one set of consent and
/// cancellation rules.
public enum MeaningAskMode: String, Sendable, Equatable, CaseIterable {
    case meaning
    case translation
    case grammar

    /// **The reader's choice is remembered across windows** (plan-context-tools WI-8): one key, one rule, so the pane
    /// opens on the question the reader last asked.
    public static let defaultsKey = "meaning.askMode"

    public static func stored(in defaults: UserDefaults = .standard) -> MeaningAskMode {
        defaults.string(forKey: defaultsKey).flatMap(MeaningAskMode.init(rawValue:)) ?? .meaning
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// **The sentence a request is about, as the request holds it** (HIG audit 2026-10-23, UI09): the captured term, its
/// sentence, the term's range and which ends the capture cut — copied from the hand-off when the question is composed,
/// so the pane shows the context of this request, never a newer capture's.
public struct MeaningContext: Equatable, Sendable {
    public let term: String
    public let sentence: String
    /// The term's range in the sentence, in UTF-16 units; nil when the capture carried none.
    public let range: NSRange?
    public let cut: CutEnds
    /// The dictionary's spelling of the phrase a phrase ask is about (AI contract 5), or nil for a word ask.
    public let phrase: String?

    public init(term: String, sentence: String, range: NSRange?, cut: CutEnds = [], phrase: String? = nil) {
        self.term = term
        self.sentence = sentence
        self.range = range
        self.cut = cut
        self.phrase = phrase
    }

    init(_ handoff: MeaningHandoff) {
        self.init(term: handoff.term, sentence: handoff.sentence, range: handoff.range, cut: handoff.cut,
                  phrase: handoff.phrase)
    }
}

/// **The composed question as it was sent** (ADR-0021 d.13): the exact bytes, the mode, and whether the entry was cut
/// before it went. Kept in memory for the presentation only, so the answer pane's View the prompt shows what was really
/// sent, never a re-render that may differ.
public struct MeaningSent: Sendable, Equatable {
    public let text: String
    public let mode: AIMode
    /// **The source the request was composed for**, so an answer is never relabelled after the reader switches sources.
    public let source: AIProviderKind?
    /// **The model the request asked for**, frozen at compose time (Codex refutation, 2026-10-25): the reader may change
    /// Settings ▸ AI afterwards, and the pane must not relabel an old answer. Nil for a source that names no model (the
    /// CLI sources pass their own defaults) and for an HTTP source with an empty field.
    public let model: String?
    /// **The endpoint's host the request went to**, frozen at compose time for the same reason as `model`: a reader who
    /// changes the address afterwards must not relabel an answer already shown, nor its saved note (audit 2026-10-27).
    public let endpointHost: String?
    /// False when the entry's budget cut it (`entry_text`'s `complete`); always true in `sentenceOnly` mode.
    public let complete: Bool
    public let cutAt: UInt64
    /// **The chosen sense**, in `explainSense` mode only: what the request named, and what the answer is validated
    /// against. Kept with the request so the pane shows the sense that was sent, not the one selected since.
    public let sense: AISense?
    /// The dictionary the entry was sent from, as the reader knows it: for the chosen sense the frame it was clicked
    /// in, on the All page never the one that happens to be shown (plan-explain-sense WI-5); for a grounded ask the
    /// entry the request was composed from (HIG audit UI11). Nil for a sentence-only request.
    public let dictionaryName: String?
    /// **The sentence this request is about** (UI09); nil only for a value built without one.
    public let questionContext: MeaningContext?
    /// **The entry the request sent**, so the pane's evidence reveals the right frame (UI11); nil when no entry went.
    public let target: MeaningTarget?
    /// **The language the answer was asked in** (contract 6): the translation's target in `translate` mode, the
    /// explanation's language otherwise. Frozen with the request, so a Settings change cannot relabel an old answer.
    public let language: String?

    public init(text: String, mode: AIMode, source: AIProviderKind?, complete: Bool, cutAt: UInt64,
                sense: AISense? = nil, dictionaryName: String? = nil, questionContext: MeaningContext? = nil,
                target: MeaningTarget? = nil, model: String? = nil, endpointHost: String? = nil,
                language: String? = nil) {
        self.text = text
        self.mode = mode
        self.source = source
        self.model = model
        self.endpointHost = endpointHost
        self.complete = complete
        self.cutAt = cutAt
        self.sense = sense
        self.dictionaryName = dictionaryName
        self.questionContext = questionContext
        self.target = target
        self.language = language
    }
}

/// **One entry an operation is about** (plan-explain-sense WI-5): the dictionary's handle and the entry's reference, in
/// the frame the reader is reading. Carried as a value, so an operation's target cannot drift with the window.
public struct MeaningTarget: Equatable, Hashable, Sendable {
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
        /// **The entry could not be read, with the service's own typed failure** (audit finding, 2026-10-25): a transport
        /// interruption is worth a retry, an entry that has gone is not — the blanket `entryUnreadable` said neither.
        case entryFailure(ClientFailure)
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
    /// **The question the pane's one ask button asks** (contract 6; plan-context-tools D10): meaning here by default;
    /// the reader may switch it to translation or grammar. Set through `choose(_:)`, which drops the previous answer.
    public private(set) var chosenMode: MeaningAskMode = .meaning
    /// What the reader chose, read at each ask: a change in Settings applies to the next one.
    public var settings: MeaningSettings = .off
    /// **Where the reader's choices really live** (WI-6): Settings ▸ AI's store, read at each ask so a change applies to
    /// the next one. Nil in tests, which set `settings` directly.
    @ObservationIgnored public var settingsProvider: (@MainActor () -> MeaningSettings)?
    /// **The dictionary's name as the reader knows it**, for the request's evidence label (HIG audit UI11): read on the
    /// main actor when an ask or a preview starts, so the name is the request's, fixed with it.
    @ObservationIgnored public var dictionaryNamer: (@MainActor (DictId) -> String?)?
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
    /// A preview owed to a draw that has not come: its own flags, cleared with the sentence (`clear`) and at the draw.
    @ObservationIgnored private var previewWhenDrawn = false
    @ObservationIgnored private var previewWhenDrawnOperation: Operation?
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
    /// **The operation the last ask tried, refused or not**: what Ask Again repeats — never an older ask's operation
    /// after a newer one that failed before it reached a target (audit round 1, 2026-10-25).
    @ObservationIgnored private var lastOperation: Operation?
    /// The operation a deferred ask (a hand-off before its entry drew) will run.
    @ObservationIgnored private var askWhenDrawnOperation: Operation?
    /// **The sentence's lookup settled with nothing drawn** (audit round 2, 2026-10-25): a later ask must answer
    /// `noEntry` at once rather than wait for a draw that already failed to come.
    @ObservationIgnored private var lookupWithoutEntry = false

    @ObservationIgnored private let fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>
    @ObservationIgnored private let presented: @MainActor () -> (DictId, EntryRef)?
    @ObservationIgnored private let makeProvider: @Sendable (MeaningSettings, AIMode) throws(AIProviderError) -> any AIProvider
    @ObservationIgnored private var running: Task<Void, Never>?
    /// **The operation `running` is executing**: a cleared chosen sense must be able to invalidate a preview or ask still
    /// being composed (audit finding, 2026-10-25).
    @ObservationIgnored private var runningOperation: Operation?
    /// **The source the running ask was started for**, frozen at the tap (verification round 1, 2026-10-25): the pane
    /// names the request's recipient, which a Settings change while it runs must not relabel.
    public private(set) var askingSource: AIProviderKind?
    /// **The entry the running ask is about**, frozen with the source (audit round 3): the pane's context speaker speaks
    /// the request's dictionary's language while `sent` is still nil.
    public private(set) var askingTarget: MeaningTarget?
    /// Bumped by every ask, cancel and clear: a task finishing after one of them changes nothing.
    @ObservationIgnored private var generation = 0
    /// **Counts every ask, Send or preview task that finished, stale or not** (audit round 2, 2026-10-25): a test's signal
    /// that a released operation is over. Nothing in the app reads it.
    public private(set) var settled = 0

    /// - `fetchEntryText` is `entry_text` through the service (contract 8), under a text budget.
    /// - `presented` is the entry drawn now: the ask's edition-qualified target.
    /// - `makeProvider` builds the source `settings` names (a fake in the tests).
    public init(fetchEntryText: @escaping @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>,
                presented: @escaping @MainActor () -> (DictId, EntryRef)?,
                makeProvider: @escaping @Sendable (MeaningSettings, AIMode) throws(AIProviderError) -> any AIProvider) {
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

    /// **A sense the entry names, as the pane's list shows it** (plan-companion WI-8): the core's projection, never a
    /// guess. The snippet is the sense's own bytes, whitespace-collapsed, so rows with no label or an identical section
    /// stay distinguishable.
    public struct SenseRow: Equatable, Sendable, Identifiable {
        public let id: UInt32
        public let label: String?
        public let section: String?
        public let snippet: String
        public let whole: Bool
    }

    /// The senses of `sensesTarget`, empty while the fetch runs, when it failed, or when the projection names none.
    public private(set) var senses: [SenseRow] = []
    /// The edition-qualified entry those rows belong to: another entry's list is never shown for this one.
    public private(set) var sensesTarget: MeaningTarget?
    /// **How the fetch for `sensesTarget` ended**, so a failure is not shown as an entry with no senses (audit round 1,
    /// 2026-10-25): nil when nothing was asked, `.loading` while it runs, `.loaded` (even with no rows), `.failed`.
    public enum SensesStatus: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }
    public private(set) var sensesStatus: SensesStatus?
    /// Counts every sense fetch that finished, stale or not: a test's signal that a released load is over (audit round 3).
    public private(set) var sensesSettled = 0
    @ObservationIgnored private var sensesGeneration = 0
    @ObservationIgnored private var sensesTask: Task<Void, Never>?

    /// **The entry's own senses, for the pane's list**: one `entry_text` fetch per edition-qualified entry, under the
    /// ask's own budget, cancelled by another entry's load or the presentation ending. A late answer for an entry the
    /// pane has left is dropped by generation rather than shown against the new one. **One fetch per target**: the
    /// status, not the row count, says whether there is something to ask again — an entry with no senses is loaded, not
    /// unasked (audit round 1, 2026-10-25). A failed fetch is asked again only by the reader's retry.
    public func loadSenses(for target: MeaningTarget) {
        if sensesTarget == target, let status = sensesStatus, status != .failed { return }
        sensesGeneration += 1
        let mine = sensesGeneration
        sensesTask?.cancel()
        senses = []
        sensesTarget = target
        sensesStatus = .loading
        let fetchEntryText = self.fetchEntryText
        sensesTask = Task { [weak self] in
            let result = await fetchEntryText(target.dictionary, target.entry, MeaningBudget.entryTextBytes)
            guard let self else { return }
            self.sensesSettled += 1
            guard mine == self.sensesGeneration, !Task.isCancelled else { return }
            switch result {
            case .success(let projected):
                self.senses = Self.rows(of: projected)
                self.sensesStatus = .loaded
            case .failure:
                self.senses = []
                self.sensesStatus = .failed
            }
        }
    }

    /// The rows a projection makes: every sense the markup named, with its own text as the snippet.
    static func rows(of projected: EntryText) -> [SenseRow] {
        let bytes = Array(projected.text.utf8)
        return projected.senses.map { sense in
            let snippet = slice(bytes, start: sense.start, len: sense.len)?
                .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return SenseRow(id: sense.id, label: sense.label, section: sense.section,
                            snippet: String(snippet.prefix(80)), whole: sense.whole)
        }
    }

    /// **An entry's bytes at a sense's range, as text** — the one range rule both the sense list and the composed
    /// sense read (audit round 1, 2026-10-25): nil when the range is past the text or splits a character (a forged range
    /// is refused, never repaired).
    nonisolated static func slice(_ bytes: [UInt8], start: UInt64, len: UInt64) -> String? {
        guard let start = Int(exactly: start), let len = Int(exactly: len),
              start <= bytes.count, len <= bytes.count - start else { return nil }
        return String(bytes: bytes[start..<(start + len)], encoding: .utf8)
    }

    /// A new capture or the presentation ending: the list goes with it.
    private func clearSenses() {
        sensesGeneration += 1
        sensesTask?.cancel()
        sensesTask = nil
        senses = []
        sensesTarget = nil
        sensesStatus = nil
    }

    /// Whether the chosen-sense ask may send the entry: its one consent rule, the reader's switch. The button is shown
    /// disabled with the reason when this is false, never silently absent (ADR-0021 d.4).
    public var senseExplainAllowed: Bool { (settingsProvider?() ?? settings).sendEntryText }

    /// Whether a tap's ask is still waiting for the entry to draw: the window answers a lookup that settles with nothing
    /// drawn through `noEntry()`, rather than dropping the ask. (Verification finding, 2026-10-20.)
    public var isWaitingToAsk: Bool { askWhenDrawn || previewWhenDrawn }

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
        kept.removeAll()
        dropEvidence()
        selection = nil
        lastOperation = nil
        previewWhenDrawn = false
        previewWhenDrawnOperation = nil
        askWhenDrawn = asking
        lookupWithoutEntry = false
        clearSenses()
        // The entry the sentence belongs to is remembered even without an ask owed: a manual ask before it draws must
        // wait for it, not ground in whatever the window shows (verification finding, 2026-10-20).
        askWhenDrawnExpected = expecting
        state = .idle
    }

    /// **The reader selected a sense** (plan-explain-sense WI-5; ADR-0029 d.6): the choice is this presentation's, and
    /// a new one makes the last request and answer about another sense — they are dropped, and an ask in flight is
    /// cancelled, so a late answer to the old one is never shown as this selection's.
    ///
    /// **A finished answer stays** (HIG audit 2026-10-23, UI23): a plain click is how a reader reads, and erasing the
    /// answer on it destroyed useful output. The answer keeps its own request (`sent`), so the pane labels it with the
    /// sense it was about and says the choice has moved; it is never shown as the new selection's. A preview or an ask
    /// in flight is about the old choice and not yet output: it ends, as before.
    public func select(_ selection: MeaningSelection) {
        guard held != nil else { return }
        guard self.selection != selection else { return }
        let finished = Self.isFinished(state)
        abandon()
        // A tap that was still waiting for its entry is the old operation's: abandon() ended it; a selection is the
        // reader moving on.
        self.selection = selection
        previewSettings = nil
        previewEntry = nil
        previewOperation = nil
        guard !finished else { return }
        sent = nil
        state = .idle
    }

    /// **The reader cleared the chosen sense** (UI21): the mark goes, and Explain This Sense with it; what is shown
    /// stays, labelled by its own request.
    public func clearSelection() {
        guard selection != nil else { return }
        // **A preview or ask about the sense being cleared does not outlive the clear** (audit finding, 2026-10-25): a
        // shown explain-sense preview is dismissed, and one still being composed is invalidated before it can appear.
        if case .preview(let previewed) = state, previewed.mode == .explainSense {
            cancel()
        } else if runningOperation?.mode == .explainSense {
            abandon()
            // **The request being abandoned is not this pane's any more** (audit round 4, 2026-10-25): its sent record
            // goes with it, so the pane does not show a cancelled request beside "No Answer Yet".
            dropEvidence()
            state = .idle
        }
        selection = nil
    }

    /// An answer or a failure the reader can read: everything but idle, asking and a preview.
    private static func isFinished(_ state: State) -> Bool {
        switch state {
        case .idle, .asking, .preview: false
        case .answer, .template, .invalid, .unavailable, .cancelled: true
        }
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
        lookupWithoutEntry = false
        if askWhenDrawn {
            // A deferred ask waits for its own entry; another presentation's draw is not the one the reader asked about.
            // (Without an expected subject — a caller with none — the first draw is the one.)
            askWhenDrawn = false
            awaitsAdoptedPlace = false
            // Bound now: the bound target guards later presentations, so the expectation has done its work.
            askWhenDrawnExpected = nil
            self.subject = subject
            boundTarget = target
            // **The popover's Meaning Here** (audit rd 1, contract 6): the button promised the meaning question, so the
            // destination window's remembered mode must not turn it into a translation or a grammar ask — and the tabs
            // follow the question actually asked (audit 2026-10-27), or a meaning answer would sit under a remembered
            // translation tab.
            var operation = askWhenDrawnOperation
            askWhenDrawnOperation = nil
            if operation == nil {
                let chosen = settingsProvider?() ?? settings
                operation = self.operation(for: chosen, selection: nil, honouring: .meaning)
                adopt(.meaning)
            }
            if let operation { start(operation) }
            return
        }
        if previewWhenDrawn {
            // **A preview owed to this draw** (audit 2026-10-27): the same binding as an ask's, then the composition.
            previewWhenDrawn = false
            awaitsAdoptedPlace = false
            askWhenDrawnExpected = nil
            self.subject = subject
            boundTarget = target
            let owed = previewWhenDrawnOperation
            previewWhenDrawnOperation = nil
            if let owed {
                composePreview(owed)
            } else {
                composePreview(self.operation(for: settingsProvider?() ?? settings, selection: selection,
                                              honouring: chosenMode))
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
        // **The evidence of an earlier answer does not attach to this failure** (audit round 4, 2026-10-26), and the
        // operation it would repeat is not the one the reader tapped.
        dropEvidence()
        lastOperation = nil
        lookupWithoutEntry = true
        state = .unavailable(.noEntry)
    }

    /// **The phrase's entry could not be looked up** (plan WI-9; audit round 3, 2026-10-26): the tap had no page to
    /// ground its question in, the reason is the service's own failure, and the sentence stays held for another try.
    public func entryLookupFailed(_ failure: ClientFailure) {
        refuse(.entryFailure(failure))
    }

    /// **A new ask has begun** (audit round 4, 2026-10-26): the window's retry of a failed phrase lookup belongs to the
    /// failure that armed it, and the reader asking something else ends it.
    @ObservationIgnored public var onAskBegins: (@MainActor () -> Void)?
    /// **The model and host the request in flight was composed for** (verification 2026-10-27): the "Asking …" line names
    /// them as they were at the ask, not as Settings say while it runs.
    public private(set) var askingModel: String?
    public private(set) var askingHost: String?

    /// **The presentation ended**: the sentence goes, and so does the ask in flight and its answer.
    public func clear() {
        abandon()
        kept.removeAll()
        previewWhenDrawn = false
        previewWhenDrawnOperation = nil
        held = nil
        subject = nil
        boundTarget = nil
        awaitsAdoptedPlace = false
        adoptionSerial = nil
        dropEvidence()
        selection = nil
        lastOperation = nil
        askWhenDrawnExpected = nil
        lookupWithoutEntry = false
        clearSenses()
        state = .idle
    }

    /// Escape, a newer ask, or closing: the ask in flight ends, and what it would have returned is not shown.
    public func cancel() {
        // **Cancel ends the question** (audit rd 3): a phrase tap still waiting for its lookup belongs to the attempt the
        // reader cancelled, and its late page must not adopt the phrase and ask after the fact.
        onAskBegins?()
        abandon()
        // **The sentence keeps the entry it belongs to** (verification finding, 2026-10-20): cancelling stops the ask, not
        // the binding; a second ask must still wait for that entry rather than sample whatever the window shows.
        if case .preview = state {
            // **Cancel on a preview means dismiss it** (audit finding, 2026-10-20); it used to change nothing.
            dropEvidence()
            state = .idle
            return
        }
        if state == .asking { state = .cancelled }
    }

    /// **The reader asked** ("Meaning Here", "Translate" or "Grammar", per the pane's mode): one button, the chosen
    /// question. Meaning here lets the model choose the sense; the chosen-sense ask is `explain()`.
    public func ask() {
        let chosen = settingsProvider?() ?? settings
        ask(operation: operation(for: chosen, selection: nil, honouring: chosenMode))
    }

    /// **The tab is the question** (owner, 2026-10-26): choosing it asks for that question — unless its answer is
    /// already here, in which case it is shown again and nothing is sent. A sentence keeps one answer per question while
    /// it is held. With Settings ▸ AI's "Show the request before asking" on, the same tap shows the composed request with
    /// Send and Cancel instead. Pressing the chosen tab again retries a failure and leaves an answer alone.
    public func choose(_ mode: MeaningAskMode) {
        if mode == chosenMode {
            if state == .asking { return }
            if case .answer = state { return }
            startQuestion()
            return
        }
        abandon()
        switch state {
        case .asking, .idle:
            break
        default:
            kept[chosenMode] = Kept(state: state, sent: sent, operation: lastOperation,
                                    previewSettings: previewSettings, previewEntry: previewEntry,
                                    previewOperation: previewOperation)
        }
        chosenMode = mode
        if let answer = kept[mode] {
            state = answer.state
            sent = answer.sent
            lastOperation = answer.operation
            // **A kept preview stays sendable** (audit 2026-10-27): its composed bytes, settings and entry come back with
            // it, or Send would silently return and the pane would show a request it cannot send.
            previewSettings = answer.previewSettings
            previewEntry = answer.previewEntry
            previewOperation = answer.previewOperation
            return
        }
        dropEvidence()
        state = .idle
        startQuestion()
    }

    /// **The tabs follow a question asked by name** (audit 2026-10-27): the popover's Meaning Here is the meaning question,
    /// so the pane shows it under that tab; a kept answer of another question goes with the switch.
    private func adopt(_ mode: MeaningAskMode) {
        guard chosenMode != mode else { return }
        kept.removeAll()
        chosenMode = mode
    }

    /// One tap's question: the composed request when the reader asked to see it first, else the ask itself. Nothing is
    /// asked with no sentence in hand.
    private func startQuestion() {
        guard held != nil else { return }
        let chosen = settingsProvider?() ?? settings
        start(operation(for: chosen, selection: selection, honouring: chosenMode))
    }

    /// **One question begins, preview or send** (audit 2026-10-27): a deferred tap — the popover's Meaning Here waiting for
    /// its entry, or a tab pressed before the entry drew — goes through the reader's "show the request before asking"
    /// exactly as a first tap does, instead of calling `ask(operation:)` and leaving without the review step.
    private func start(_ operation: Operation) {
        if (settingsProvider?() ?? settings).previewBeforeSending {
            composePreview(operation)
        } else {
            ask(operation: operation)
        }
    }

    /// One question's finished result, kept while the reader looks at another.
    private struct Kept {
        let state: State
        let sent: MeaningSent?
        let operation: Operation?
        let previewSettings: MeaningSettings?
        let previewEntry: AIEntryText?
        let previewOperation: Operation?
    }

    /// **What each question has shown for this sentence** (owner, 2026-10-26): cleared with the sentence, because an
    /// answer is about the sentence it was asked on.
    @ObservationIgnored private var kept: [MeaningAskMode: Kept] = [:]

    /// **The answer is dropped, the sentence kept**: used when the question changed under it. Nothing was sent.
    public func discardAnswer() {
        abandon()
        dropEvidence()
        state = .idle
    }

    /// **The reader chose which dictionary answers this sentence** (owner, 2026-10-26): the same in-context question,
    /// grounded in the entry of the dictionary they picked from the page, instead of the one shown first. The entry's
    /// text leaves only under the switch, like every grounded ask.
    public func ask(in target: MeaningTarget) {
        let chosen = settingsProvider?() ?? settings
        guard chosen.sendEntryText else {
            refuse(.entryTextOff)
            return
        }
        // **A sense chosen on another entry does not survive** (owner, 2026-10-26): its ordinal belongs to that entry.
        // Choosing the entry already bound keeps the reader's choice for the chips.
        if let selection, selection.dictionary != target.dictionary || selection.entry != target.entry {
            self.selection = nil
        }
        ask(operation: Operation(mode: .grounded, selection: nil, target: target))
    }

    /// **The reader asks about the sense they selected** (plan-explain-sense WI-5; ADR-0029 d.6): the entry's text and
    /// the chosen sense go to the source, and the answer says whether the sense fits. It has no sentence-only variant:
    /// with the switch off, the row says so and nothing is sent.
    public func explain() {
        let chosen = settingsProvider?() ?? settings
        guard chosen.sendEntryText else {
            refuse(.entryTextOff)
            return
        }
        guard let selection else {
            refuse(.noSense)
            return
        }
        // The successful path's cleanup belongs to `ask(operation:)` alone (audit round 4, 2026-10-25).
        ask(operation: Operation(mode: .explainSense, selection: selection, target: nil))
    }

    /// **An early refusal**: the earlier work ends, the evidence and retry context go, and the reason is shown — the same
    /// steps on every path that returns before an ask runs (audit round 4).
    private func refuse(_ reason: Unavailable) {
        abandon()
        dropEvidence()
        lastOperation = nil
        state = .unavailable(reason)
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
        // **The frame the reader was reading is the displayed answer's own target**, not the sense that has since been
        // selected or cleared (audit finding, 2026-10-25): the button follows up a `doesNotFit` verdict, and a selection
        // made after it must not move the follow-up to another entry. A caller with no answer shown falls back to the
        // selection. Read before the abandonment clears the evidence it comes from.
        let target = sent?.target ?? selection.map { MeaningTarget(dictionary: $0.dictionary, entry: $0.entry) }
        guard chosen.sendEntryText else {
            refuse(.entryTextOff)
            return
        }
        ask(operation: Operation(mode: .grounded, selection: nil, target: target))
    }

    /// One ask's kind and target, as an immutable value: the mode, the chosen sense when the mode has one, and an
    /// explicit entry when the ask is about a frame rather than the shown one.
    private struct Operation: Equatable {
        let mode: AIMode
        let selection: MeaningSelection?
        let target: MeaningTarget?
    }

    /// The operation a fresh ask would run from the reader's choices: the pane's mode decides the question; in meaning
    /// mode the chosen sense goes only under the switch that lets the entry leave, since that question always sends it.
    private func operation(for chosen: MeaningSettings, selection: MeaningSelection?,
                           honouring mode: MeaningAskMode = .meaning) -> Operation {
        switch mode {
        case .translation:
            return Operation(mode: .translate, selection: nil, target: nil)
        case .grammar:
            return Operation(mode: .explainGrammar, selection: nil, target: nil)
        case .meaning:
            if let selection, chosen.sendEntryText {
                return Operation(mode: .explainSense, selection: selection, target: nil)
            }
            return Operation(mode: chosen.sendEntryText ? .grounded : .sentenceOnly, selection: nil, target: nil)
        }
    }

    /// One operation: compose, fetch the entry under the switch, ask the one source, validate. A preview's Send takes
    /// its bytes from the preview, never a recomposition.
    private func ask(operation: Operation) {
        // **Any early return still ends the previous work** (audit finding, 2026-10-20): an ask refused for lack of a
        // source must not leave the last task running to overwrite this state, and must not keep the previous attempt's
        // prompt attached (audit finding, 2026-10-25).
        abandon()
        dropEvidence()
        onAskBegins?()
        lastOperation = operation
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
        let target: (DictId, EntryRef)?
        switch resolveTarget(operation) {
        case .resolved(let resolved):
            target = resolved
        case .waitsForDraw:
            // **The sentence has not drawn its entry yet** (verification finding, 2026-10-20): the window may still show
            // the entry from before the hand-off — and a capture whose popover had not resolved yet names no entry at
            // all — so the tap waits for the first draw and asks then. `drawn` binds the adopted presentation; the
            // placeholder settles a tap that never gets one through `noEntry`. The source recorded is the one the ask
            // will actually use when it starts: a deferred ask runs under the settings read at its own start.
            askWhenDrawn = true
            askWhenDrawnOperation = operation
            askingSource = chosen.source
            askingModel = chosen.source == .http && !chosen.model.isEmpty ? chosen.model : nil
            askingHost = chosen.source == .http ? chosen.endpoint?.host() : nil
            askingTarget = operation.target
            state = .asking
            return
        case .refused(let reason):
            state = .unavailable(reason)
            return
        }
        generation += 1
        let mine = generation
        state = .asking
        askingSource = chosen.source
        askingModel = chosen.source == .http && !chosen.model.isEmpty ? chosen.model : nil
        askingHost = chosen.source == .http ? chosen.endpoint?.host() : nil
        askingTarget = target.map { MeaningTarget(dictionary: $0.0, entry: $0.1) }
        runningOperation = operation
        let fetchEntryText = self.fetchEntryText
        let makeProvider = self.makeProvider
        let recheck = Self.consentReader(self)
        let name = dictionaryName(for: operation, target: target)
        running = Task { [weak self] in
            let outcome = await Self.composeAndSend(handoff: handoff, mode: operation.mode, target: target,
                                             selection: operation.selection, dictionaryName: name, settings: chosen,
                                             fetchEntryText: fetchEntryText, makeProvider: makeProvider,
                                             recheck: recheck)
            guard let self else { return }
            self.finish(outcome, mine: mine)
        }
    }

    /// **One completion for an ask and a Send** (audit round 3, 2026-10-25): the count, the generation check and the
    /// clearing of the running state happen once, so the two paths cannot drift.
    private func finish(_ outcome: Performed, mine: Int) {
        settled += 1
        guard generation == mine else { return }
        running = nil
        runningOperation = nil
        askingSource = nil
        askingModel = nil
        askingHost = nil
        askingTarget = nil
        state = outcome.state
        sent = outcome.sent
    }

    /// **Send, from a preview**: the Send button's own action. It transmits the previewed bytes themselves — no refetch,
    /// no recomposition, so a dictionary that changed between Preview and Send cannot change what leaves (audit
    /// follow-up, 2026-10-20). **Any other ask abandons the preview** rather than sending it (audit finding, 2026-10-25).
    public func sendPreview() {
        guard case .preview(let previewed) = state, let operation = previewOperation else { return }
        abandon()
        let current = settingsProvider?() ?? settings
        // **The same operation, not only the same settings**: a new selection makes another request, while a
        // sentence-only preview ignores the selection and is still the one shown.
        guard current == previewSettings,
              self.operation(for: current, selection: selection, honouring: chosenMode) == operation else {
            // The prompt, the switch or the chosen sense changed after the preview: sending would differ from what was
            // shown.
            dropEvidence()
            state = .cancelled
            return
        }
        let entry = previewEntry
        dropEvidence()
        generation += 1
        let mine = generation
        sent = previewed
        state = .asking
        askingSource = current.source
        // **The previewed request's own name** (verification 2026-10-27): a Send shows the model and host it was composed
        // for, exactly as the answer will keep them.
        askingModel = previewed.model
        askingHost = previewed.endpointHost
        askingTarget = previewed.target
        lastOperation = operation
        runningOperation = operation
        let makeProvider = self.makeProvider
        let recheck = Self.consentReader(self)
        running = Task { [weak self] in
            let outcome = await Self.send(sent: previewed, entry: entry, settings: current,
                                          makeProvider: makeProvider, recheck: recheck)
            guard let self else { return }
            self.finish(outcome, mine: mine)
        }
    }

    /// **The entry an operation grounds in**, as both an ask and a preview must compute it — one rule for the target,
    /// with the undrawn-entry policy left to the caller (an ask waits; a preview refuses) (audit finding, 2026-10-25).
    private enum TargetResolution {
        case resolved((DictId, EntryRef)?)
        case waitsForDraw
        case refused(Unavailable)
    }

    private func resolveTarget(_ operation: Operation) -> TargetResolution {
        switch operation.mode {
        case .sentenceOnly:
            return .resolved(nil)
        case .translate, .explainGrammar:
            // **Contract 6's operations carry no entry**: the sentence is the whole question, so there is nothing to
            // wait for and nothing to fetch.
            return .resolved(nil)
        case .explainSense:
            guard let selection = operation.selection else { return .refused(.noSense) }
            // **The frame's own entry** (plan-explain-sense WI-5): on the All page this is the dictionary whose frame
            // the reader clicked in, not the one shown; the window matched it to that frame's results before selecting.
            return .resolved((selection.dictionary, selection.entry))
        case .grounded:
            if let explicit = operation.target { return .resolved((explicit.dictionary, explicit.entry)) }
            if let bound = boundTarget {
                // **The entry must still be the one the sentence was bound to** (verification finding, 2026-10-20): between
                // a draw and the ask, the window can present another entry, and sending that one would answer about the
                // wrong sense. Refused, never sent.
                guard let drawn = presented(), drawn == bound else { return .refused(.noContext) }
                return .resolved(drawn)
            }
            if subject == nil { return lookupWithoutEntry ? .refused(.noEntry) : .waitsForDraw }
            guard let drawn = presented() else { return .refused(.noEntry) }
            return .resolved(drawn)
        }
    }

    /// **Preview the request without sending it** (ADR-0021 d.13): the same composition an ask would send — the reader's
    /// template, the sentence, the entry, its cut if there is one, and the chosen sense when one is selected — and no
    /// provider is built or called. The pane offers Send from here.
    public func preview() {
        let chosen = settingsProvider?() ?? settings
        composePreview(operation(for: chosen, selection: selection, honouring: chosenMode))
    }

    /// **The composition a tap shows before sending** (ADR-0021 d.13), for a question already decided: the same bytes an
    /// ask would send, and no provider built or called.
    private func composePreview(_ operation: Operation) {
        abandon()
        // **A preview is a newer question** (audit rd 2): a phrase tap still waiting for its lookup belongs to the
        // question the preview superseded, and its late page must not replace this preview.
        onAskBegins?()
        // **A preview discards the previous attempt's evidence**: a refusal here must not leave the last prompt attached.
        dropEvidence()
        guard let handoff = held else {
            state = .unavailable(.noContext)
            return
        }
        let chosen = settingsProvider?() ?? settings
        // **A refused preview is still the newest attempt** (audit rounds 2 and 3, 2026-10-25): its operation is recorded
        // before the source guard, so a preview refused for lack of a source leaves its own operation for Try Again once
        // the reader chooses one — never the last answer's.
        lastOperation = operation
        guard chosen.source != nil else {
            state = .unavailable(.noSource)
            return
        }
        let target: (DictId, EntryRef)?
        switch resolveTarget(operation) {
        case .resolved(let resolved):
            target = resolved
        case .waitsForDraw:
            // **A preview waits for the sentence's own entry** (audit 2026-10-27): composing one before the adopted entry
            // draws would show another entry, and refusing here made a capture's automatic preview fail for good while
            // the entry was still on its way. It is composed at the draw, like an ask that waits.
            previewWhenDrawn = true
            previewWhenDrawnOperation = operation
            state = .asking
            return
        case .refused(let reason):
            state = .unavailable(reason)
            return
        }
        generation += 1
        let mine = generation
        state = .idle
        runningOperation = operation
        let fetchEntryText = self.fetchEntryText
        let name = dictionaryName(for: operation, target: target)
        running = Task { [weak self] in
            let composed = await Self.compose(handoff: handoff, mode: operation.mode, target: target,
                                              selection: operation.selection, dictionaryName: name, settings: chosen,
                                              fetchEntryText: fetchEntryText)
            guard let self else { return }
            self.settled += 1
            guard self.generation == mine else { return }
            self.running = nil
            self.runningOperation = nil
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

    /// The name the request's evidence is labelled with: the chosen sense's frame, else the target dictionary's.
    private func dictionaryName(for operation: Operation, target: (DictId, EntryRef)?) -> String? {
        operation.selection?.dictionaryName ?? target.flatMap { dictionaryNamer?($0.0) }
    }

    /// **The switch as it is now**, read on the main actor at each send boundary (plan-explain-sense WI-2): the ask
    /// re-reads it after the entry fetch and after the queue's permit, so a switch turned off during either wait stops
    /// the entry text leaving.
    private nonisolated static func consentReader(_ session: MeaningSession) -> @Sendable () async -> MeaningSettings {
        { [weak session] in
            await MainActor.run { session?.settingsProvider?() ?? session?.settings ?? .off }
        }
    }

    /// Whether the reader's switch still stands for this question's mode: for a mode that sends the entry the mode is
    /// the switch, so a change in either direction makes the composed question the wrong one; **a mode that carries no
    /// entry has nothing for the switch to govern** (contract 6 §2), so turning it either way never stops a translation
    /// or a grammar question.
    private nonisolated static func consentHolds(_ settings: MeaningSettings, mode: AIMode) -> Bool {
        mode.carriesEntry ? settings.sendEntryText : true
    }

    /// **Cancels everything an earlier action started and makes it unable to report**: the task, a deferred ask still
    /// waiting for its entry, and the operation the task was running. The state keeps whatever it showed, unless the
    /// caller sets it. Every new reader action begins here, so a preview, a `noEntry` or a failure cannot leave a
    /// deferred ask armed to fire on a later draw (audit finding, 2026-10-25).
    private func abandon() {
        generation += 1
        running?.cancel()
        running = nil
        runningOperation = nil
        askingSource = nil
        askingModel = nil
        askingHost = nil
        askingTarget = nil
        askWhenDrawn = false
        askWhenDrawnOperation = nil
        // **Cancel ends a preview owed to a draw too** (verification 2026-10-27): left standing, the next draw would
        // compose a request the reader had already dismissed.
        previewWhenDrawn = false
        previewWhenDrawnOperation = nil
        // **The expected subject outlives a cancellation**: it protects the sentence's binding, not the ask (audit
        // finding of 2026-10-20); only the draw that binds it or a new hold clears it.
    }

    /// **The previous attempt's prompt and preview do not belong to the action starting now** (audit finding,
    /// 2026-10-25): a refused ask or a new preview must not leave the last question's text attached, where the pane would
    /// show it as this request's. A finished *answer* keeps its own `sent` (`select()` never calls this).
    private func dropEvidence() {
        sent = nil
        previewSettings = nil
        previewEntry = nil
        previewOperation = nil
        // **A sense load still running belongs to the answer being dropped** (verification round 3, 2026-10-25): its rows
        // may arrive after a new ask, so it is cancelled and its state reset. The pane's task keys on the sent record, so
        // the next answer loads this entry's rows again even when the target is unchanged.
        if sensesStatus == .loading { clearSenses() }
    }

    /// What composition produced: a failure state, the request as it would be sent, or both (a failure after composing
    /// keeps the prompt, so the reader can see what the refused ask was about).
    struct Composed: Sendable {
        let failure: State?
        let sent: MeaningSent?
        let entry: AIEntryText?
    }

    /// **Composition alone**: the entry under the budget, the chosen sense, the question, the template. No provider,
    /// no send — shared by an ask and a preview, so the prompt a preview shows is byte for byte the prompt an ask sends.
    private nonisolated static func compose(
        handoff: MeaningHandoff, mode: AIMode, target: (DictId, EntryRef)?, selection: MeaningSelection?,
        dictionaryName: String?, settings: MeaningSettings,
        fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>
    ) async -> Composed {
        // A source is required to have come this far (`ask` refuses without one).
        guard settings.source != nil else {
            return Composed(failure: .unavailable(.noSource), sent: nil, entry: nil)
        }
        var entry: AIEntryText?
        var sense: AISense?
        if mode.carriesEntry {
            guard let target else { return Composed(failure: .unavailable(.noEntry), sent: nil, entry: nil) }
            let fetched = await fetchEntryText(target.0, target.1, MeaningBudget.entryTextBytes)
            guard !Task.isCancelled else { return Composed(failure: .cancelled, sent: nil, entry: nil) }
            let projected: EntryText
            switch fetched {
            case .success(let text):
                projected = text
            case .failure(let failure):
                // **The service's own typed failure travels** (audit finding, 2026-10-25): a transport interruption is a
                // different reason, and a different next step, from an entry that no longer exists.
                return Composed(failure: .unavailable(.entryFailure(failure)), sent: nil, entry: nil)
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
                    return Composed(failure: .unavailable(.noSense), sent: nil, entry: entry)
                }
                sense = AISense(id: chosen.id, start: chosen.start, len: chosen.len, text: text,
                                label: chosen.label, section: chosen.section, whole: chosen.whole)
            }
        }
        let range = handoff.range.map { AITermRange.range(start: $0.location, length: $0.length) } ?? .notFound
        // **A translation's `language` is its target** (contract 6 §2), not the explanation's language.
        let answerLanguage = mode == .translate ? settings.translationLanguage : settings.language
        let question = AIQuestion(term: handoff.term, termRange: range, sentence: handoff.sentence, entry: entry,
                                  sense: sense, language: answerLanguage, mode: mode, phrase: handoff.phrase)
        let template = settings.template(for: mode) ?? ""
        let composed: String
        do {
            composed = try AIComposer.compose(template: template, question: question)
        } catch {
            return Composed(failure: .template(error), sent: nil, entry: entry)
        }
        return Composed(failure: nil,
                        sent: MeaningSent(text: composed, mode: mode, source: settings.source,
                                          complete: entry?.complete ?? true, cutAt: entry?.cutAt ?? 0,
                                          sense: sense,
                                          dictionaryName: mode.carriesEntry ? dictionaryName : nil,
                                          questionContext: MeaningContext(handoff),
                                          target: mode.carriesEntry ? target.map {
                                              MeaningTarget(dictionary: $0.0, entry: $0.1)
                                          } : nil,
                                          model: settings.source == .http && !settings.model.isEmpty
                                              ? settings.model : nil,
                                          endpointHost: settings.source == .http ? settings.endpoint?.host() : nil,
                                          language: answerLanguage),
                        entry: entry)
    }

    /// The chosen sense's text, as the entry's own bytes at its range (the same range rule the sense list uses).
    private nonisolated static func senseText(of sense: Sense, in text: String) -> String? {
        slice(Array(text.utf8), start: sense.start, len: sense.len)
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
        sent: MeaningSent, entry: AIEntryText?, settings: MeaningSettings,
        makeProvider: @Sendable (MeaningSettings, AIMode) throws(AIProviderError) -> any AIProvider,
        recheck: @Sendable () async -> MeaningSettings
    ) async -> Performed {
        guard let source = settings.source else { return Performed(state: .unavailable(.noSource), sent: sent) }
        let provider: any AIProvider
        do {
            provider = try makeProvider(settings, sent.mode)
        } catch {
            return Performed(state: .unavailable(.provider(error)), sent: sent)
        }
        // **One ask per source at a time** (plan-ai-meaning WI-5): a second window's ask waits here; a cancelled one
        // leaves the queue without being asked.
        let ticket = UUID()
        guard await MeaningQueue.shared.acquire(source, id: ticket) else {
            return Performed(state: .cancelled, sent: sent)
        }
        // **The permit is released exactly once, on every path below**, through one place (audit finding, 2026-10-25):
        // the six manual releases it replaces were balanced today and a new exit could have unbalanced them.
        return await withPermit(source) {
            // The queue may hand over a permit just as the task is cancelled; the provider must not be called then.
            guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
            // **The send boundary**: the switch may have been turned off while the ask waited for the source, and the
            // cancellation may have arrived while the switch was being read on the main actor.
            guard Self.consentHolds(await recheck(), mode: sent.mode) else {
                return Performed(state: .unavailable(.consentChanged), sent: sent)
            }
            guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
            let raw: String
            do {
                raw = try await provider.answer(to: sent.text)
            } catch {
                guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
                // **The provider's failure, typed where the compiler sees `any Error`**: inside this closure the
                // typed-throws call no longer narrows `error` (measured 2026-10-25), so the session names the type
                // itself. A cancelled call is the session's own cancellation, not a source failure; anything else
                // that is not an `AIProviderError` is reported as an unrecognised framework failure rather than lost.
                let failure = error as? AIProviderError ?? .framework(String(describing: type(of: error)))
                if failure == .cancelled { return Performed(state: .cancelled, sent: sent) }
                return Performed(state: .unavailable(.provider(failure)), sent: sent)
            }
            guard !Task.isCancelled else { return Performed(state: .cancelled, sent: sent) }
            do {
                let answer = try AIAnswerValidator.validate(json: Data(raw.utf8), mode: sent.mode, entry: entry,
                                                           sense: sent.sense)
                return Performed(state: .answer(answer, mode: sent.mode), sent: sent)
            } catch let invalid as AIAnswerError {
                return Performed(state: .invalid(invalid), sent: sent)
            } catch {
                // The validator throws only `AIAnswerError`; a different error is a harness fault, reported as a shape
                // failure rather than cast away (`error` is `any Error` inside this closure, measured 2026-10-25).
                return Performed(state: .invalid(.shape), sent: sent)
            }
        }
    }

    /// Runs one send under a source permit and releases it once, on every path.
    private nonisolated static func withPermit(
        _ source: AIProviderKind, _ body: () async -> Performed
    ) async -> Performed {
        let result = await body()
        await MeaningQueue.shared.release(source)
        return result
    }

    /// **A direct ask's composition and send**, apart from the session's state so cancellation is decided by `generation`
    /// alone. The preview's own Send is `sendPreview()`.
    private nonisolated static func composeAndSend(
        handoff: MeaningHandoff, mode: AIMode, target: (DictId, EntryRef)?, selection: MeaningSelection?,
        dictionaryName: String?, settings: MeaningSettings,
        fetchEntryText: @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>,
        makeProvider: @Sendable (MeaningSettings, AIMode) throws(AIProviderError) -> any AIProvider,
        recheck: @Sendable () async -> MeaningSettings
    ) async -> Performed {
        guard settings.source != nil else { return Performed(state: .unavailable(.noSource), sent: nil) }
        let composed = await Self.compose(handoff: handoff, mode: mode, target: target, selection: selection,
                                          dictionaryName: dictionaryName, settings: settings,
                                          fetchEntryText: fetchEntryText)
        // **Nothing was sent on a refusal** (audit rounds 1–4, 2026-10-26): `sent` is what the pane's evidence names and
        // what a note records as its provenance; a request that stopped at a check never reached the source.
        if let failure = composed.failure { return Performed(state: failure, sent: nil) }
        guard let sent = composed.sent else { return Performed(state: .unavailable(.noEntry), sent: nil) }
        // **After the fetch**: the reader may have turned the switch off while the entry was read.
        guard Self.consentHolds(await recheck(), mode: mode) else {
            return Performed(state: .unavailable(.consentChanged), sent: nil)
        }
        guard !Task.isCancelled else { return Performed(state: .cancelled, sent: nil) }
        return await send(sent: sent, entry: composed.entry, settings: settings,
                          makeProvider: makeProvider, recheck: recheck)
    }
}
