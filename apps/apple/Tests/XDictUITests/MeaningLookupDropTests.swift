import Testing
@testable import XDictUI

/// **When a lookup drops the held sentence** (audit 2026-10-31): the reader moving on does; a phrase ask's own lookup
/// and a card's adopted lookup — whose query is the entry key, not the recorded word (`Apple` / `apple`) — do not.
@MainActor
struct MeaningLookupDropTests {
    @Test func anotherQueryDropsTheSentence() {
        #expect(SearchWindowState.meaningIsDropped(heldTerm: "hold", query: "held", adoptionQuery: nil, phraseAsked: false))
    }

    @Test func theHandoffsOwnTermKeepsTheSentence() {
        #expect(!SearchWindowState.meaningIsDropped(heldTerm: "hold", query: "hold", adoptionQuery: nil,
                                                    phraseAsked: false))
    }

    /// A card's recorded word and its entry key differ in case or inflection; the adopted lookup queries the key.
    @Test func theAdoptionsOwnLookupKeepsTheSentence() {
        #expect(!SearchWindowState.meaningIsDropped(heldTerm: "Apple", query: "apple", adoptionQuery: "apple",
                                                    phraseAsked: false))
    }

    @Test func aPhraseAsksOwnLookupKeepsTheSentence() {
        #expect(!SearchWindowState.meaningIsDropped(heldTerm: "take into account", query: "account",
                                                    adoptionQuery: nil, phraseAsked: true))
    }

    /// The adoption names one query only: another lookup during it is the reader moving on.
    @Test func anotherQueryDuringAnAdoptionStillDropsIt() {
        #expect(SearchWindowState.meaningIsDropped(heldTerm: "Apple", query: "pear", adoptionQuery: "apple",
                                                   phraseAsked: false))
    }
}
