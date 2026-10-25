import Foundation
import Testing
import XDictContract
import XDictSearch
@testable import XDictUI

/// **Which dictionaries can answer this word** (owner, 2026-10-26): the All page's results, named and ready to ground an
/// ask, in the page's own order. The pane offers them on its evidence row; a choice asks the same question on that
/// dictionary's entry.
struct MeaningGroundingTests {
    static let edition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32))

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
    }

    static func entry(_ key: String, _ occurrence: UInt32 = 0) -> EntryRef {
        EntryRef(edition: edition, key: key, occurrence: occurrence)
    }

    static func source(_ n: Int, _ name: String, handle: String?) -> SearchSource {
        SearchSource(id: id(n), name: name, edition: edition, preferencesKey: "lineage-\(n)", enabled: true,
                     state: handle.map { .ready(DictId(rawValue: $0)) } ?? .indexing(fraction: nil))
    }

    @Test func thePagesDictionariesAreOfferedInItsOrderWithTheirOwnEntries() {
        let dictionary = Self.source(1, "Oxford Dictionary of English", handle: "handle-one")
        let thesaurus = Self.source(2, "Oxford American Writer’s Thesaurus", handle: "handle-two")
        let results = [ResultID(dictionary: thesaurus.id, entry: Self.entry("resource")),
                       ResultID(dictionary: dictionary.id, entry: Self.entry("resource", 1))]
        let choices = MeaningGrounding.choices(results: results, sources: [dictionary, thesaurus])
        #expect(choices.map(\.name) == ["Oxford American Writer’s Thesaurus", "Oxford Dictionary of English"])
        #expect(choices.map(\.target) == [
            MeaningTarget(dictionary: DictId(rawValue: "handle-two"), entry: Self.entry("resource")),
            MeaningTarget(dictionary: DictId(rawValue: "handle-one"), entry: Self.entry("resource", 1)),
        ])
    }

    @Test func aDictionaryThatCannotAnswerYetIsNotOffered() {
        let waiting = Self.source(3, "Oxford Thesaurus of English", handle: nil)
        let choices = MeaningGrounding.choices(results: [ResultID(dictionary: waiting.id, entry: Self.entry("x"))],
                                               sources: [waiting])
        #expect(choices.isEmpty, "a dictionary with no open entry was offered")
    }

    @Test func aDictionaryAnsweringMoreThanOnceIsOfferedOnce() {
        let one = Self.source(1, "Oxford Dictionary of English", handle: "handle-one")
        let results = [ResultID(dictionary: one.id, entry: Self.entry("a")),
                       ResultID(dictionary: one.id, entry: Self.entry("b"))]
        #expect(MeaningGrounding.choices(results: results, sources: [one]).count == 1)
    }

    @Test func aResultWhoseDictionaryIsGoneIsNotOffered() {
        let one = Self.source(1, "Oxford Dictionary of English", handle: "handle-one")
        let choices = MeaningGrounding.choices(results: [ResultID(dictionary: UUID(), entry: Self.entry("a"))],
                                               sources: [one])
        #expect(choices.isEmpty)
    }
}
