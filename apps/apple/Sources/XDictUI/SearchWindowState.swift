import Foundation
import Observation
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictSpeech

/// **One main window** (plan-macos-v1 WI-6): its search (`SearchModel`), the library it searches, the entry view it
/// shows entries in, and what the window asks of the app — the library window, and the keyboard for its search field.
/// The entry view's links come back here and are followed in the dictionary whose entry they are in (I7); its sounds
/// and spoken words are pronounced from that dictionary, in its declared language (WI-7).
@MainActor
@Observable
public final class SearchWindowState {
    public let model: SearchModel
    public let library: Library
    public let entry: EntryViewController
    /// The entry's sounds and the system voice (WI-7): what the window's notice shows.
    public let pronunciation: Pronunciation
    /// What the dictionary service answered at launch: shown when it did not.
    public var service = LaunchStatus.asking
    /// Asks the search field for the keyboard whenever it changes (at launch, and by Search, ⌥⌘F).
    public private(set) var searchFocus = 1
    /// Asks the results list for the keyboard whenever it changes (↓ from the search field).
    public private(set) var resultsFocus = 0
    /// The dictionary whose entry the pane shows: its links are looked up there.
    public private(set) var presented: UUID?
    /// **Which lookup the entry view was last handed**, so a document's finish is acknowledged only for the lookup shown
    /// now (plan-capture WI-4 rule 3): a stale document finishing in the gap before a newer lookup's entry request
    /// acknowledged the newer term `shown`.
    @ObservationIgnored private var presentedEntry = PresentedEntry()
    /// **Which phrase ask this window is on** (audit round 1, 2026-10-26): a newer tap supersedes an older one still
    /// waiting for its lookup, so the older never adopts or asks.
    @ObservationIgnored private var phraseAskSerial = 0

    /// Whether the entry view was asked to show the lookup the model shows now — the identity a finished document's
    /// acknowledgement rests on (both the lookup and its shown entry: while a newer lookup awaits its first result the
    /// shown entry is still the older lookup's). False before the first ask, and while a newer lookup is still on its way.
    public var showsPresentedLookup: Bool {
        guard let shown = model.shown else { return false }
        return presentedEntry.isCurrent(serial: shown.serial, lookup: shown.lookup)
            && shown.lookup == model.lookup?.serial
    }

    /// Settings ▸ Dictionaries, at one dictionary or none (ADR-0012 d.4: `SettingsRoute.show`).
    @ObservationIgnored public var showDictionaries: (@MainActor (UUID?) -> Void)?
    /// Each entry handed to the entry view, and whether it was: for the instruments.
    @ObservationIgnored public var onPresented: (@MainActor (SearchModel.Shown, Bool) -> Void)?
    /// A word ⌘-clicked in the entry, looked up in a new tab of this window (parity P47). Unset in the lookup popover,
    /// where a ⌘-click does nothing new.
    @ObservationIgnored public var openInNewTab: (@MainActor (String) -> Void)?

    /// **"Meaning here"** (ADR-0021, plan-ai-meaning WI-5): the presentation's sentence, its one ask and its answer. Fed
    /// `entry_text` through the service, the sources are the app's (`MeaningProviders`), and the settings it reads are
    /// the AI pane's (WI-6).
    public let meaning: MeaningSession

    /// **The reverse-example results** (ADR-0031, plan-reverse-examples WI-5): asked for a Chinese lookup in scope,
    /// shown in the right pane's Examples section.
    public let examples: ExamplesModel

    /// **The phrase around the captured term** (contract 15, plan-phrase-recognition WI-8), shown in the panel and the
    /// window's title row.
    public let phrases: PhrasesModel

    @ObservationIgnored private let backend: any SearchBackend

