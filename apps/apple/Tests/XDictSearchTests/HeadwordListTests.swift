import Foundation
import Testing
import XDictClient
import XDictContract
import XDictLibrary
import XDictSearch

/// **The sidebar as Apple's Dictionary has it** (parity ledger P9, P10, P13; owner's decisions of 2026-10-17): one flat
/// list of matching headwords across the dictionaries in scope, the first match shown while the reader types, Return
/// only confirming, and "Did you mean?" for a misspelling.
@MainActor
struct HeadwordListTests {
    /// The library's keys, by dictionary: what a lookup finds (exact) and what a prefix suggests.
    nonisolated static let keys: [String: [String]] = [
        "A": ["apple", "apple pie", "take off", "take on", "accommodate"],
        "B": ["Apple", "apple tree", "take off"],
    ]

    static func backend() -> FakeSearchBackend {
        let backend = FakeSearchBackend { query, dict, _ in
            let name = String(dict.rawValue.dropFirst("handle-".count))
            let found = (keys[name] ?? []).filter { $0.lowercased() == query.lowercased() }
            return .success(Fixture.page(found.map { Fixture.hit(name, $0) }))
        }
        return backend
    }

    static func model(_ backend: FakeSearchBackend, guesser: (any SpellingGuesser)? = nil) async -> SearchModel {
        await backend.setSuggest { prefix, dicts in
            var out: [String] = []
            for dict in dicts {
                let name = String(dict.rawValue.dropFirst("handle-".count))
                for key in keys[name] ?? [] where key.lowercased().hasPrefix(prefix.lowercased()) && !out.contains(key) {
                    out.append(key)
                }
            }
            return out
        }
        var options = SearchModel.Options()
        options.suggestionDelay = .milliseconds(20)
        let sources = Sources([Fixture.source(1, "A"), Fixture.source(2, "B")])
        return SearchModel(backend: backend, window: "test", options: options, guesser: guesser) { sources.list }
    }

    static func type(_ model: SearchModel, _ text: String) {
        model.text = text
        model.textDidChange()
    }

    /// **P9**: one row per distinct headword, the typed word's own matches first (in the reader's order), then the
    /// keys that begin with it; "N found" counts the rows.
    @Test func theListIsOneRowPerHeadwordAcrossDictionaries() async {
        let model = await Self.model(Self.backend())
        #expect(model.listing == nil, "no list before a search: the sidebar is hidden")
        model.submit("apple")
        #expect(await eventually { model.listing?.settled == true })
        #expect(model.listing?.headwords == ["apple", "Apple", "apple pie", "apple tree"])
        #expect(model.listing?.isGuess == false)
        #expect(model.found == 4)
        #expect(model.selectedHeadword == "apple")
    }

    /// **P10**: typing shows the first match's entry without Return; Return then confirms, asking nothing again.
    @Test func typingShowsTheFirstMatchAndReturnOnlyConfirms() async {
        let backend = Self.backend()
        let model = await Self.model(backend)
        Self.type(model, "app")
        Self.type(model, "apple")
        #expect(await eventually { model.shown?.result == Fixture.result(1, "A", "apple") })
        let before = await backend.lookups.filter { $0.caller == Caller("search.test") }.count
        #expect(before == 2, "one lookup per dictionary, for the latest text only")
        #expect(model.trail.visits.count == 1)
        model.submit()
        await model.idle()
        await model.answersSettled()
        let after = await backend.lookups.filter { $0.caller == Caller("search.test") }.count
        #expect(after == before, "Return asked again what typing had shown")
        #expect(model.trail.visits.count == 1)
        // Typing more after Return is a new place, not a change to the confirmed one.
        Self.type(model, "take off")
        #expect(await eventually { model.shown?.result.entry.key == "take off" })
        #expect(model.trail.visits.map(\.query) == ["apple", "take off"])
    }

    /// **P10**: a typed text that is no headword itself shows its first completion ("take o" shows "take off").
    @Test func aPrefixShowsItsFirstCompletion() async {
        let model = await Self.model(Self.backend())
        Self.type(model, "take o")
        #expect(await eventually { model.shown?.result.entry.key == "take off" })
        #expect(model.listing?.headwords == ["take off", "take on"])
        #expect(model.selectedHeadword == "take off")
        #expect(model.text == "take o", "the field keeps what the reader typed")
    }

    /// **P9, P11**: choosing a row shows that headword, keeps the list, and is a place Back returns from.
    @Test func choosingARowShowsItAndKeepsTheList() async {
        let model = await Self.model(Self.backend())
        model.submit("apple")
        #expect(await eventually { model.listing?.settled == true && model.shown != nil })
        model.choose(headword: "apple tree")
        #expect(await eventually { model.shown?.result == Fixture.result(2, "B", "apple tree") })
        #expect(model.selectedHeadword == "apple tree")
        #expect(model.listing?.headwords == ["apple", "Apple", "apple pie", "apple tree"])
        #expect(model.text == "apple")
        model.back()
        await model.idle()
        #expect(await eventually { model.shown?.result == Fixture.result(1, "A", "apple") })
        #expect(model.selectedHeadword == "apple")
    }

    /// **P13**: nothing under the text and nothing beginning with it: the spelling guesses the library has, under "Did
    /// you mean?", the first one shown; a guess the library lacks is not offered.
    @Test func aMisspellingOffersTheGuessesTheLibraryHas() async {
        let model = await Self.model(Self.backend(), guesser: FixedGuesser(["accommodate", "accumulate"]))
        model.submit("accomodate")
        #expect(await eventually { model.listing?.settled == true })
        #expect(model.listing?.headwords == ["accommodate"])
        #expect(model.listing?.isGuess == true)
        #expect(model.found == nil, "a guess is not a find: the title has no count")
        #expect(await eventually { model.shown?.result == Fixture.result(1, "A", "accommodate") })
    }

    /// **P12**: no match, no completion, no guess: an empty list, nothing shown, no count.
    @Test func nothingFoundIsAnEmptySettledList() async {
        let model = await Self.model(Self.backend(), guesser: FixedGuesser(["zzz"]))
        model.submit("qqqq")
        #expect(await eventually { model.listing?.settled == true })
        #expect(model.listing?.headwords == [])
        #expect(model.found == nil)
        #expect(model.shown == nil)
    }

    /// **P7**: ⌘} and ⌘{ step the scope through All and each enabled dictionary, wrapping.
    @Test func theScopeStepsThroughAllAndEachDictionary() async {
        let model = await Self.model(Self.backend())
        model.stepScope(forward: true)
        #expect(model.scope == .one(Fixture.id(1)))
        model.stepScope(forward: true)
        #expect(model.scope == .one(Fixture.id(2)))
        model.stepScope(forward: true)
        #expect(model.scope == .all)
        model.stepScope(forward: false)
        #expect(model.scope == .one(Fixture.id(2)))
    }
}

/// Spelling guesses the test names.
struct FixedGuesser: SpellingGuesser {
    let words: [String]

    init(_ words: [String]) {
        self.words = words
    }

    func guesses(for word: String) -> [String] { words }
}
