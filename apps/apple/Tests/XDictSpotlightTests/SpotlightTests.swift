import CoreSpotlight
import Foundation
import Testing
import XDictSpotlight
import XDictTestSupport

/// **What actually reaches Core Spotlight, and what comes back out** (plan-setup-v2 WI-6; ADR-0028, headwords only): the
/// item's fields, the identifier's round trip, the batches, the domains, and the switch. Core Spotlight itself is behind
/// `SpotlightIndexing`, so every check here drives a fake.
struct SpotlightItemTests {
    @Test func anItemsWordComesBackFromItsIdentifierWhateverItHolds() {
        for word in ["colour", "a/b", "state: of the art", "½", "thai–english", "/"] {
            let item = SpotlightItem(word: word, domain: "0E1B2C3D-0000-0000-0000-000000000000")
            #expect(SpotlightItem.word(of: item.identifier) == word, "\(word)")
        }
        #expect(SpotlightItem.word(of: "no slash here") == nil)
        #expect(SpotlightItem.word(of: "domain/") == nil, "an empty word is no word")
    }

    /// **The identifier gives the dictionary back too** (audit-fix 2026-10-22 finding 15): a result opened while the
    /// window is scoped elsewhere selects the dictionary it came from, so the domain must come back with the word.
    @Test func anItemsDomainComesBackWithItsWord() {
        let domain = "0E1B2C3D-0000-0000-0000-000000000000"
        for word in ["colour", "a/b", "/", "½"] {
            let item = SpotlightItem.item(of: SpotlightItem(word: word, domain: domain).identifier)
            #expect(item == SpotlightItem(word: word, domain: domain), "\(word)")
        }
        #expect(SpotlightItem.item(of: "no slash here") == nil)
        #expect(SpotlightItem.item(of: "/word") == nil, "an empty domain is no item")
        #expect(SpotlightItem.item(of: "domain/") == nil, "an empty word is no item")
    }

    /// **A word, and nothing about the entry**: the title and the keyword carry it, the domain groups it, and no text
    /// is written (ADR-0028 decision 2 as revised: headwords only).
    @Test func anItemHoldsTheWordAndNoEntry() {
        let item = SpotlightItems.item(SpotlightItem(word: "colour", domain: "abc"))
        #expect(item.uniqueIdentifier == "abc/colour")
        #expect(item.domainIdentifier == "abc")
        let attributes = item.attributeSet
        #expect(attributes.title == "colour")
        #expect(attributes.keywords == ["colour"])
        #expect(attributes.contentDescription == nil, "no definition travels")
        #expect(attributes.textContent == nil, "no entry text travels")
        #expect(attributes.contentType == "public.text", "`.text`, which macOS reliably shows")
    }
}

/// **The index behind a fake**: what is stored, in which batches, under which domain, and what a cancellation and a
/// refusal leave behind.
struct SpotlightIndexerTests {
    /// An index that remembers what it was given, and can be made to refuse. An actor: the indexer awaits it from a
    /// task of its own, and a lock taken across an `await` is what Swift 6 refuses.
    actor FakeIndex: SpotlightIndexing {
        private(set) var batches: [[String]] = []
        private(set) var domains: [[String]] = []
        var refuses = false

        func index(_ items: [SpotlightItem]) async throws {
            if refuses { throw NSError(domain: "fake", code: 1) }
            batches.append(items.map(\.identifier))
        }

        func delete(domains: [String]) async throws {
            if refuses { throw NSError(domain: "fake", code: 2) }
            self.domains.append(domains)
        }

        func deleteAll() async throws {
            if refuses { throw NSError(domain: "fake", code: 3) }
            domains.append(["*"])
        }

        func refuse() { refuses = true }
    }

    /// A source of one page: `count` words, then nil.
    static func onePage(_ count: Int) -> @Sendable (UInt64) async throws -> SpotlightIndexer.Page? {
        { from in
            guard from == 0 else { return nil }
            return SpotlightIndexer.Page(words: (0..<count).map { "w\($0)" }, next: UInt64(count))
        }
    }

    /// **A word goes in once, in batches of 200**, and the pages are asked for until the dictionary ends.
    @Test func wordsAreStoredInBatchesOfTwoHundred() async throws {
        let index = FakeIndex()
        let indexer = SpotlightIndexer(index: index)
        let run = try await indexer.index(domain: "abc", next: Self.onePage(450))
        #expect(run.stored == 450)
        let batches = await index.batches
        #expect(batches.map(\.count) == [200, 200, 50])
        #expect(batches.flatMap { $0 }.allSatisfy { $0.hasPrefix("abc/") }, "every item names its domain")
        #expect(Set(batches.flatMap { $0 }).count == 450, "no word twice")
    }

    /// An empty dictionary stores nothing and still ends; an empty word is not an item.
    @Test func nothingIsStoredForAnEmptyDictionary() async throws {
        let index = FakeIndex()
        let run = try await SpotlightIndexer(index: index).index(domain: "abc", next: { _ in nil })
        let empty = await index.batches.isEmpty
        #expect(run.stored == 0 && empty)
        // A punctuation-only word is a public key no reader lookup can reach: it is not an item (audit-fix 2026-10-22).
        let spaced = try await SpotlightIndexer(index: index).index(domain: "abc", next: { from in
            from == 0 ? SpotlightIndexer.Page(words: ["one", "", ",", "two"], next: 4) : nil
        })
        #expect(spaced.stored == 2)
    }

