import Foundation
import Testing
import XDictClient
import XDictContract
import XDictLibrary
import XDictSearch

/// **The main window's search** (plan-macos-v1 WI-6) against a fake of the service: who is asked and in what order, what
/// paints when, which answers are refused as stale, scope and order, paging to every record, and the dictionaries that
/// cannot answer, each with its next action.
@MainActor
struct SearchModelTests {
    /// Every dictionary answers its own key `apple`, and nothing else.
    static func apples() -> FakeSearchBackend {
        FakeSearchBackend { query, dict, _ in
            let name = String(dict.rawValue.dropFirst("handle-".count))
            return .success(Fixture.page(query == "apple" ? [Fixture.hit(name, "apple")] : []))
        }
    }

    static func model(_ backend: FakeSearchBackend, _ sources: Sources,
                      options: SearchModel.Options = SearchModel.Options()) -> SearchModel {
        SearchModel(backend: backend, window: "test", options: options) { sources.list }
    }

    static func names(_ model: SearchModel) -> [String] { model.sections.map(\.name) }

    // MARK: - Who is asked (Q2, Q12)

    @Test func eachEnabledDictionaryIsAskedOnItsOwnInTheReadersOrder() async {
        let backend = Self.apples()
        let sources = Sources([Fixture.source(1, "A"), Fixture.source(2, "B"), Fixture.source(3, "C", enabled: false)])
        let model = Self.model(backend, sources)
        model.text = "apple"
        model.submit()
        await model.idle()
        await model.answersSettled()
        let asked = await backend.lookups
        #expect(asked.map(\.dicts) == [[Fixture.handle("A")], [Fixture.handle("B")]])
        #expect(asked.map(\.superseding) == [true, false], "the first of a lookup's calls supersedes the last lookup's")
        #expect(asked.allSatisfy { $0.options.mode == .reader && $0.options.offset == 0 && $0.options.generation == nil })
        #expect(Self.names(model) == ["A", "B"])
        #expect(model.sections.allSatisfy { if case .results = $0.status { true } else { false } })
    }

