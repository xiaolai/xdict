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
@MainActor
@Observable
public final class SearchModel {
    public struct Options: Sendable {
        /// Hits in a dictionary's first page: a screenful and more, answered quickly.
        public var firstPage: UInt32 = 100
        /// Hits in each further page: the core's whole page (`MAX_PAGE`).
        public var furtherPage: UInt32 = 1_000
        public var suggestionLimit: UInt32 = 20
        /// How long typing must pause before suggestions are asked for.
        public var suggestionDelay: Duration = .milliseconds(120)

        public init() {}
    }

    /// The lookup the sections answer.
    public struct Lookup: Hashable, Sendable {
        public let query: String
        public let mode: MatchMode
        public let scope: SearchScope
        let serial: Int
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
    public private(set) var suggestions: [String] = []
    /// The reader is typing: the sidebar offers suggestions rather than results.
    public private(set) var suggesting = false
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
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var shownSerial = 0
    @ObservationIgnored private var suggestionSerial = 0
    /// The landing of a result the model will choose itself, once due; nil when the reader has chosen, or nothing is due.
    @ObservationIgnored private var autoSelect: Landing?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var navigation: Task<Void, Never>?
    @ObservationIgnored private var lookups: [Task<Void, Never>] = []

    /// `window` names this window's callers, so two windows never supersede each other's lookups.
    public init(backend: any SearchBackend, window: String, options: Options = Options(),
                sources: @escaping @MainActor () -> [SearchSource]) {
        self.backend = backend
        self.sources = sources
        self.options = options
        searchCaller = Caller("search.\(window)")
        suggestCaller = Caller("suggest.\(window)")
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

    /// The suggestions are what the sidebar shows.
    public var showsSuggestions: Bool { suggesting && !suggestions.isEmpty }

    public func source(_ id: UUID) -> SearchSource? {
        known.first { $0.id == id }
    }

    /// The hit a result names, among those loaded.
    public func hit(_ id: ResultID) -> Hit? {
        guard case .answered(_, let results)? = asked[id.dictionary] else { return nil }
        return results.hits.first { $0.entry == id.entry }
    }

    // MARK: - Typing and searching

    /// The reader typed: suggestions for what the field holds, asked once typing pauses, over the dictionaries the
    /// scope asks (Q6, Q7: the core suggests public keys only).
    public func textDidChange() {
        suggestionTask?.cancel()
        suggestionSerial += 1
        let prefix = text
        let dicts = inScope(scope).compactMap(\.handle)
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !dicts.isEmpty else {
            suggesting = false
            suggestions = []
            return
        }
        suggesting = true
        let mine = suggestionSerial
        let (backend, caller, limit, delay) = (backend, suggestCaller, options.suggestionLimit, options.suggestionDelay)
        suggestionTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            let pending = await backend.queue([.suggest(prefix: prefix, dicts: dicts, limit: limit)], as: caller,
                                              superseding: true)
            guard let outcome = await pending.first?.outcome() else { return }
            guard let self, self.suggestionSerial == mine, case .success(let keys) = outcome.suggestions else { return }
            self.suggestions = keys
        }
    }

    /// Stops offering suggestions (Escape, or a search made).
    public func dismissSuggestions() {
        suggestionTask?.cancel()
        suggestionSerial += 1
        suggesting = false
        suggestions = []
    }

    /// Looks up `query` (the field's text when nil) as typed, in the reader's scope: a new place in the trail.
    public func submit(_ query: String? = nil) {
        let word = (query ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        dismissSuggestions()
        guard !word.isEmpty else { return }
        text = word
        let scope = scope
        navigate { model in
            await model.leaveCurrent()
            model.trail.push(Visit(query: word, mode: .reader, scope: scope, isOrigin: true))
            model.begin(word, .reader, scope, landing: .top, select: nil)
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
    }

    /// The library changed: an order, a name, a dictionary enabled, ready, gone or reopened under another handle.
    public func sourcesDidChange() {
        let now = sources()
        guard now != known else { return }
        known = now
        if case .one(let id) = scope, !now.contains(where: { $0.id == id && $0.enabled }) { scope = .all }
        for (id, answer) in asked where now.first(where: { $0.id == id })?.handle != answer.handle {
            asked[id] = nil
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
            model.dismissSuggestions()
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
    public func adopt(_ visit: Visit) {
        navigate { model in
            await model.leaveCurrent()
            model.trail.push(visit)
            model.restore(visit)
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

    private func restore(_ visit: Visit) {
        dismissSuggestions()
        text = visit.query
        if visit.mode == .reader { scope = visit.scope }
        let landing: Landing = visit.scroll > 0 ? .offset(visit.scroll) : visit.anchor.map(Landing.anchor) ?? .top
        begin(visit.query, visit.mode, visit.scope, landing: landing, select: visit.result)
    }

    /// A new lookup: every dictionary in scope asked again, the older lookup's calls superseded.
    private func begin(_ query: String, _ mode: MatchMode, _ scope: SearchScope, landing: Landing, select: ResultID?) {
        serial += 1
        lookup = Lookup(query: query, mode: mode, scope: scope, serial: serial)
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
        shown = Shown(result: id, landing: landing, serial: shownSerial)
    }
}