    /// **A cancelled run stops**: the index is not handed another batch once the task is cancelled.
    @Test func aCancelledRunStopsAtTheNextBatch() async throws {
        let index = FakeIndex()
        let indexer = SpotlightIndexer(index: index)
        let task = Task {
            try await indexer.index(domain: "abc", next: { from in
                if from == 0 { return SpotlightIndexer.Page(words: (0..<200).map { "w\($0)" }, next: 200) }
                withUnsafeCurrentTask { $0?.cancel() }
                return SpotlightIndexer.Page(words: (0..<200).map { "x\($0)" }, next: 400)
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let batches = await index.batches
        #expect(batches.count == 1, "the second page never reached the index")
    }

    /// **A refusal is thrown, not swallowed**: the caller learns the index did not take the words.
    @Test func aRefusalIsReported() async throws {
        let index = FakeIndex()
        await index.refuse()
        await #expect(throws: (any Error).self) {
            _ = try await SpotlightIndexer(index: index).index(domain: "abc", next: Self.onePage(5))
        }
        await #expect(throws: (any Error).self) {
            try await SpotlightIndexer(index: index).delete(domains: ["abc"])
        }
    }

    /// **Turning the switch off deletes every XDict domain**, one call, and deleting nothing calls nothing.
    @Test func deletingTakesEveryDomainAtOnce() async throws {
        let index = FakeIndex()
        let indexer = SpotlightIndexer(index: index)
        try await indexer.delete(domains: ["a", "b"])
        let first = await index.domains
        #expect(first == [["a", "b"]])
        try await indexer.delete(domains: [])
        let both = await index.domains
        #expect(both == [["a", "b"]], "nothing to delete, nothing asked")
    }
}

/// **A call whose answer never comes is a failure** (2026-10-27): Core Spotlight performed this app's deletion on
/// 2026-10-27 and never called it back, so the app owed the same deletion at every launch and sent it again. These
/// hold the bound that turns that silence into a thrown error.
struct SpotlightDeadlineTests {
    @Test func anAnswerComesBack() async throws {
        try await SpotlightDeadline.bounded(.seconds(5)) { done in done(nil) }
    }

    @Test func aRefusalComesBackAsItself() async {
        await #expect(throws: (any Error).self) {
            try await SpotlightDeadline.bounded(.seconds(5)) { done in
                done(NSError(domain: "corespotlight", code: 1))
            }
        }
    }

    @Test func aMissedAnswerIsThrown() async throws {
        let clock = ContinuousClock()
        let began = clock.now
        await #expect(throws: SpotlightNoAnswer.self) {
            try await SpotlightDeadline.bounded(.milliseconds(40)) { _ in /* the index never calls back */ }
        }
        // The deadline decides, not luck: the await ends near it rather than at the generous default.
        #expect(began.duration(to: clock.now) < .seconds(2), "the bounded wait ended at its deadline")
    }

    /// An answer that arrives after the deadline is **dropped**, not resumed into a continuation already resumed —
    /// which traps. Reaching the end of this test without a crash is the assertion.
    @Test func aLateAnswerIsDropped() async throws {
        await #expect(throws: SpotlightNoAnswer.self) {
            try await SpotlightDeadline.bounded(.milliseconds(30)) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done(nil) }
            }
        }
        try await Task.sleep(for: .milliseconds(250))
    }
}

@MainActor
struct SpotlightSettingsTests {
    /// **The suite this test writes to**, held until the test's own instance goes (audit findings, 2026-10-25: a
    /// generated suite name that the system refused fell back to the reader's own defaults).
    let held = HeldDefaults()

    func suite() throws -> UserDefaults {
        let fixture = try TestDefaults(prefix: "ai.xdict.tests.spotlight")
        held.fixture = fixture
        return fixture.database
    }

    /// **Off until the reader says otherwise**, kept across launches, and every change says what the index must do.
    @Test func theSwitchIsOffUntilTheReaderTurnsItOn() throws {
        let defaults = try suite()
        let settings = SpotlightSettings(defaults: defaults)
        #expect(!settings.enabled, "opt-in, never opt-out")
        #expect(settings.setEnabled(true) == .include)
        #expect(settings.enabled)
        #expect(SpotlightSettings(defaults: defaults).enabled, "kept")
        #expect(settings.setEnabled(true) == .none, "the same answer twice asks for nothing")
        #expect(settings.setEnabled(false) == .exclude)
        #expect(!SpotlightSettings(defaults: defaults).enabled)
    }

    /// **A failed run is remembered as what it was** (audit-fix 2026-10-22 finding 7): the switch keeps saying what the
    /// reader chose, the row can read the failure, and a deletion that failed is owed again at the next launch.
    @Test func aFailedRunIsRememberedAndItsDeletionOwed() throws {
        let settings = SpotlightSettings(defaults: try suite())
        #expect(settings.lastRunFailed == nil, "no run yet")
        settings.setEnabled(true)
        settings.record(failed: false)
        #expect(settings.lastRunFailed == false && !settings.cleanupPending)
        settings.record(failed: true)
        #expect(settings.lastRunFailed == true && settings.enabled, "a failed run does not undo the reader's choice")
        #expect(!settings.needsCleanup(), "an inclusion that failed owes no deletion")
        settings.setEnabled(false)
        settings.record(failed: true)
        #expect(settings.needsCleanup(), "a deletion that failed is owed at the next launch")
        settings.record(failed: false)
        #expect(!settings.needsCleanup(), "one that succeeded is not owed")
    }
}