    /// `window` names the window's callers in the service client, so two windows never supersede each other. `speech`
    /// is where its sound leaves the app, `speechPreferences` the reader's accent: the system's and the reader's own,
    /// unless an instrument passes a silent output and a defaults suite of its own.
    public init(library: Library, backend: any SearchBackend, entry: EntryViewController, window: String,
                speech: any PronunciationOutput = SystemOutput(),
                speechPreferences: SpeechPreferences = SpeechPreferences()) {
        self.library = library
        self.backend = backend
        self.entry = entry
        let model = SearchModel(backend: backend, window: window, guesser: SystemSpellingGuesser()) { [library] in
            library.searchSources
        }
        self.model = model
        examples = ExamplesModel(backend: backend, window: window)
        phrases = PhrasesModel(backend: backend, window: window)
        meaning = MeaningSession(
            fetchEntryText: { [backend] dict, entry, budget in
                await backend.entryText(dict, entry: entry, maxTextBytes: budget)
            },
            presented: { [weak model] in model.flatMap(Self.drawnEntry) },
            makeProvider: MeaningProviders.make)
        // **The reader's choices are Settings ▸ AI's** (plan-ai-meaning WI-6): read at each ask, and only then, so the
        // store is not touched by a window that never asks (and a test never reads the Keychain).
        meaning.settingsProvider = { MeaningPreferences.shared.settings }
        // **The evidence names its dictionary** (HIG audit UI11): a grounded ask records the name its target's
        // dictionary has in the library now, in the request's own snapshot.
        meaning.dictionaryNamer = { [library] handle in
            library.searchSources.first { $0.handle == handle }?.name
        }
        pronunciation = Pronunciation(backend: backend, output: speech, preferences: speechPreferences)
        model.scrollReader = { [weak entry] in await entry?.scrollOffset() }
        entry.onLookup = { [weak self] query, anchor in self?.follow(query, anchor: anchor) }
        entry.onSound = { [weak self] path in self?.playRecording(path) }
        entry.onSpeak = { [weak self] text in self?.speak(text) }
        entry.onOpenInNewTab = { [weak self] word in self?.openInNewTab?(word) }
        // **A click on a sense names the frame's own entry** (plan-explain-sense WI-5): the window matches it to what
        // it presents now, so a forged ordinal or a frame that is gone selects nothing.
        entry.onSelectSense = { [weak self] handle, edition, reference, id in
            self?.selectSense(handle: handle, edition: edition, reference: reference, id: id)
        }
        entry.onPageSourcesChanged = { [weak self] sources in self?.pageSources = sources }
        // **The presentation follows the scope wherever it was changed** (audit round 4, 2026-10-25): the picker, the
        // Search menu and the keyboard all end in `setScope`.
        model.scopeDidChange = { [weak self] in self?.scopeChanged() }
    }

    /// **The All page's dictionaries and the one being read** (HIG audit UI24): Go ▸ Dictionaries on This Page lists
    /// them, and the current one's name is pinned over the page once its divider has scrolled away. Nil off the page.
    public private(set) var pageSources: EntryPageSources?

    /// Go ▸ Dictionaries on This Page: the page scrolled to that dictionary.
    public func jumpToSource(_ id: UUID) { entry.jumpToPageSource(id) }

    /// **Which panes the reader chose to see** (HIG audit UI02, UI05, UI07): the answer pane and the results list.
    var panes = SearchPanes()

    public func focusSearch() { searchFocus += 1 }
    public func focusResults() { resultsFocus += 1 }

    // MARK: - Meaning here

    /// **The reader clicked a sense in an entry** (plan-explain-sense WI-5; ADR-0029 d.6): the click carries the
    /// frame's own handle, edition and reference, and is accepted only when that entry is one this window presents now
    /// — the single entry, or one of the All page's frames. On the All page the selection names that frame's dictionary,
    /// never `model.shown`'s.
    public func selectSense(handle: String, edition: String, reference: EntryReference, id: UInt32) {
        guard meaning.held != nil,
              let selection = Self.senseTarget(
                  handle: handle, edition: edition, reference: reference, sense: id,
                  among: presentedResults.map { (result: $0, source: model.source($0.dictionary)) })
        else { return }
        meaning.select(selection)
    }

    /// **The chosen sense, marked in its frame** (HIG audit UI21): what the session holds, drawn where the reader chose
    /// it; no selection clears every mark.
    public func markSelection() {
        let selection = meaning.selection
        entry.markSense(handle: selection?.dictionary.rawValue,
                        reference: selection.map { EntryReference(key: $0.entry.key, occurrence: $0.entry.occurrence) },
                        id: selection?.sense)
    }

    /// Go ▸ Next/Previous Sense (UI22): the keyboard's way to choose a sense, only while a captured sentence is held.
    public func stepSense(_ delta: Int) {
        guard meaning.held != nil else { return }
        entry.stepSense(delta)
    }

    /// Go ▸ Clear Chosen Sense (UI23): the choice goes; a finished answer stays.
    public func clearSense() { meaning.clearSelection() }

    /// The results list shows: there is a listing and the reader has not hidden it (UI07).
    var resultsShown: Bool { panes.resultsVisible(listed: model.listing != nil) }

    /// **Show in the Entry** (HIG audit UI11): the quoted text revealed only in the frame the answer was about, named
    /// by its frozen target (the dictionary's handle, the edition, the record); never a search of the page at large,
    /// where another dictionary's similar wording could be found instead. False when the answer has no target or no
    /// frame shown carries it, or the text is not visible there: the pane says so rather than doing nothing.
    @discardableResult
    public func revealEvidence(_ quote: String, target: MeaningTarget?) -> Task<Bool, Never> {
        guard let target else { return Task { false } }
        return entry.revealEvidence(quote, in: Self.evidenceFrame(target))
    }

