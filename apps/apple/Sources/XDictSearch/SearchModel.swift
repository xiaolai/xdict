import Foundation
import Observation
import XDictClient
import XDictContract

/// **The main window's model** (plan-macos-v1 WI-6): what the reader typed, which dictionaries it asks, each one's
/// answer as it comes, the entry being read, and the trail of entries read.
///
/// - **Every dictionary is asked on its own** (Q12): one lookup each, queued in the reader's order as one caller's calls
///   (`SearchBackend.queue`), each painted as it answers; a slow one holds up no other. A newer lookup supersedes the
///   older (ADR-0009 decision 5), and an answer to an older one is never painted (Q12: the old query cannot replace the
///   new).
/// - **The scope** is every enabled dictionary, in the reader's order, or one (Q1, Q2). Sections follow the library's
///   order as it is now, so reordering reorders them; switching scope asks only the dictionaries not yet asked.
/// - **Every record** (Q10): a first page, then further ones on request, each continuing the page generation the first
///   gave (ADR-0007 decision 9), with the total.
/// - **Why a dictionary has nothing to show** is a kind with its next action (Q11), never a sentence.
/// - **The entry**: the first result of the first dictionary, in order, that has one, once every dictionary before it
///   has answered (so a later dictionary's quicker answer never takes the place the reader's order gives an earlier
///   one), unless the reader chose one first.
/// - **The trail** (I7, I8): a typed word adds a place, a link followed adds one (looked up in link mode, in the
///   dictionary the link is in), Back and Forward restore a place with its scroll, and one step returns to the word last
///   typed. Steps through the trail run one at a time, each after the last.
/// - **The list and live search** (Apple Dictionary parity P9, P10, P13): once typing pauses, the typed text is looked
///   up and its first match shown, without Return; the place it makes is replaced while the reader goes on typing, and
///   Return only confirms it. The sidebar's list (`listing`) is every matching headword, one row each, or the spelling
///   guesses the library has.
@MainActor
@Observable
public final class SearchModel {
    public struct Options: Sendable {
        /// Hits in a dictionary's first page: a screenful and more, answered quickly.
        public var firstPage: UInt32 = 100
        /// Hits in each further page: the core's whole page (`MAX_PAGE`).
        public var furtherPage: UInt32 = 1_000
        /// Keys beginning with the typed text, in the list after its own matches.
        public var suggestionLimit: UInt32 = 100
        /// How long typing must pause before the typed text is looked up and listed.
        public var suggestionDelay: Duration = .milliseconds(120)
        /// Spelling guesses checked against the library for "Did you mean?".
        public var guessLimit = 5

        public init() {}
    }

    /// The lookup the sections answer.
    public struct Lookup: Hashable, Sendable {
        public let query: String
        public let mode: MatchMode
        public let scope: SearchScope
        /// **This lookup's identity**, fresh for every ask: what tells the lookup shown now from the one a finished
        /// document belongs to (`PresentedEntry`, plan-capture WI-4 rule 3).
        public let serial: Int
    }

    /// Where to land in an entry when it is shown.
    public enum Landing: Hashable, Sendable {
        case top
        case anchor(String)
        /// A scroll offset, in CSS pixels from the top.
        case offset(Double)
    }

    /// What the entry pane should show. `serial` changes whenever it must be shown again, even the same entry (Back to
    /// it lands somewhere else).
    public struct Shown: Hashable, Sendable {
        public let result: ResultID
        public let landing: Landing
        public let serial: Int
        /// **The lookup this entry belongs to**, carried with the value (its serial): an ask records which lookup it was
        /// for from here, never by sampling the model after an await (`PresentedEntry`; audit-fix 2026-10-20 finding 1).
        public let lookup: Int?
    }

    /// One dictionary's part of the current lookup, under the handle it was asked through.
    enum Asked: Hashable {
        case searching(DictId)
        case answered(DictId, Results)
        case failed(DictId, LookupFailure)

        var handle: DictId {
            switch self {
            case .searching(let handle), .answered(let handle, _), .failed(let handle, _): handle
            }
        }
    }

