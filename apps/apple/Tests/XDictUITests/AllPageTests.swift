import Foundation
import Testing
import XDictContract
import XDictSearch
@testable import XDictUI

/// **The All page's entries** (parity P15): the reader's order, one entry per dictionary that has the word, the shown
/// one as chosen, the others by the headword's exact spelling.
struct AllPageTests {
    private static let edition = Edition(rawValue: String(repeating: "a", count: 64))

    private static func hit(_ key: String, _ occurrence: UInt32 = 0) -> Hit {
        Hit(dict: DictId(rawValue: "d"), entry: EntryRef(edition: edition, key: key, occurrence: occurrence),
            headword: key, how: .exact, problems: [])
    }

    private static func section(_ id: UUID, _ status: SectionStatus) -> ResultSection {
        ResultSection(id: id, name: id.uuidString, edition: nil, showsEdition: false, status: status)
    }

    private static func found(_ keys: String...) -> SectionStatus {
        .results(Results(hits: keys.map { hit($0) }, total: UInt64(keys.count), generation: 1))
    }

    @Test func oneEntryPerDictionaryThatHasTheWordInTheReadersOrder() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let sections = [
            Self.section(a, Self.found("apple", "Apple")),
            Self.section(b, .noMatch(query: "apple", mode: .reader)),
            Self.section(c, .searching),
            Self.section(d, Self.found("Apple", "apple")),
        ]
        let shown = ResultID(dictionary: a, entry: Self.hit("apple").entry)
        let page = AllPage.results(sections: sections, shown: shown, headword: "apple")
        #expect(page.map(\.dictionary) == [a, d], "a dictionary without the word, or still searching, has no frame")
        #expect(page.first == shown)
        #expect(page.last?.entry.key == "apple", "the headword's own spelling, not merely the first hit")
    }

    @Test func theShownResultKeepsItsOwnEntry() {
        let (a, b) = (UUID(), UUID())
        let sections = [Self.section(a, Self.found("apple")), Self.section(b, Self.found("apple", "Apple"))]
        let shown = ResultID(dictionary: b, entry: Self.hit("Apple").entry)
        let page = AllPage.results(sections: sections, shown: shown, headword: "Apple")
        #expect(page.map(\.dictionary) == [a, b], "the reader's order, not the shown one first")
        #expect(page[1] == shown)
        #expect(page[0].entry.key == "apple", "no exact spelling there: its first hit")
    }

    @Test func onlyATypedWordOverEveryDictionaryIsAPage() {
        #expect(AllPage.applies(scope: .all, mode: .reader))
        #expect(!AllPage.applies(scope: .one(UUID()), mode: .reader))
        #expect(!AllPage.applies(scope: .all, mode: .link))
    }
}