    /// **Q12: a slow dictionary holds up no other.** A, first in the reader's order, is held; B's results are there
    /// while A is still searching, and A's arrive when it answers.
    @Test func aSlowDictionaryHoldsUpNoOther() async {
        let backend = Self.apples()
        await backend.hold(Fixture.handle("A"))
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]))
        model.submit("apple")
        let painted = await eventually {
            if case .results = model.sections.last?.status { true } else { false }
        }
        #expect(painted, "B's results never painted while A was held: \(model.sections)")
        #expect(model.sections.first?.status == .searching)
        #expect(model.isSearching)
        await backend.release(Fixture.handle("A"))
        #expect(await eventually { if case .results = model.sections.first?.status { true } else { false } })
        #expect(!model.isSearching)
    }

    /// **Q12: an older lookup never replaces a newer one**, even when its answer arrives after the newer one's (the
    /// fake delivers it late, as a service that did not drop it would).
    @Test func anOlderLookupsLateAnswerIsNeverShown() async {
        let backend = FakeSearchBackend { query, dict, _ in
            .success(Fixture.page([Fixture.hit(String(dict.rawValue.dropFirst("handle-".count)), query)]))
        }
        await backend.setHonoursSupersession(false)
        await backend.hold(Fixture.handle("A"))
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        model.submit("old")
        await model.idle()
        #expect(await eventually { model.lookup?.query == "old" && model.isSearching })
        await backend.release(Fixture.handle("A"))
        await backend.hold(Fixture.handle("A"))
        model.submit("new")
        await model.idle()
        await backend.release(Fixture.handle("A"))
        await model.answersSettled()
        guard case .results(let results)? = model.sections.first?.status else {
            Issue.record("no results: \(model.sections)")
            return
        }
        #expect(results.hits.map(\.headword) == ["new"])
    }

    /// The core's order is kept: exact before folded before unmarked (ADR-0007 decision 9). The model never reorders.
    @Test func hitsKeepTheCoresOrder() async {
        let backend = FakeSearchBackend { _, _, _ in
            .success(Fixture.page([Fixture.hit("A", "abbe", how: .exact), Fixture.hit("A", "Abbe", how: .folded),
                                   Fixture.hit("A", "abbé", how: .unmarked)]))
        }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        model.submit("abbe")
        await model.idle()
        await model.answersSettled()
        guard case .results(let results)? = model.sections.first?.status else {
            Issue.record("no results: \(model.sections)")
            return
        }
        #expect(results.hits.map(\.how) == [.exact, .folded, .unmarked])
        #expect(results.hits.map(\.headword) == ["abbe", "Abbe", "abbé"])
    }

    // MARK: - Scope and order (Q1)

    @Test func reorderingTheLibraryReordersTheSectionsWithoutAskingAgain() async {
        let backend = Self.apples()
        let sources = Sources([Fixture.source(1, "A"), Fixture.source(2, "B")])
        let model = Self.model(backend, sources)
        model.submit("apple")
        await model.idle()
        await model.answersSettled()
        #expect(Self.names(model) == ["A", "B"])
        sources.list.reverse()
        model.sourcesDidChange()
        #expect(Self.names(model) == ["B", "A"])
        await model.answersSettled()
        #expect(await backend.lookups.count == 2)
    }

    @Test func switchingScopeChangesTheResultsAndAsksOnlyWhatIsNew() async {
        let backend = Self.apples()
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]))
        model.setScope(.one(Fixture.id(1)))
        model.submit("apple")
        await model.idle()
        await model.answersSettled()
        #expect(Self.names(model) == ["A"])
        #expect(await backend.lookups.map(\.dicts) == [[Fixture.handle("A")]])
        model.setScope(.all)
        await model.answersSettled()
        #expect(Self.names(model) == ["A", "B"])
        #expect(await backend.lookups.map(\.dicts) == [[Fixture.handle("A")], [Fixture.handle("B")]])
        model.setScope(.one(Fixture.id(2)))
        await model.answersSettled()
        #expect(Self.names(model) == ["B"])
        #expect(await backend.lookups.count == 2)
        #expect(model.trail.current?.scope == .one(Fixture.id(2)), "the place keeps the scope it is read in")
    }

    @Test func aScopeOfADictionaryNoLongerUsedFallsBackToEveryDictionary() async {
        let sources = Sources([Fixture.source(1, "A"), Fixture.source(2, "B")])
        let model = Self.model(Self.apples(), sources)
        model.setScope(.one(Fixture.id(2)))
        #expect(model.scope == .one(Fixture.id(2)))
        sources.list[1] = Fixture.source(2, "B", enabled: false)
        model.sourcesDidChange()
        #expect(model.scope == .all)
    }

    // MARK: - Every record (Q10)

    /// 2,345 records under one key: the first page, then pages continuing its generation, to every record once.
    @Test func pagingReachesEveryRecordOnceUnderTheFirstGeneration() async {
        let records: UInt32 = 2_345
        let backend = FakeSearchBackend { _, _, options in
            guard options.generation == nil || options.generation == 7 else {
                return .failure(.wire(.core(.staleHandle(detail: "another generation"))))
            }
            let range = options.offset..<min(records, options.offset + options.limit)
            return .success(Page(hits: range.map { Fixture.hit("A", "EC", $0) }, total: UInt64(records), generation: 7,
                                 problems: []))
        }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        model.submit("EC")
        await model.idle()
        await model.answersSettled()
        var rounds = 0
        while case .results(let results)? = model.sections.first?.status, results.hasMore, rounds < 10 {
            model.loadMore(Fixture.id(1))
            await model.answersSettled()
            rounds += 1
        }
        guard case .results(let results)? = model.sections.first?.status else {
            Issue.record("no results: \(model.sections)")
            return
        }
        #expect(results.total == UInt64(records))
        #expect(results.hits.map(\.entry.occurrence) == Array(0..<records))
        #expect(!results.hasMore && results.moreFailed == nil)
        let asked = await backend.lookups
        #expect(asked.map(\.options.offset) == [0, 100, 1_100, 2_100])
        #expect(asked.dropFirst().allSatisfy { $0.options.generation == 7 && $0.options.limit == 1_000 && !$0.superseding })
        #expect(results.repeatedKeys == ["EC"])
    }

    // MARK: - No answer, told apart (Q11)

    @Test func eachUnavailableStateIsItsOwnWithItsNextAction() async {
        let backend = FakeSearchBackend { _, dict, _ in
            switch dict.rawValue {
            case "handle-down": .failure(.wire(.interrupted))
            case "handle-broken": .failure(.wire(.core(.malformed(detail: "a bad block"))))
            default: .success(Fixture.page([]))
            }
        }
        let model = Self.model(backend, Sources([
            Fixture.source(1, "none"),
            Fixture.source(2, "indexing", state: .indexing(fraction: 0.4)),
            Fixture.source(3, "missing", state: .missing(fileName: "gone.mdx")),
            Fixture.source(4, "damaged", state: .refused(.damaged)),
            Fixture.source(5, "locked", state: .refused(.registrationCode)),
            Fixture.source(6, "stopped", state: .notImported(.cancelled)),
            Fixture.source(7, "down"),
            Fixture.source(8, "broken"),
            Fixture.source(9, "moved", state: .outsideItsFolder(fileName: "link.mdd")),
        ]))
        model.submit("xyzzy")
        await model.idle()
        await model.answersSettled()
        let statuses = model.sections.map(\.status)
        #expect(statuses == [
            .noMatch(query: "xyzzy", mode: .reader),
            .unavailable(.indexing(fraction: 0.4)),
            .unavailable(.missingFile("gone.mdx")),
            .unavailable(.malformed),
            .unavailable(.unsupported(.registrationCode)),
            .unavailable(.notImported(.cancelled)),
            .failed(.serviceFailed),
            .failed(.malformed),
            .unavailable(.outsideItsFolder("link.mdd")),
        ])
        #expect(model.sections.map(\.next) == [
            .checkSpelling, .wait, .openLibrary(Fixture.id(3)), .openLibrary(Fixture.id(4)), .openLibrary(Fixture.id(5)),
            .retryImport(Fixture.id(6)), .retryLookup(Fixture.id(7)), .openLibrary(Fixture.id(8)),
            .openLibrary(Fixture.id(9)),
        ])
        #expect(Set(statuses).count == statuses.count, "two states read alike")
    }

    @Test func anIndexingDictionaryIsAskedOnceItCanAnswer() async {
        let backend = Self.apples()
        let sources = Sources([Fixture.source(1, "A", state: .indexing(fraction: nil))])
        let model = Self.model(backend, sources)
        model.submit("apple")
        await model.idle()
        await model.answersSettled()
        #expect(model.sections.first?.status == .unavailable(.indexing(fraction: nil)))
        #expect(await backend.lookups.isEmpty)
        sources.list = [Fixture.source(1, "A")]
        model.sourcesDidChange()
        await model.answersSettled()
        #expect(await backend.lookups.map(\.dicts) == [[Fixture.handle("A")]])
        #expect(model.selection == Fixture.result(1, "A", "apple"), "its first result is shown, nothing else being due")
    }

    @Test func aDictionaryReopenedUnderAnotherHandleIsAskedAgain() async {
        let backend = Self.apples()
        let sources = Sources([Fixture.source(1, "A")])
        let model = Self.model(backend, sources)
        model.submit("apple")
        await model.idle()
        await model.answersSettled()
        sources.list = [SearchSource(id: Fixture.id(1), name: "A", edition: Fixture.edition("A"), preferencesKey: "l",
                                     enabled: true, state: .ready(DictId(rawValue: "handle-A2")))]
        model.sourcesDidChange()
        await model.answersSettled()
        #expect(await backend.lookups.map(\.dicts) == [[Fixture.handle("A")], [DictId(rawValue: "handle-A2")]])
    }

    @Test func retryAsksAFailedDictionaryAgain() async {
        let backend = FakeSearchBackend { _, _, _ in .failure(.wire(.timedOut(deadline: .seconds(5)))) }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        model.submit("apple")
        await model.idle()
        await model.answersSettled()
        #expect(model.sections.first?.status == .failed(.serviceFailed))
        model.retry(Fixture.id(1))
        await model.answersSettled()
        #expect(await backend.lookups.count == 2)
    }

    // MARK: - The entry shown

    /// The first result of the first dictionary in order that has one, once every dictionary before it has answered: a
    /// quicker later dictionary never takes the place.
    @Test func theFirstResultInTheReadersOrderIsShownOnceEveryEarlierOneHasAnswered() async {
        let backend = Self.apples()
        await backend.hold(Fixture.handle("A"))
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]))
        model.submit("apple")
        #expect(await eventually { if case .results = model.sections.last?.status { true } else { false } })
        #expect(model.selection == nil, "B answered first, but A comes first")
        await backend.release(Fixture.handle("A"))
        #expect(await eventually { model.selection != nil })
        #expect(model.selection == Fixture.result(1, "A", "apple"))
        #expect(model.shown?.result == Fixture.result(1, "A", "apple"))
        #expect(model.shown?.landing == .top)
    }

    @Test func aDictionaryWithNothingBeforeTheOneWithResultsIsPassedOver() async {
        let backend = Self.apples()
        let model = Self.model(backend, Sources([Fixture.source(1, "A", state: .refused(.damaged)), Fixture.source(2, "B")]))
        model.submit("apple")
        #expect(await eventually { model.selection != nil })
        #expect(model.selection == Fixture.result(2, "B", "apple"))
    }

    @Test func theReadersChoiceIsNeverReplacedByAnAutomaticOne() async {
        let backend = Self.apples()
        await backend.hold(Fixture.handle("A"))
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]))
        model.submit("apple")
        #expect(await eventually { if case .results = model.sections.last?.status { true } else { false } })
        model.select(Fixture.result(2, "B", "apple"))
        await backend.release(Fixture.handle("A"))
        await model.answersSettled()
        #expect(model.selection == Fixture.result(2, "B", "apple"))
        #expect(model.trail.visits.count == 1, "choosing among one lookup's results replaces the place")
        #expect(model.trail.current?.result == Fixture.result(2, "B", "apple"))
    }

    // MARK: - Suggestions (Q6, Q7)

    @Test func suggestionsAreAskedOnceTypingPausesAndOnlyForTheLatestText() async {
        let backend = Self.apples()
        await backend.setSuggest { prefix, _ in prefix == "take o" ? ["take off", "take on"] : ["stale"] }
        var options = SearchModel.Options()
        options.suggestionDelay = .milliseconds(30)
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]), options: options)
        model.text = "take"
        model.textDidChange()
        model.text = "take o"
        model.textDidChange()
        #expect(await eventually { model.showsSuggestions })
        #expect(model.suggestions == ["take off", "take on"])
        let asked = await backend.suggestions
        #expect(asked.map(\.prefix) == ["take o"], "the first text's suggestions were asked: \(asked)")
        #expect(asked.first?.dicts == [Fixture.handle("A"), Fixture.handle("B")])
        model.submit()
        #expect(!model.showsSuggestions && model.suggestions.isEmpty)
    }

    // MARK: - Links and the trail (I7, I8)

    @Test func aLinkIsLookedUpInLinkModeInItsOwnDictionary() async {
        let backend = Self.apples()
        let model = Self.model(backend, Sources([Fixture.source(1, "A"), Fixture.source(2, "B")]))
        model.submit("apple")
        await model.idle()
        model.follow("abbe", anchor: "sense2", from: Fixture.id(2))
        await model.idle()
        await model.answersSettled()
        let last = await backend.lookups.last
        #expect(last?.dicts == [Fixture.handle("B")])
        #expect(last?.options.mode == .link)
        #expect(model.trail.visits.count == 2)
        #expect(model.trail.current?.isOrigin == false)
        #expect(model.text == "abbe")
        #expect(model.sections.map(\.status) == [.noMatch(query: "abbe", mode: .link)])
        #expect(model.sections.first?.next == .searchEverywhere("abbe"))
    }

    @Test func aLinksAnchorIsWhereItsEntryLands() async {
        let backend = FakeSearchBackend { query, _, _ in .success(Fixture.page([Fixture.hit("A", query)])) }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        model.submit("run")
        await model.idle()
        model.follow("walk", anchor: "sense2", from: Fixture.id(1))
        await model.idle()
        #expect(await eventually { model.shown?.result == Fixture.result(1, "A", "walk") })
        #expect(model.shown?.landing == .anchor("sense2"))
    }

    /// **A 5-hop trail returns exactly with Back, and to the origin in one step** (I8): each place comes back with the
    /// entry and the scroll it was left at.
    @Test func aFiveHopTrailReturnsExactlyWithBackAndToTheOriginInOneStep() async {
        let backend = FakeSearchBackend { query, _, _ in .success(Fixture.page([Fixture.hit("A", query)])) }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        // The entry pane's scroll: each hop's entry was left 100 × (n + 1) pixels down.
        model.scrollReader = { [weak model] in
            guard let key = model?.shown?.result.entry.key, let n = Int(key.dropFirst(3)) else { return nil }
            return Double(100 * (n + 1))
        }
        model.submit("hop0")
        await model.idle()
        #expect(await eventually { model.shown?.result.entry.key == "hop0" })
        for hop in 1...5 {
            model.follow("hop\(hop)", anchor: nil, from: Fixture.id(1))
            await model.idle()
            #expect(await eventually { model.shown?.result.entry.key == "hop\(hop)" })
        }
        #expect(model.trail.visits.count == 6)
        #expect(model.canReturnToOrigin)
        for hop in (0...4).reversed() {
            model.back()
            await model.idle()
            #expect(model.shown?.result == Fixture.result(1, "A", "hop\(hop)"))
            #expect(model.shown?.landing == .offset(Double(100 * (hop + 1))), "hop\(hop) came back elsewhere")
            #expect(model.selection == Fixture.result(1, "A", "hop\(hop)"))
            #expect(model.text == "hop\(hop)")
        }
        #expect(!model.canGoBack)
        for _ in 1...5 {
            model.forward()
            await model.idle()
        }
        #expect(model.shown?.result.entry.key == "hop5")
        model.returnToOrigin()
        await model.idle()
        #expect(model.shown?.result == Fixture.result(1, "A", "hop0"))
        #expect(model.shown?.landing == .offset(100))
        #expect(model.lookup?.mode == .reader)
        #expect(model.canGoForward, "the places after the origin stay ahead")
    }

    @Test func aNewWordDropsThePlacesAhead() async {
        let backend = FakeSearchBackend { query, _, _ in .success(Fixture.page([Fixture.hit("A", query)])) }
        let model = Self.model(backend, Sources([Fixture.source(1, "A")]))
        for word in ["one", "two", "three"] {
            model.submit(word)
            await model.idle()
        }
        model.back()
        model.back()
        model.submit("four")
        await model.idle()
        #expect(model.trail.visits.map(\.query) == ["one", "four"])
        #expect(!model.canGoForward)
    }
}
