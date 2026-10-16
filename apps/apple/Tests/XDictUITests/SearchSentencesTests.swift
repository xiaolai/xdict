import Foundation
import Testing
import XDictContract
import XDictLibrary
import XDictSearch
import XDictUI

/// **What the main window says** (plan-macos-v1 WI-6): why a dictionary shows nothing, each state its own sentence (Q11),
/// what the reader can do next, why each result matched (Q4), and that every result names its dictionary (R11, and what
/// VoiceOver reads, R10). Read in the source language here; `StringCatalogTests` holds both languages complete.
struct SearchSentencesTests {
    static func text(_ resource: LocalizedStringResource?) -> String {
        resource.map { String(localized: $0) } ?? ""
    }

    /// Q11's five, and the rest a section can be: each its own sentence, the named ones naming what they name.
    @Test func everyStateASectionCanBeInHasItsOwnSentence() {
        let states: [SectionStatus] = [
            .noMatch(query: "xyzzy", mode: .reader), .noMatch(query: "xyzzy", mode: .link),
            .unavailable(.indexing(fraction: 0.4)), .unavailable(.indexing(fraction: nil)),
            .unavailable(.missingFile("gone.mdx")), .unavailable(.outsideItsFolder("link.mdd")),
            .unavailable(.malformed), .unavailable(.unsupported(.registrationCode)),
            .unavailable(.unsupported(.formatVersion("4.0"))), .unavailable(.notImported(.cancelled)),
            .failed(.malformed), .failed(.changed), .failed(.tooLarge), .failed(.serviceFailed), .searching,
        ]
        let sentences = states.map { Self.text(SearchSentences.status($0)) }
        #expect(sentences.allSatisfy { !$0.isEmpty }, "\(sentences)")
        #expect(Set(sentences).count == states.count, "two states read alike: \(sentences)")
        #expect(sentences[0].contains("xyzzy") && sentences[1].contains("xyzzy"))
        #expect(sentences[2].contains("40"))
        #expect(sentences[4].contains("gone.mdx") && sentences[5].contains("link.mdd"))
        #expect(sentences[8].contains("4.0"))
        #expect(SearchSentences.status(.results(Results(hits: [], total: 0, generation: 0))) == nil)
    }

    @Test func everyNextActionIsWordedAndItsOwn() {
        let id = UUID()
        let actions: [NextAction] = [.wait, .openLibrary(id), .retryImport(id), .retryLookup(id), .reopen,
                                     .searchEverywhere("abbe"), .checkSpelling]
        let words = actions.map { Self.text(SearchSentences.action($0)) }
        #expect(words.allSatisfy { !$0.isEmpty }, "\(words)")
        #expect(Set(words).count == actions.count, "\(words)")
        #expect(words[5].contains("abbe"))
        #expect(SearchSentences.isButton(.openLibrary(id)) && SearchSentences.isButton(.retryLookup(id))
                && SearchSentences.isButton(.searchEverywhere("a")))
        #expect(!SearchSentences.isButton(.wait) && !SearchSentences.isButton(.checkSpelling))
    }

    /// Q4: the reason a result matched is shown, each its own; a redirect names the way it came.
    @Test func everyMatchReasonIsItsOwn() {
        let reasons: [How] = [.exact, .folded, .unmarked, .redirect(chain: ["colour", "color"])]
        let words = reasons.map { Self.text(SearchSentences.reason($0)) }
        #expect(Set(words).count == reasons.count, "\(words)")
        #expect(words[3].contains("colour") && words[3].contains("color"))
    }

    /// R10, R11: every result, as VoiceOver reads it, names its headword, why it matched, and its dictionary.
    @Test func aResultReadsWithItsDictionary() {
        let label = Self.text(SearchSentences.result(headword: "abbé", how: .unmarked, record: nil, dictionary: "Beta"))
        #expect(label.contains("abbé") && label.contains("Beta"))
        #expect(label.contains(Self.text(SearchSentences.reason(.unmarked))))
        let second = Self.text(SearchSentences.result(headword: "run", how: .exact, record: 2, dictionary: "Alpha"))
        #expect(second.contains(Self.text(SearchSentences.record(2))) && second.contains("Alpha"))
    }

    /// Q10, R11: a section says whose results they are, which edition, and how many of how many are shown.
    @Test func aSectionSaysWhoseHowManyAndWhichEdition() {
        let edition = Edition(rawValue: "mdx-sha256-v1:3f2a9c1e5b7d00112233445566778899")
        #expect(SearchSentences.edition(edition) == "3f2a9c1e")
        #expect(SearchSentences.edition(Edition(rawValue: "odd")) == "odd")
        let all = Self.text(SearchSentences.count(loaded: 3, total: 3))
        let some = Self.text(SearchSentences.count(loaded: 100, total: 66_355))
        #expect(all.contains("3") && some.contains("100") && some.contains("66"))
        #expect(all != some)
        #expect(Self.text(SearchSentences.more(1_000, remaining: 66_255)).contains("1"))
        let header = Self.text(SearchSentences.section(name: "Records", edition: edition, loaded: 100, total: 66_355))
        #expect(header.contains("Records") && header.contains("3f2a9c1e"))
    }

    /// The owner, 2026-10-16: the edition is out of a header, shown and read, unless another edition of the same
    /// dictionary is in the results; its help names it either way.
    @Test func aHeaderNamesItsEditionOnlyWhereTwoEditionsMeet() {
        let edition = Edition(rawValue: "mdx-sha256-v1:3f2a9c1e5b7d00112233445566778899")
        let results = SectionStatus.results(Results(hits: [], total: 3, generation: 1))
        let alone = ResultSection(id: UUID(), name: "Alpha", edition: edition, showsEdition: false, status: results)
        let beside = ResultSection(id: UUID(), name: "Alpha", edition: edition, showsEdition: true, status: results)
        #expect(SearchSentences.inlineEdition(alone) == nil)
        #expect(SearchSentences.inlineEdition(beside) == "3f2a9c1e")
        #expect(!Self.text(SearchSentences.header(alone)).contains("3f2a9c1e"))
        #expect(Self.text(SearchSentences.header(alone)).contains("Alpha"))
        #expect(Self.text(SearchSentences.header(beside)).contains("3f2a9c1e"))
        #expect(Self.text(SearchSentences.editionHelp(edition)).contains("3f2a9c1e5b7d00112233445566778899"))
        let damaged = ResultSection(id: UUID(), name: "Damaged", edition: edition, showsEdition: false,
                                    status: .failed(.serviceFailed))
        #expect(Self.text(SearchSentences.header(damaged)) == "Damaged")
    }

    /// Q11, R10: a section with nothing to count (indexing, damaged, missing) names its dictionary and edition and
    /// claims no count: VoiceOver must not read "0 results" for a dictionary that was never asked.
    @Test func aSectionWithNothingToCountClaimsNoCount() {
        let edition = Edition(rawValue: "mdx-sha256-v1:3f2a9c1e5b7d00112233445566778899")
        let none = Self.text(SearchSentences.count(loaded: 0, total: 0))
        let header = Self.text(SearchSentences.section(name: "Damaged", edition: edition))
        #expect(header.contains("Damaged") && header.contains("3f2a9c1e") && !header.contains(none))
        #expect(Self.text(SearchSentences.section(name: "Gone", edition: nil)) == "Gone")
        #expect(Self.text(SearchSentences.allDictionaries) == "All Dictionaries")
    }
}