    /// The search field's text. Set by the field; the model sets it when it restores a place or follows a link.
    public var text = ""
    public private(set) var lookup: Lookup?
    /// The reader's scope: what a typed word asks. A link's lookup asks its own dictionary, whatever this is.
    public private(set) var scope: SearchScope = .all
    public private(set) var selection: ResultID?
    public private(set) var shown: Shown?
    public private(set) var trail = Trail()
    /// The keys beginning with the listed text, as the dictionaries in scope suggested them.
    public private(set) var suggestions: [String] = []
    /// The sidebar's list; nil before the first search, when the sidebar is hidden.
    public private(set) var listing: Listing?
    /// The row the reader chose, or the typed place's first match; nil to read it off the entry shown.
    private var chosenHeadword: String?
    /// The dictionaries as the model last read them, in the reader's order.
    public private(set) var known: [SearchSource] = []
    private var asked: [UUID: Asked] = [:]

    /// Reads the entry pane's scroll offset, for the place being left.
    @ObservationIgnored public var scrollReader: (@MainActor () async -> Double?)?
    /// Each dictionary's answer, as it is stored: for the instruments' timing.
    @ObservationIgnored public var onAnswered: (@MainActor (UUID, Lookup) -> Void)?

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let sources: @MainActor () -> [SearchSource]
    @ObservationIgnored private let options: Options
    @ObservationIgnored private let searchCaller: Caller
    @ObservationIgnored private let suggestCaller: Caller
    @ObservationIgnored private let guessCaller: Caller
    @ObservationIgnored private let guesser: (any SpellingGuesser)?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var shownSerial = 0
    @ObservationIgnored private var listSerial = 0
    /// The keys for the listed text, once suggested.
    @ObservationIgnored private var listedKeys: [String]?
    /// The current place was made by typing and not yet confirmed: more typing replaces it.
    @ObservationIgnored private var provisional = false
    /// The landing of a result the model will choose itself, once due; nil when the reader has chosen, or nothing is due.
    @ObservationIgnored private var autoSelect: Landing?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var navigation: Task<Void, Never>?
    @ObservationIgnored private var lookups: [Task<Void, Never>] = []

    /// `window` names this window's callers, so two windows never supersede each other's lookups.
    public init(backend: any SearchBackend, window: String, options: Options = Options(),
                guesser: (any SpellingGuesser)? = nil, sources: @escaping @MainActor () -> [SearchSource]) {
        self.backend = backend
        self.sources = sources
        self.options = options
        self.guesser = guesser
        searchCaller = Caller("search.\(window)")
        suggestCaller = Caller("suggest.\(window)")
        guessCaller = Caller("guess.\(window)")
        known = sources()
    }

    // MARK: - What the window shows

    /// One section per dictionary in the lookup's scope, in the reader's order as it is now.
    public var sections: [ResultSection] {
        guard let lookup else { return [] }
        let shown = inScope(lookup.scope)
        // Lineages with two editions or more among these results: only their headers name the edition.
        var editions: [String: Set<Edition>] = [:]
        for source in shown {
            if let edition = source.edition { editions[source.preferencesKey, default: []].insert(edition) }
        }
        return shown.map { source in
            ResultSection(id: source.id, name: source.name, edition: source.edition,
                          showsEdition: (editions[source.preferencesKey]?.count ?? 0) > 1,
                          status: status(of: source, in: lookup))
        }
    }

    private func status(of source: SearchSource, in lookup: Lookup) -> SectionStatus {
        switch asked[source.id] {
        case .searching: return .searching
        case .answered(_, let results):
            return results.total == 0 && results.hits.isEmpty ? .noMatch(query: lookup.query, mode: lookup.mode)
                : .results(results)
        case .failed(_, let failure): return .failed(failure)
        case nil: return source.handle == nil ? .unavailable(Unavailable(source.state)) : .searching
        }
    }

    /// Some dictionary has not answered yet.
    public var isSearching: Bool {
        sections.contains { $0.status == .searching }
    }

    /// The sidebar's selected row: the one chosen, else the headword of the entry shown.
    public var selectedHeadword: String? {
        chosenHeadword ?? shown.flatMap { hit($0.result)?.headword }
    }

    /// How many headwords the last settled list found ("N found" under the window's title): none for guesses or an
    /// empty list. Set only when a list settles, and only when it differs (owner, 2026-10-18: the titlebar's text
    /// flashed): a list still being asked for keeps the count before it, so typing never drops the subtitle line and
    /// brings it back, and an unchanged count never lays the title out again.
    public private(set) var found: Int?

    private func settleFound(_ listing: Listing) {
        let count = listing.isGuess || listing.headwords.isEmpty ? nil : listing.headwords.count
        if found != count { found = count }
    }

