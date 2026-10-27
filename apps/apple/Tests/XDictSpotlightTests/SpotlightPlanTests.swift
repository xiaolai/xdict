import Foundation
import Testing
import XDictSpotlight

/// **The index is written once per edition** (owner, 2026-10-27: a reader's library made the app delete and rewrite every
/// word on every launch): the plan says what changed, and a launch over an unchanged library asks for nothing.
struct SpotlightPlanTests {
    private func update(_ domain: String, _ edition: String) -> SpotlightPlan.Update {
        SpotlightPlan.Update(domain: domain, edition: edition)
    }

    /// **Nothing to do**: the common launch, and the one that used to rewrite millions of items.
    @Test func anUnchangedLibraryAsksForNothing() {
        let plan = SpotlightPlan.make(library: [update("a", "e1"), update("b", "e2")],
                                      indexed: ["a": "e1", "b": "e2"])
        #expect(plan.isEmpty)
    }

    /// A dictionary the index has never seen is written, and nothing else is.
    @Test func aNewDictionaryIsWritten() {
        let plan = SpotlightPlan.make(library: [update("a", "e1"), update("b", "e2")], indexed: ["a": "e1"])
        #expect(plan.removing.isEmpty)
        #expect(plan.updating == [update("b", "e2")])
    }

    /// **A new edition replaces its own domain**: the old edition's words never outlive it.
    @Test func aNewEditionIsWritten() {
        let plan = SpotlightPlan.make(library: [update("a", "e2")], indexed: ["a": "e1"])
        #expect(plan.removing.isEmpty, "the domain is rewritten in place, not removed as a whole")
        #expect(plan.updating == [update("a", "e2")])
    }

    /// A dictionary the reader removed or disabled takes its domain out, and only its own.
    @Test func aDictionaryGoneFromTheLibraryIsRemoved() {
        let plan = SpotlightPlan.make(library: [update("a", "e1")], indexed: ["a": "e1", "gone": "e9"])
        #expect(plan.removing == ["gone"])
        #expect(plan.updating.isEmpty)
    }

    /// **Domains are ordered**, so two runs over the same state do the same work in the same order.
    @Test func theplanIsOrdered() {
        let plan = SpotlightPlan.make(library: [update("b", "e"), update("a", "e")], indexed: ["z": "e", "y": "e"])
        #expect(plan.updating.map(\.domain) == ["a", "b"])
        #expect(plan.removing == ["y", "z"])
    }
}

/// **The record of what the index was given** (owner, 2026-10-27): kept in the reader's own preferences, read back by the
/// next launch, forgotten with the deletion it belongs to.
@MainActor
struct SpotlightLedgerTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.spotlight.\(UUID().uuidString)"))
    }

    @Test func whatWasIndexedIsRemembered() throws {
        let ledger = SpotlightLedger(defaults: try suite())
        #expect(ledger.indexed.isEmpty, "a reader who never indexed has no record")
        ledger.record(domain: "a", edition: "e1")
        #expect(ledger.indexed == ["a": "e1"])
        ledger.record(domain: "b", edition: "e2")
        #expect(ledger.indexed == ["a": "e1", "b": "e2"])
    }

    @Test func forgettingAndClearingLeaveWhatIsStillThere() throws {
        let ledger = SpotlightLedger(defaults: try suite())
        ledger.record(domain: "a", edition: "e1")
        ledger.record(domain: "b", edition: "e2")
        ledger.forget(domains: ["a", "missing"])
        #expect(ledger.indexed == ["b": "e2"])
        ledger.clear()
        #expect(ledger.indexed.isEmpty)
    }

    /// **A record made on another system is no record** (owner, 2026-10-27): preferences can survive an OS reinstall
    /// that took the index with it, and a record outliving its index would leave the library unsearchable.
    @Test func arecordFromAnotherSystemIsNoRecord() throws {
        let defaults = try suite()
        let ledger = SpotlightLedger(defaults: defaults)
        ledger.record(domain: "a", edition: "e1")
        #expect(ledger.indexed == ["a": "e1"])
        defaults.set("another system", forKey: SpotlightLedger.buildKey)
        #expect(ledger.indexed.isEmpty)
    }

    @Test func aStoredValueOfAnotherShapeIsNoRecord() throws {
        let defaults = try suite()
        defaults.set(["a": 1], forKey: SpotlightLedger.key)
        #expect(SpotlightLedger(defaults: defaults).indexed.isEmpty)
    }
}
