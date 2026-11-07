import Foundation
import Testing
@testable import XDict

/// **A Spotlight run indexes only the edition its plan names** (L14): the ledger records the run under the planned
/// edition, so a page of any other edition, the first page included, stops the run instead of being indexed under the
/// wrong name.
struct SpotlightEditionTests {
    @Test func aFirstPageFromAnotherEditionIsRefused() throws {
        #expect(throws: SpotlightLibrary.SpotlightFailure.editionChanged) {
            try SpotlightLibrary.checkedPage(edition: "new", words: ["a"], next: 1, planned: "old")
        }
    }

    @Test func aPageOfThePlannedEditionIsIndexedAndAnEmptyOneEnds() throws {
        let page = try SpotlightLibrary.checkedPage(edition: "old", words: ["a", "b"], next: 2, planned: "old")
        #expect(page?.words == ["a", "b"])
        #expect(page?.next == 2)
        #expect(try SpotlightLibrary.checkedPage(edition: "old", words: [], next: 2, planned: "old") == nil)
    }
}