    public func source(_ id: UUID) -> SearchSource? {
        known.first { $0.id == id }
    }

    /// The hit a result names, among those loaded.
    public func hit(_ id: ResultID) -> Hit? {
        guard case .answered(_, let results)? = asked[id.dictionary] else { return nil }
        return results.hits.first { $0.entry == id.entry }
    }

    // MARK: - Typing and searching

    /// The reader typed: once typing pauses, what the field holds is looked up and listed, and its first match shown
    /// (P10), as a place that more typing replaces.
    public func textDidChange() {
        liveTask?.cancel()
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !inScope(scope).compactMap(\.handle).isEmpty else { return }
        let delay = options.suggestionDelay
        liveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            self.live(typed, confirm: false)
        }
    }

    /// Looks up `query` (the field's text when nil) as typed, in the reader's scope: a new place in the trail. Return on
    /// what typing already shows only confirms it.
    public func submit(_ query: String? = nil) {
        liveTask?.cancel()
        let word = (query ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if provisional, listing?.typed == word {
            provisional = false
            return
        }
        text = word
        live(word, confirm: true)
    }

    /// A row of the list chosen (a click, or ↓ and ↑ from the field): that headword shown, the list kept, as a place of
    /// its own.
    public func choose(headword: String) {
        liveTask?.cancel()
        provisional = false
        chosenHeadword = headword
        let scope = scope, typed = listing?.typed
        navigate { model in
            await model.leaveCurrent()
            model.trail.push(Visit(query: headword, mode: .reader, scope: scope, typed: typed, isOrigin: false))
            model.begin(headword, .reader, scope, landing: .top, select: nil)
        }
    }

    /// ⌘} and ⌘{ (P7): the next or previous of All and each enabled dictionary, wrapping.
    public func stepScope(forward: Bool) {
        let scopes = [SearchScope.all] + known.filter(\.enabled).map { SearchScope.one($0.id) }
        let at = scopes.firstIndex(of: scope) ?? 0
        setScope(scopes[(at + (forward ? 1 : scopes.count - 1)) % scopes.count])
    }

    private func live(_ word: String, confirm: Bool) {
        let replace = provisional
        provisional = !confirm
        chosenHeadword = nil
        let scope = scope
        navigate { model in
            await model.leaveCurrent()
            let visit = Visit(query: word, mode: .reader, scope: scope, typed: word, isOrigin: true)
            if replace, model.trail.current != nil { model.trail.updateCurrent { $0 = visit } } else { model.trail.push(visit) }
            model.begin(word, .reader, scope, landing: .top, select: nil)
            model.relist(word)
        }
    }

    // MARK: - The list (P9, P13)

    /// Lists `typed` afresh: the keys beginning with it are asked for; its own matches are the lookup's, when the lookup
    /// is of it.
    private func relist(_ typed: String) {
        listSerial += 1
        let mine = listSerial
        listedKeys = nil
        listing = Listing(typed: typed)
        let dicts = inScope(scope).compactMap(\.handle)
        let (backend, caller, limit) = (backend, suggestCaller, options.suggestionLimit)
        Task { [weak self] in
            var keys: [String] = []
            if !dicts.isEmpty {
                let pending = await backend.queue([.suggest(prefix: typed, dicts: dicts, limit: limit)], as: caller,
                                                  superseding: true)
                if let outcome = await pending.first?.outcome(), case .success(let found) = outcome.suggestions {
                    keys = found
                }
            }
            guard let self, self.listSerial == mine else { return }
            self.suggestions = keys
            self.listedKeys = keys
            self.reconcile()
        }
    }

    /// Settles the list once the keys and the typed word's own lookup have both answered; with nothing in it, asks for
    /// spelling guesses. Called whenever either answers.
    private func reconcile() {
        guard var listing, !listing.settled, let keys = listedKeys else { return }
        var own: [String] = []
        if let lookup, lookup.mode == .reader, lookup.query == listing.typed {
            guard !isSearching else { return }
            own = sections.flatMap { section -> [String] in
                if case .results(let results) = section.status { results.hits.map(\.headword) } else { [] }
            }
        }
        let words = Listing.merged(own, keys)
        if words.isEmpty, let guesser {
            listedKeys = nil
            guess(listing.typed, from: guesser)
            return
        }
        listing.headwords = words
        listing.settled = true
        self.listing = listing
        settleFound(listing)
        showFirstMatchIfNeeded()
    }

    /// The spelling guesses some dictionary in scope has a match for, in the guesser's order (P13).
    private func guess(_ typed: String, from guesser: any SpellingGuesser) {
        let words = Array(guesser.guesses(for: typed).filter { $0 != typed }.prefix(options.guessLimit))
        let dicts = inScope(scope).compactMap(\.handle)
        let mine = listSerial
        let pairs = words.flatMap { word in dicts.map { (word, $0) } }
        let operations = pairs.map { word, handle in
            ServiceOperation.lookup(query: word, dicts: [handle],
                                    options: LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil))
        }
        let (backend, caller) = (backend, guessCaller)
        Task { [weak self] in
            var found: Set<String> = []
            if !operations.isEmpty {
                let pending = await backend.queue(operations, as: caller, superseding: true)
                for ((word, _), call) in zip(pairs, pending) {
                    if case .success(let page) = await call.outcome().page, !page.hits.isEmpty { found.insert(word) }
                }
            }
            guard let self, self.listSerial == mine, var listing = self.listing else { return }
            listing.headwords = words.filter(found.contains)
            listing.isGuess = !listing.headwords.isEmpty
            listing.settled = true
            self.listing = listing
            self.settleFound(listing)
            self.showFirstMatchIfNeeded()
        }
    }

    /// The typed word has no entry of its own but the list has rows: the first row is shown in the typed place (P10:
    /// "take o" shows "take off"; P13: the first guess).
    private func showFirstMatchIfNeeded() {
        guard let listing, let first = listing.headwords.first, let lookup, lookup.mode == .reader,
              lookup.query == listing.typed, !isSearching,
              !sections.contains(where: { if case .results = $0.status { true } else { false } }) else { return }
        chosenHeadword = first
        let scope = lookup.scope
        navigate { model in
            model.trail.updateCurrent {
                $0.query = first
                $0.result = nil
                $0.scroll = 0
            }
            model.begin(first, .reader, scope, landing: .top, select: nil)
        }
    }

    /// The reader's scope (Q1). A typed word's lookup asks the dictionaries it adds; a link's keeps its own.
    public func setScope(_ newScope: SearchScope) {
        guard newScope != scope else { return }
        scope = newScope
        guard let current = lookup, current.mode == .reader else { return }
        lookup = Lookup(query: current.query, mode: current.mode, scope: newScope, serial: current.serial)
        trail.updateCurrent { $0.scope = newScope }
        if let selection, !inScope(newScope).contains(where: { $0.id == selection.dictionary }) {
            self.selection = nil
            autoSelect = .top
        }
        ask(superseding: false)
        autoSelectIfDue()
        if let typed = listing?.typed { relist(typed) }
    }

    /// The library changed: an order, a name, a dictionary enabled, ready, gone or reopened under another handle.
    public func sourcesDidChange() {
        let now = sources()
        guard now != known else { return }
        known = now
        // **Stale handles go first, then the fallback through the scope's own transition** (audit-fix 2026-10-20 round 2,
        // finding 3): assigning `scope` alone left the active lookup asking the removed dictionary; asking before the
        // invalidation could ask a reopened dictionary through the handle it no longer has.
        for (id, answer) in asked where now.first(where: { $0.id == id })?.handle != answer.handle {
            asked[id] = nil
        }
        if case .one(let id) = scope, !now.contains(where: { $0.id == id && $0.enabled }) { setScope(.all) }
        // **The shown entry's dictionary may be the one that went** (round 3, finding 2): a selection outside the library or
        // the scope is cleared, so the model can show a dictionary that is still there instead of holding a dead one.
        if let selection, !inScope(lookup?.scope ?? scope).contains(where: { $0.id == selection.dictionary }) {
            self.selection = nil
            autoSelect = .top
        }
        ask(superseding: false)
        autoSelectIfDue()
    }

    /// The next page of one dictionary's results, continuing its generation.
    public func loadMore(_ dictionary: UUID) {
        guard let lookup, case .answered(let handle, var results)? = asked[dictionary], results.hasMore,
              !results.loadingMore else { return }
        results.loadingMore = true
        results.moreFailed = nil
        asked[dictionary] = .answered(handle, results)
        let offset = results.hits.count
        let operation = ServiceOperation.lookup(
            query: lookup.query, dicts: [handle],
            options: LookupOptions(limit: options.furtherPage, offset: UInt32(offset), mode: lookup.mode,
                                   generation: results.generation))
        let (backend, caller, serial) = (backend, searchCaller, lookup.serial)
        lookups.append(Task { [weak self] in
            let pending = await backend.queue([operation], as: caller, superseding: false)
            guard let outcome = await pending.first?.outcome() else { return }
            self?.paged(dictionary, handle: handle, serial: serial, offset: offset, outcome.page)
        })
    }

    /// Asks one dictionary again (after the service failed it).
    public func retry(_ dictionary: UUID) {
        guard asked[dictionary].map({ if case .failed = $0 { true } else { false } }) == true else { return }
        asked[dictionary] = nil
        ask(superseding: false)
    }

    // MARK: - Choosing and following

    /// The reader chose a result (or none): it replaces the entry of the current place.
    public func select(_ id: ResultID?) {
        guard id != selection else { return }
        autoSelect = nil
        guard let id else {
            selection = nil
            return
        }
        choose(id, landing: .top)
    }

    /// A link in the entry of `dictionary` named `query`: looked up in link mode in that dictionary (ADR-0007
    /// decision 7), as a new place in the trail.
    public func follow(_ query: String, anchor: String?, from dictionary: UUID) {
        navigate { model in
            await model.leaveCurrent()
            model.trail.push(Visit(query: query, mode: .link, scope: .one(dictionary), anchor: anchor, isOrigin: false))
            model.liveTask?.cancel()
            model.provisional = false
            model.chosenHeadword = nil
            model.text = query
            model.begin(query, .link, .one(dictionary), landing: anchor.map(Landing.anchor) ?? .top, select: nil)
        }
    }

    /// **The place being read, with how far down its entry the reader is** — what the lookup panel hands the main window
    /// when it expands (plan-macos-v1 WI-8, I5). Nil before anything is shown.
    public func currentPlace() async -> Visit? {
        await idle()
        guard trail.current?.result != nil else { return nil }
        await leaveCurrent()
        return trail.current
    }

    /// **A place handed over from another window** (I5): a new place in this window's trail, its query, scope, entry and
    /// scroll restored, as Back restores one — so Back from it reaches this window's own places.
    /// `started` hears the serial of the lookup this adoption begins, when it begins — not the serial current when it was
    /// queued. A navigation queued before the adoption begins its own lookup first, and only this callback tells the two
    /// apart (verification finding, 2026-10-20).
    public func adopt(_ visit: Visit, started: @escaping @MainActor (Int) -> Void = { _ in }) {
        navigate { model in
            await model.leaveCurrent()
            model.trail.push(visit)
            model.restore(visit, started: started)
        }
    }

    public var canGoBack: Bool { trail.canGoBack }
    public var canGoForward: Bool { trail.canGoForward }
    public var canReturnToOrigin: Bool { trail.canReturnToOrigin }

    public func back() {
        navigate { model in
            await model.leaveCurrent()
            if let visit = model.trail.back() { model.restore(visit) }
        }
    }

    public func forward() {
        navigate { model in
            await model.leaveCurrent()
            if let visit = model.trail.forward() { model.restore(visit) }
        }
    }

    /// To the word last typed at or before this place, in one step (I8).
    public func returnToOrigin() {
        navigate { model in
            await model.leaveCurrent()
            if let visit = model.trail.toOrigin() { model.restore(visit) }
        }
    }

    /// Returns once every step through the trail asked so far has been taken.
    public func idle() async {
        await navigation?.value
    }

    /// Returns once every lookup and page asked so far has answered (or been superseded).
    public func answersSettled() async {
        while let next = lookups.first {
            await next.value
            lookups.removeFirst()
        }
    }

    // MARK: - Inside

    private func inScope(_ scope: SearchScope) -> [SearchSource] {
        switch scope {
        case .all: known.filter(\.enabled)
        case .one(let id): known.filter { $0.id == id }
        }
    }

    private func navigate(_ step: @escaping @MainActor (SearchModel) async -> Void) {
        let previous = navigation
        navigation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await step(self)
        }
    }

    /// Keeps how far down the entry the reader is, on the place being left.
    private func leaveCurrent() async {
        guard let leaving = trail.current?.result, let reader = scrollReader, let offset = await reader() else { return }
        guard trail.current?.result == leaving else { return }
        trail.updateCurrent { $0.scroll = offset }
    }

    private func restore(_ visit: Visit, started: @escaping @MainActor (Int) -> Void = { _ in }) {
        liveTask?.cancel()
        provisional = false
        text = visit.typed ?? visit.query
        chosenHeadword = visit.typed == nil ? nil : visit.query
        if visit.mode == .reader { scope = visit.scope }
        if let typed = visit.typed, listing?.typed != typed { relist(typed) }
        let landing: Landing = visit.scroll > 0 ? .offset(visit.scroll) : visit.anchor.map(Landing.anchor) ?? .top
        begin(visit.query, visit.mode, visit.scope, landing: landing, select: visit.result, started: started)
    }

    /// A new lookup: every dictionary in scope asked again, the older lookup's calls superseded.
    private func begin(_ query: String, _ mode: MatchMode, _ scope: SearchScope, landing: Landing, select: ResultID?,
                       started: @MainActor (Int) -> Void = { _ in }) {
        serial += 1
        lookup = Lookup(query: query, mode: mode, scope: scope, serial: serial)
        started(serial)
        asked = [:]
        selection = select
        autoSelect = select == nil ? landing : nil
        if let select { show(select, landing: landing) }
        ask(superseding: true)
    }

    /// Asks every dictionary in the lookup's scope that answers and has not been asked, in the reader's order.
    private func ask(superseding: Bool) {
        guard let lookup else { return }
        let wanted = inScope(lookup.scope).compactMap { source -> (UUID, DictId)? in
            guard let handle = source.handle, asked[source.id] == nil else { return nil }
            return (source.id, handle)
        }
        guard !wanted.isEmpty || superseding else { return }
        for (id, handle) in wanted { asked[id] = .searching(handle) }
        let operations = wanted.map { _, handle in
            ServiceOperation.lookup(query: lookup.query, dicts: [handle], options: LookupOptions(
                limit: options.firstPage, offset: 0, mode: lookup.mode, generation: nil))
        }
        let (backend, caller, serial) = (backend, searchCaller, lookup.serial)
        lookups.append(Task { [weak self] in
            if operations.isEmpty {
                await backend.supersede(caller)
                return
            }
            let pending = await backend.queue(operations, as: caller, superseding: superseding)
            await withTaskGroup(of: Void.self) { group in
                for ((id, handle), call) in zip(wanted, pending) {
                    group.addTask {
                        let outcome = await call.outcome()
                        await self?.answered(id, handle: handle, serial: serial, outcome.page)
                    }
                }
            }
        })
    }

    private func answered(_ id: UUID, handle: DictId, serial: Int, _ outcome: Result<Page, ClientFailure>) {
        guard let lookup, lookup.serial == serial, asked[id] == .searching(handle) else { return }
        switch outcome {
        case .success(let page):
            asked[id] = .answered(handle, Results(hits: page.hits, total: page.total, generation: page.generation))
        case .failure(let failure):
            guard let why = LookupFailure(failure) else { return }
            asked[id] = .failed(handle, why)
        }
        onAnswered?(id, lookup)
        autoSelectIfDue()
        reconcile()
    }

    private func paged(_ id: UUID, handle: DictId, serial: Int, offset: Int, _ outcome: Result<Page, ClientFailure>) {
        guard lookup?.serial == serial, case .answered(handle, var results)? = asked[id], results.hits.count == offset
        else { return }
        results.loadingMore = false
        switch outcome {
        case .success(let page):
            results.hits += page.hits
            results.total = page.total
        case .failure(let failure):
            guard let why = LookupFailure(failure) else { return }
            results.moreFailed = why
        }
        asked[id] = .answered(handle, results)
    }

    /// Chooses the first result of the first dictionary, in order, that has one, once every dictionary before it has
    /// answered or cannot.
    private func autoSelectIfDue() {
        guard let landing = autoSelect, selection == nil else { return }
        for section in sections {
            switch section.status {
            case .searching:
                return
            case .results(let results):
                guard let first = results.hits.first else { continue }
                autoSelect = nil
                choose(ResultID(dictionary: section.id, entry: first.entry), landing: landing)
                return
            case .noMatch, .unavailable, .failed:
                continue
            }
        }
    }

    private func choose(_ id: ResultID, landing: Landing) {
        selection = id
        trail.updateCurrent {
            $0.result = id
            $0.scroll = 0
        }
        show(id, landing: landing)
    }

    private func show(_ id: ResultID, landing: Landing) {
        shownSerial += 1
        shown = Shown(result: id, landing: landing, serial: shownSerial, lookup: lookup?.serial)
    }
}
