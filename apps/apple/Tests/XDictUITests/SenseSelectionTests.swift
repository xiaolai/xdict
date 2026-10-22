import Foundation
import Testing
import XDictContract
import XDictEntryView
import XDictSearch
@testable import XDictUI

/// **A sense clicked on the All page names its own frame's dictionary** (plan-explain-sense WI-5; ADR-0029 d.2): two
/// dictionaries can print the same ordinal, so the click carries the frame's handle, edition and reference, and the
/// selection is matched to what the window presents — never to the dictionary that happens to be shown.
struct SenseSelectionTests {
    static let editionA = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "aa", count: 32))
    static let editionB = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "bb", count: 32))

    static func source(_ name: String, _ id: UUID, _ handle: DictId, _ edition: Edition) -> SearchSource {
        SearchSource(id: id, name: name, edition: edition, preferencesKey: name, enabled: true, state: .ready(handle))
    }

    static func presented() -> [(result: ResultID, source: SearchSource?)] {
        let idA = UUID(), idB = UUID()
        let entryA = EntryRef(edition: editionA, key: "hold", occurrence: 0)
        let entryB = EntryRef(edition: editionB, key: "hold", occurrence: 1)
        return [(ResultID(dictionary: idA, entry: entryA), source("A", idA, DictId(rawValue: "aaaa"), editionA)),
                (ResultID(dictionary: idB, entry: entryB), source("B", idB, DictId(rawValue: "bbbb"), editionB))]
    }

    @Test func theFramesOwnDictionaryAndEditionAreSelected() {
        let entries = Self.presented()
        let picked = SearchWindowState.senseTarget(
            handle: "bbbb", edition: Self.editionB.rawValue,
            reference: EntryReference(key: "hold", occurrence: 1), sense: 1, among: entries)
        #expect(picked?.dictionary == DictId(rawValue: "bbbb"))
        #expect(picked?.entry == entries[1].result.entry)
        #expect(picked?.dictionaryName == "B")
        // The same ordinal in the other frame is that frame's own entry, never the shown one's.
        let other = SearchWindowState.senseTarget(
            handle: "aaaa", edition: Self.editionA.rawValue,
            reference: EntryReference(key: "hold", occurrence: 0), sense: 1, among: entries)
        #expect(other?.dictionary == DictId(rawValue: "aaaa"))
        #expect(other?.entry.edition == Self.editionA)
    }

    @Test func aHandleEditionOrReferenceTheWindowDoesNotPresentSelectsNothing() {
        let entries = Self.presented()
        // A handle that is not presented.
        #expect(SearchWindowState.senseTarget(handle: "cccc", edition: Self.editionA.rawValue,
                                              reference: EntryReference(key: "hold", occurrence: 0), sense: 1,
                                              among: entries) == nil)
        // The right handle with another frame's edition.
        #expect(SearchWindowState.senseTarget(handle: "bbbb", edition: Self.editionA.rawValue,
                                              reference: EntryReference(key: "hold", occurrence: 1), sense: 1,
                                              among: entries) == nil)
        // The right handle with another record's reference.
        #expect(SearchWindowState.senseTarget(handle: "bbbb", edition: Self.editionB.rawValue,
                                              reference: EntryReference(key: "held", occurrence: 1), sense: 1,
                                              among: entries) == nil)
    }
}