    /// The frame a frozen target names: its dictionary's handle, its edition and its edition-qualified record.
    nonisolated public static func evidenceFrame(_ target: MeaningTarget) -> EntryFrameName {
        EntryFrameName(handle: target.dictionary.rawValue, edition: target.entry.edition.rawValue,
                       reference: EntryReference(key: target.entry.key, occurrence: target.entry.occurrence))
    }

    /// The entries this presentation offers: the All page's frames while one is shown, else the shown entry.
    public var presentedResults: [ResultID] {
        if let results = pageResults { return results }
        guard let shown = model.shown else { return [] }
        return [shown.result]
    }

    /// **The frame's entry matched to what is presented** (plan-explain-sense WI-5): the ordinal alone is never trusted;
    /// the dictionary's handle, the edition and the reference must all name one of these entries, whose name the pane
    /// then shows. Two dictionaries with the same ordinal are told apart by the frame.
    nonisolated static func senseTarget(handle: String, edition: String, reference: EntryReference, sense: UInt32,
                                        among presented: [(result: ResultID, source: SearchSource?)]) -> MeaningSelection? {
        guard let match = presented.first(where: { candidate in
            candidate.source?.handle?.rawValue == handle
                && candidate.result.entry.edition.rawValue == edition
                && candidate.result.entry.key == reference.key
                && candidate.result.entry.occurrence == reference.occurrence
        }) else { return nil }
        return MeaningSelection(dictionary: DictId(rawValue: handle), entry: match.result.entry, sense: sense,
                                dictionaryName: match.source?.name)
    }

    /// **A draw that ends the sentence ends the phrase row with it** (audit round 3, 2026-10-26): `MeaningSession` drops
    /// the sentence when a different entry draws, and the row asks about that very sentence — only `holdMeaning` and
    /// `clearMeaning` used to keep the two together.
    public func entryDrew(_ subject: MeaningSession.Subject, target: (DictId, EntryRef)?, lookup: Int?) {
        let hadSentence = meaning.held != nil
        meaning.drawn(subject, target: target, lookup: lookup)
        if hadSentence, meaning.held == nil { phrases.clear() }
    }

    /// The entry drawn now, as an ask's target: its dictionary's handle and its edition-qualified reference.
    static func drawnEntry(_ model: SearchModel) -> (DictId, EntryRef)? {
        guard let shown = model.shown, let source = model.source(shown.result.dictionary), let handle = source.handle
        else { return nil }
        return (handle, shown.result.entry)
    }

    /// **A sentence is handed to this presentation** (a delivery in the popover, or the popover's hand-off on expansion):
    /// held until the presentation ends or draws another entry, and cancelling any ask that was about the last one.
    public func holdMeaning(_ handoff: MeaningHandoff, asking: Bool = false,
                            expecting: MeaningSession.Subject? = nil, adopted: Bool = false) {
        // **An expansion's ask waits for its own adopted entry** (audit findings, 2026-10-20): asking here sent the
        // window's previous entry, or failed in a new window; the expected subject keeps a stale draw from starting it,
        // and the adopted lookup's identity keeps a queued presentation of the previous lookup from binding it.
        meaning.hold(handoff, asking: asking, expecting: expecting, adopted: adopted)
        // **The phrase row follows the captured sentence** (contract 15; plan-phrase-recognition WI-8): the capture is
        // the reader's tap, so the question is asked here and nowhere else. A capture that carried no term range is not
        // asked — the core needs the term's place in the sentence — and the row stays hidden.
        if handoff.phrase != nil {
            // A phrase ask is already about the phrase: detecting one under its own span would offer itself.
            phrases.clear()
        } else if let range = handoff.range {
            phrases.update(sentence: handoff.sentence,
                           term: PhraseTerm(location: UInt64(range.location), length: UInt64(range.length)),
                           handles: phraseHandles)
        } else {
            phrases.clear()
        }
    }

    /// Every enabled dictionary that answers now, in the reader's order: what the phrase question asks.
    public var phraseHandles: [DictId] {
        library.searchSources.filter(\.enabled).compactMap(\.handle)
    }

    /// **The phrase row chosen**: the dictionary's own spelling becomes the lookup, in place, so Back returns to the
    /// word that found it. A template (`take something into account`) is a lookup key like any link's.
    public func openPhrase(_ phrase: String) {
        model.submit(phrase)
    }

