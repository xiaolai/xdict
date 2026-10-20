import Testing
import XDictSearch

/// **A document's finish counts only for the lookup the view was asked to show** (plan-capture WI-4 rule 3, settling the
/// refutation's objection 3): the adapter used to take the model's current query for the finished document's, so a stale
/// document's finish in the gap before a newer lookup's entry request acknowledged the newer term `shown`.
struct PresentedEntryTests {
    @Test func theAskedLookupIsTheOneShown() {
        var entry = PresentedEntry()
        entry.asked(serial: 7, lookup: 4)
        #expect(entry.isCurrent(serial: 7, lookup: 4))
    }

    @Test func anotherLookupsDocumentIsNotThisOne() {
        var entry = PresentedEntry()
        entry.asked(serial: 7, lookup: 4)
        #expect(!entry.isCurrent(serial: 8, lookup: 4), "a stale document's finish in the gap was taken for the new lookup")
        entry.asked(serial: 9, lookup: 5)
        #expect(!entry.isCurrent(serial: 7, lookup: 4), "the older lookup's document came back to life")
        #expect(entry.isCurrent(serial: 9, lookup: 5))
    }

    /// **The gap**: a newer lookup has started but no result has replaced `shown` yet, so the shown serial still matches
    /// the older document's while the lookup does not. That finish is not a draw of the newer term (audit-fix finding 1).
    @Test func aNewerLookupAwaitingItsEntryIsNotTheShownDocument() {
        var entry = PresentedEntry()
        entry.asked(serial: 7, lookup: 4)
        #expect(!entry.isCurrent(serial: 7, lookup: 5), "the old lookup's document was credited to the new lookup")
    }

    /// Nothing shown, or nothing ever asked: two nils are not agreement. A panel that showed nothing has not drawn.
    @Test func nothingAskedAndNothingShownIsNotACurrentLookup() {
        var entry = PresentedEntry()
        #expect(!entry.isCurrent(serial: nil, lookup: nil), "a fresh value counted a panel that showed nothing as drawn")
        entry.asked(serial: 3, lookup: 2)
        #expect(!entry.isCurrent(serial: nil, lookup: 2), "a closed panel counted the last document as still shown")
        #expect(!entry.isCurrent(serial: 3, lookup: nil), "a lookup with no serial counted")
        entry.asked(serial: 3, lookup: nil)
        #expect(!entry.isCurrent(serial: 3, lookup: nil), "an ask with no lookup counted")
    }
}