    /// **The reader asks about the phrase** (AI contract 5; plan-phrase-recognition WI-9): the question's term becomes
    /// the words the reader met — the sentence's own span — and its target the phrase's entry, found by the reader's
    /// ordinary lookup of the dictionary's spelling. Recognition alone changed nothing: this is the tap. With the
    /// entry-text switch off the session refuses it, as it refuses any grounded ask.
    public func askAboutPhrase(_ candidate: PhraseRow.Candidate) async {
        guard let held = meaning.held, held.phrase == nil,
              let span = PhrasesModel.span(candidate, in: held.sentence),
              let source = source(for: candidate.dict) else { return }
        // **The presentation and the ask this tap belongs to** (audit round 1, 2026-10-26): the lookup is awaited, and
        // a newer capture, a navigation or another phrase ask in the meantime must not have its sentence replaced by
        // this one — two asks on one handoff must not both land.
        phraseAskSerial += 1
        let ask = phraseAskSerial
        let presentation = meaning.handoffToken
        let lookup = model.lookup?.serial
        let options = LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil)
        let answer = await backend.request(.lookup(query: candidate.phrase, dicts: [candidate.dict], options: options))
        guard phraseAskSerial == ask, model.lookup?.serial == lookup, meaning.handoffToken == presentation,
              let now = meaning.held, now.phrase == nil,
              now.term == held.term, now.sentence == held.sentence, now.range == held.range,
              self.source(for: candidate.dict) != nil
        else { return }
        guard case .success(let delivered) = answer, case .page(let page) = delivered.answer, let hit = page.hits.first
        else { return }
        let handoff = MeaningHandoff(term: String(held.sentence[span]), sentence: held.sentence,
                                     range: NSRange(span, in: held.sentence), cut: held.cut, origin: held.origin,
                                     phrase: candidate.phrase)
        // **The phrase's entry is drawn and adopted, and the ask waits for it**, as an expansion's does: a stale draw
        // never claims the sentence, and the target is the phrase's entry, never the word's.
        let expected = MeaningSession.Subject(dictionary: source.id, key: hit.entry.key,
                                              occurrence: hit.entry.occurrence)
        // **The place is the phrase's own dictionary**, as `SearchModel.open` makes it (audit round 2): the reader's
        // scope may name another dictionary, and a visit adopted under it would show one entry under another's scope.
        let place = Visit(query: candidate.phrase, mode: .reader, scope: .one(source.id),
                          result: ResultID(dictionary: source.id, entry: hit.entry), typed: nil, isOrigin: false)
        holdMeaning(handoff, asking: true, expecting: expected, adopted: true)
        let token = meaning.handoffToken
        model.adopt(place, started: { [weak self] serial in self?.meaning.adopted(serial, handoff: token) })
    }

    /// **A lookup replaced the presentation**: a query other than the held sentence's word means the reader moved on, and
    /// the captured sentence is dropped — including a lookup that draws no entry at all, which `drawn` never sees.
    /// **The examples belong to the lookup shown** (ADR-0031 d.9): a new query resets them, and one with no Chinese
    /// leaves the section closed.
    public func lookupDidChange() {
        let lookup = model.lookup
        // **A phrase ask's own lookup keeps its sentence** (AI contract 5; plan WI-9): the question's term is the
        // sentence's words, while the window looks the dictionary's spelling up, so the two differ by design. Any other
        // query is the reader moving on, and drops the sentence as before.
        let phraseAsk = meaning.held?.phrase != nil && lookup?.query == meaning.held?.phrase
        if let held = meaning.held, let lookup, lookup.query != held.term, !phraseAsk { clearMeaning() }
        panes.examplesSearched()
        let kept = examples.update(query: lookup?.query ?? "", handles: exampleHandles,
                                  unavailable: exampleUnavailable)
        if lookup == nil || !ExamplesModel.hasCJK(lookup?.query ?? "") {
            panes.examplesCleared()
        } else if kept {
            // The same query over the same dictionaries: its pairs are still current, so the pane reopens on them
            // rather than waiting for a revision that will not come (audit, 2026-10-24).
            examplesContentChanged()
        }
    }

    // MARK: - The examples section (ADR-0031, plan-reverse-examples WI-5)

    /// The dictionaries in the lookup's scope, in the reader's order: the handles the examples query asks.
    public var exampleHandles: [DictId] {
        exampleSources.compactMap { source in
            switch model.lookup?.scope ?? model.scope {
            case .all:
                return source.handle
            case .one(let id):
                return source.id == id ? source.handle : nil
            }
        }
    }

    /// The dictionaries whose example build failed this session: a missing store there is a failure, not a build
    /// still running.
    public var exampleUnavailable: [DictId] {
        exampleSources.compactMap { source in
            guard case .unavailable = library.examples[source.id] else { return nil }
            return source.handle
        }
    }

    /// The enabled dictionaries with an open handle, in the reader's order.
    private var exampleSources: [(id: UUID, handle: DictId)] {
        library.searchSources.compactMap { source in
            guard source.enabled, let handle = source.handle else { return nil }
            return (source.id, handle)
        }
    }

    /// The query's examples arrived: the pane opens, unless the reader closed it for this query.
    public func examplesContentChanged() {
        if examples.hasContent { panes.examplesAsked() }
    }

    /// **A dictionary's store changed state** (ADR-0031 d.6): once a dictionary that was still building is ready, the
    /// model asks again — never before, and never in the query itself.
    public func examplesLibraryChanged() {
        var ready: [DictId] = []
        var unavailable: [DictId] = []
        for source in exampleSources {
            switch library.examples[source.id] {
            case .ready: ready.append(source.handle)
            case .unavailable: unavailable.append(source.handle)
            case .building, nil: break
            }
        }
        examples.buildStateChanged(ready: ready, unavailable: unavailable)
    }

    /// The reader closed the Examples section: the Meaning answer, if shown, stays.
    public func closeExamples() {
        panes.examplesClosed()
    }

    /// The library's dictionary for a service handle, as the reader knows it.
    public func source(for handle: DictId) -> SearchSource? {
        library.searchSources.first { $0.handle == handle }
    }

    /// **An example row chosen**: its entry opens in the dictionary that printed it — the first of its sources this
    /// library still has. The entry is shown in place, so Back returns to the word that found it.
    public func openExample(_ hit: ExampleHit) {
        guard let candidate = Self.firstAvailableSource(hit, isAvailable: { source(for: $0) != nil }),
              let source = source(for: candidate.dict) else { return }
        model.open(ResultID(dictionary: source.id, entry: candidate.entry))
    }

    /// **A pair's own source, chosen by the reader** (plan-companion WI-12): when a pair came from more than one
    /// dictionary, the attribution offers each one the library has; the plain click keeps the first available.
    public func openExample(_ hit: ExampleHit, in dictionary: DictId) {
        guard let source = source(for: dictionary), let entry = Self.exampleEntry(hit, in: dictionary) else { return }
        model.open(ResultID(dictionary: source.id, entry: entry))
    }

    /// The first of a pair's sources the library has, in the pair's own order: a source whose dictionary was removed is
    /// skipped, never opened in another dictionary's frame.
    nonisolated static func firstAvailableSource(_ hit: ExampleHit, isAvailable: (DictId) -> Bool) -> ExampleSource? {
        hit.sources.first { isAvailable($0.dict) }
    }

    /// A pair's entry in one named dictionary, when the pair came from it.
    nonisolated static func exampleEntry(_ hit: ExampleHit, in dictionary: DictId) -> EntryRef? {
        hit.sources.first { $0.dict == dictionary }?.entry
    }

    // MARK: - Saving an answer as a note (plan-companion WI-9; owner, 2026-10-25)

    /// The shell's study model, wired by the app: nil hides the pane's Save as Note (an instrument window, a test).
    @ObservationIgnored public var noteSaver: (@MainActor (EntryRef, String, String) async -> Bool)?
    /// Whether an entry already carries a note, so a save asks before replacing it; nil when that cannot be known (the
    /// notes did not load), and then nothing is written.
    @ObservationIgnored public var entryNoteCheck: (@MainActor (EntryRef) async -> Bool?)?

    /// **Saves the answer the reader asked to keep** on the entry it was composed from. The caller builds the text — the
    /// explanation, its quotes and the provenance line; the sentence never goes in.
    public func saveNote(for target: MeaningTarget, text: String) async -> Bool {
        guard let noteSaver else { return false }
        return await noteSaver(target.entry, text, source(for: target.dictionary)?.name ?? "")
    }

    /// Whether that entry already has a note; nil when the check could not answer.
    public func entryHasNote(_ entry: EntryRef) async -> Bool? {
        guard let entryNoteCheck else { return false }
        return await entryNoteCheck(entry)
    }

    /// **A scope change can change which presentation is due** (audit round 4, 2026-10-25): the same shown entry is one
    /// frame or an All page depending on the scope, and the model may keep it while the lookup changes.
    public func scopeChanged() {
        guard let shown = model.shown else { return }
        Task { await present(shown) }
    }

    /// The presentation ended: the sentence goes (it was never anywhere else), and so does the ask in flight — the
    /// phrase row with it (contract 15).
    public func clearMeaning() {
        meaning.clear()
        phrases.clear()
    }

    /// A link in the shown entry: looked up in link mode in that entry's dictionary (on the All page, the dictionary
    /// of the frame it is in).
    public func follow(_ query: String, anchor: String?) {
        guard let from = entry.activeItem ?? presented else { return }
        model.follow(query, anchor: anchor, from: from)
    }

    // MARK: - Sound and speech (WI-7)

    /// The language the active frame's dictionary is declared in (the library's, WI-5): what its sounds are spoken in.
    public var presentedLanguage: String? {
        searchLanguage(entry.activeItem ?? presented)
    }

    /// The search language a dictionary declares, by its library id; nil when the library has none.
    private func searchLanguage(_ dictionary: UUID?) -> String? {
        guard let dictionary else { return nil }
        return library.entries.first { $0.id == dictionary }?.languages.pair.search
    }

    /// The shown entry's word: its headword as its dictionary gives it, else its key.
    public var shownWord: String? {
        guard let shown = model.shown else { return nil }
        return model.hit(shown.result)?.headword ?? shown.result.entry.key
    }

    /// Whether the speak button has a word, in a dictionary, to say.
    public var canPronounce: Bool { presented != nil && shownWord != nil }

    /// A `sound://` link in the shown entry: its recording, from the open dictionary the entry was read from, or the
    /// entry's word spoken in its place. **The fallback word and language come from the frame the sound came from**
    /// (audit round 1, 2026-10-25): on the All page another dictionary's frame can show another word than the primary.
    public func playRecording(_ path: String) {
        guard let handle = entry.binding?.handle else { return }
        let dictionary = DictId(rawValue: handle)
        let word = frameWord(for: dictionary) ?? ""
        let language = searchLanguage(source(for: dictionary)?.id) ?? presentedLanguage
        Task { await pronunciation.playRecording(path, from: dictionary, word: word, language: language) }
    }

    /// **The word one dictionary's frame shows** (audit round 1, 2026-10-25): the primary's own hit, or `AllPage`'s one
    /// rule for another dictionary's frame — shared, never re-derived (audit round 2).
    private func frameWord(for handle: DictId) -> String? {
        guard let source = source(for: handle), let shown = model.shown else { return nil }
        let shownHit = model.hit(shown.result)
        if source.id == shown.result.dictionary {
            return shownHit?.headword ?? shown.result.entry.key
        }
        guard let section = model.sections.first(where: { $0.id == source.id }),
              let hit = AllPage.hit(in: section, headword: shownHit?.headword) else { return nil }
        return hit.headword.isEmpty ? hit.entry.key : hit.headword
    }

    /// A `.tts` link in the shown entry: its text, in the dictionary's language.
    public func speak(_ text: String) {
        pronunciation.speak(text, language: presentedLanguage)
    }

    /// **The language to speak the pane's term in** (Codex refutation, 2026-10-25): the answer's own dictionary when the
    /// library knows it, else the shown entry's. The shown entry can be another dictionary entirely on the All page, so
    /// `pronounceShown`'s language is not the answer's.
    nonisolated static func termLanguage(for target: MeaningTarget?, languageOf: (DictId) -> String?,
                                         presented: String?) -> String? {
        target.flatMap { languageOf($0.dictionary) } ?? presented
    }

    /// **Speak the captured term** for the answer pane: the answer's dictionary's language, not the shown frame's; no
    /// recording is resolved here (the entry view owns a `sound://` link's playback).
    public func pronounceTerm(_ term: String, for target: MeaningTarget?) {
        let language = Self.termLanguage(for: target, languageOf: { handle in
            searchLanguage(source(for: handle)?.id)
        }, presented: presentedLanguage)
        pronunciation.speak(term, language: language)
    }

    /// The speak button: the shown entry's word, as written, in the shown entry's own dictionary language — never the
    /// last frame the reader touched, which can be another language (audit round 1, 2026-10-25).
    public func pronounceShown() {
        guard let word = shownWord else { return }
        pronunciation.speak(word, language: searchLanguage(presented))
    }

    /// The title bar's speaker and Edit ▸ Pronounce: the entry's selected text, else the shown word. **The selection and
    /// its language come from the same frame** (audit rounds 2 and 3, 2026-10-25): `selectedTextAndFrame()` reads the
    /// focused frame and names it; the fallback word belongs to the shown entry. The presentation is read before the
    /// await, so a navigation during the read drops the result.
    public func pronounceSelectionOrShown() {
        let word = shownWord
        let shownLanguage = searchLanguage(presented)
        let shown = model.shown
        Task { @MainActor in
            guard let read = await entry.selectedTextAndFrame(), model.shown == shown,
                  let spoken = Self.spoken(selection: read.text, word: word) else { return }
            pronunciation.speak(spoken.text, language: spoken.isSelection
                                                        ? searchLanguage(read.item ?? presented)
                                                        : shownLanguage)
        }
    }

    /// **What the speaker says, and whether it is a selection**: one normalisation for the text and its language (audit
    /// round 3). Nil when there is neither a selection nor a word.
    public static func spoken(selection: String?, word: String?) -> (text: String, isSelection: Bool)? {
        let selected = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty { return (selected, true) }
        guard let word else { return nil }
        return (word, false)
    }

    /// Shows the model's entry in the pane, from its dictionary as the library has it now: for a typed word over every
    /// dictionary, the All page (P15) with every dictionary's entry, the shown one among them.
    public func present(_ shown: SearchModel.Shown) async {
        // **A queued presentation the model has passed is stale and draws nothing** (verification finding, 2026-10-20):
        // the serial says the window has moved on, and binding the held sentence — or firing its deferred ask — to an
        // entry no longer shown would send the wrong entry. `ask()` samples the presented entry in the same turn as the
        // draw, so with this guard the target is the one the subject names.
        // **The lookup is part of the presentation's identity** (audit round 4, 2026-10-25): a shown result kept from the
        // previous lookup must not draw under the new lookup's scope and sections.
        guard model.shown == shown, shown.lookup == model.lookup?.serial else { return }
        // An entry about to be drawn: the held sentence belongs only to this presentation's own entry, so a reader who
        // moved on is asked `noContext`, never sent the wrong entry. The drawn target travels with the subject, so a later
        // ask cannot sample a presentation that replaced this one.
        let target = model.source(shown.result.dictionary).flatMap { source in
            source.handle.map { ($0, shown.result.entry) }
        }
        entryDrew(MeaningSession.Subject(dictionary: shown.result.dictionary, key: shown.result.entry.key,
                                         occurrence: shown.result.entry.occurrence), target: target,
                  lookup: shown.lookup)
        if let lookup = model.lookup, AllPage.applies(scope: lookup.scope, mode: lookup.mode) {
            await presentPage(shown)
            return
        }
        guard let source = model.source(shown.result.dictionary),
              let content = ServiceEntryContent(source: source, backend: backend, preferences: entry.preferences) else {
            onPresented?(shown, false)
            return
        }
        presented = source.id
        let landing: EntryLanding = switch shown.landing {
        case .top: .top
        case .anchor(let name): .anchor(name)
        case .offset(let y): .offset(y)
        }
        let reference = EntryReference(key: shown.result.entry.key, occurrence: shown.result.entry.occurrence)
        let done = await entry.show(reference, from: content, landing: landing)
        if done { presentedEntry.asked(serial: shown.serial, lookup: shown.lookup) }
        onPresented?(shown, done)
    }

    // MARK: - The All page (P15)

    /// **The dictionaries this word can be answered from** (owner, 2026-10-26): the page's results in its order, each
    /// named and ready to ground an ask. One or none off the page, where there is nothing to choose.
    public var groundingChoices: [MeaningGrounding.Choice] {
        guard let results = pageResults else { return [] }
        return MeaningGrounding.choices(results: results, sources: model.known)
    }

    /// **The reader chose the dictionary that answers** (owner, 2026-10-26): the question already asked about this
    /// sentence, grounded in the chosen dictionary's entry.
    public func askMeaning(in target: MeaningTarget) {
        meaning.ask(in: target)
        // The marks follow the choice: a sense chosen on the entry just left has no row left to mark.
        markSelection()
    }

    /// The entries the All page holds now: changes as each dictionary answers, so the page grows in the reader's order.
    /// Nil when no page is due.
    public var pageResults: [ResultID]? {
        guard let shown = model.shown, let lookup = model.lookup, AllPage.applies(scope: lookup.scope, mode: lookup.mode)
        else { return nil }
        let current = shown.lookup == model.lookup?.serial
        return AllPage.results(sections: model.sections, shown: shown.result,
                               headword: current ? model.hit(shown.result)?.headword : nil, shownIsCurrent: current)
    }

    private func pageItems(_ results: [ResultID]) -> [EntryPageItem] {
        results.compactMap { result in
            guard let source = model.source(result.dictionary),
                  let content = ServiceEntryContent(source: source, backend: backend, preferences: entry.preferences)
            else { return nil }
            return EntryPageItem(id: source.id, name: source.name, content: content,
                                 reference: EntryReference(key: result.entry.key, occurrence: result.entry.occurrence))
        }
    }

    private func presentPage(_ shown: SearchModel.Shown) async {
        guard let results = pageResults, model.source(shown.result.dictionary) != nil else {
            onPresented?(shown, false)
            return
        }
        presented = shown.result.dictionary
        let landing: EntryLanding = if case .offset(let y) = shown.landing { .offset(y) } else { .top }
        let done = await entry.showPage(pageItems(results), primary: shown.result.dictionary, landing: landing)
        if done { presentedEntry.asked(serial: shown.serial, lookup: shown.lookup) }
        onPresented?(shown, done)
    }

    /// Another dictionary answered while the page is shown: the page again, its frames kept, the new ones in place.
    /// **A presentation the window has left by the time the task runs draws nothing** (audit round 1, 2026-10-25): a
    /// navigation, a placeholder that closed the entry, or another page makes these results obsolete.
    public func pageResultsChanged() {
        guard let results = pageResults, entry.pageFrames != nil else { return }
        let shown = model.shown
        let lookup = model.lookup
        let primary = shown?.result.dictionary
        Task { @MainActor in
            // The lookup is its own identity: `begin()` can start another while the same entry is still shown.
            guard let shown, model.shown == shown, model.lookup == lookup, entry.pageFrames != nil else { return }
            await entry.showPage(pageItems(results), primary: primary)
        }
    }

    /// What covers the entry pane now (UI review X1): "No entries found." only once the list has settled empty, so it
    /// never flashes before a completion or a guess is shown (P10, P13).
    public var placeholder: EntryPlaceholder {
        let pending = model.listing.map { !$0.settled || !$0.headwords.isEmpty } ?? false
        let unsearched = model.sections.filter { if case .unavailable(let why) = $0.status {
            if case .indexing = why { false } else { true } } else { false } }.count
        return EntryPlaceholder.of(noDictionaries: library.entries.isEmpty && library.unreadable == nil,
                                   query: model.lookup?.query, selection: model.selection,
                                   searching: model.isSearching, unsearched: unsearched, pending: pending)
    }

    /// Whether an entry, or the All page, is shown: what the menus' entry commands (Print…, Find…, Expand All…) are
    /// enabled by. Read from the observed model, never from the entry view's web view, which SwiftUI cannot observe:
    /// keyed on that, every such item stayed disabled on the All page after a search (UI tour `page.print`, 2026-10-18).
    // **A placeholder that covers the pane means no entry is readable**, whatever the previous lookup left
    // (audit round 2): entry commands are disabled with the document the reader cannot see.
    public var hasEntry: Bool { model.shown != nil && !placeholder.clearsEntry }

    /// A placeholder that covers the pane closes the entry under it, so VoiceOver cannot reach a previous lookup's
    /// entry either (UI review X1). Called when the placeholder changes.
    public func placeholderChanged() {
        // **A settled lookup with nothing drawn ends the presentation**: the captured sentence's entry is no longer on
        // screen, even when the query was the same word (audit finding, 2026-10-20).
        switch placeholder {
        case .noResults, .noResultsIncomplete:
            // **A tap whose lookup settles with nothing drawn ends typed, not dropped** (verification finding, 2026-10-20):
            // a deferred ask still waiting when the pane settles has no entry to ground it, and `noEntry` keeps the
            // sentence beside that reason. An ask that already ended so keeps it; anything else is the reader moving on.
            if meaning.held != nil, case .unavailable(.noEntry) = meaning.state {
                break
            }
            if meaning.isWaitingToAsk {
                meaning.noEntry()
                break
            }
            if meaning.held != nil { clearMeaning() }
        case .noDictionaries:
            // No dictionary can answer: a waiting tap ends typed rather than waiting for a draw that cannot come.
            if meaning.isWaitingToAsk { meaning.noEntry() }
        case .start, .searching, .none:
            break
        }
        // **A pending presentation is invalidated whenever the placeholder clears the entry** (audit round 3, 2026-10-25):
        // `reference` is nil while the first fetch is under way, and an obsolete request could finish underneath it.
        guard placeholder.clearsEntry else { return }
        entry.closeEntry()
        presented = nil
    }

    /// What a section's next action does (Q11).
    public func perform(_ next: NextAction) {
        switch next {
        case .wait, .checkSpelling:
            break
        case .showInSettings(let id):
            showDictionaries?(id)
        case .retryImport(let id):
            library.retry(id)
        case .retryLookup(let id):
            model.retry(id)
        case .reopen:
            Task { await library.refresh() }
        case .searchEverywhere(let query):
            model.setScope(.all)
            model.submit(query)
        }
    }

    /// **The reader typed** in the search field. Only typing comes here: a text the window sets (a visit adopted from
    /// the panel, Back, Forward) reaches the field through `model.text` and starts no search.
    public func typedText(_ text: String) {
        model.text = text
        model.textDidChange()
    }

    /// Return in the search field: what typing shows confirmed, or what was typed looked up (P10).
    public func submit() {
        model.submit()
    }

    /// ↓ in the search field: the next row of the list chosen and the list given the keyboard, so the arrows go on
    /// through it (P11); ↑ does nothing there.
    public func move(_ step: Int) -> Bool {
        guard step > 0, let rows = model.listing?.headwords, !rows.isEmpty else { return false }
        let at = model.selectedHeadword.flatMap { rows.firstIndex(of: $0) }
        let next = at.map { min($0 + 1, rows.count - 1) } ?? 0
        if rows[next] != model.selectedHeadword { model.choose(headword: rows[next]) }
        focusResults()
        return true
    }
}
