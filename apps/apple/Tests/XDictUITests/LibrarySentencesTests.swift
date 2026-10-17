import Foundation
import Testing
import XDictContract
import XDictLibrary
import XDictUI

/// **Every refusal is a sentence that names why** (AGENTS.md: never a silent skip; ADR-0007 decision 10: the shell words
/// the kinds). One sentence per kind, each its own, naming what it names; read here in the source language — the
/// catalog's completeness in English and Simplified Chinese is `StringCatalogTests`'.
struct LibrarySentencesTests {
    static let refusals: [ImportRefusal] = [
        .formatVersion("4.0"), .resourceLibraryV3, .registrationCode, .encrypted, .compression, .encoding("KOI8-R"),
        .damaged, .tooLarge, .missingFile("a.mdx"), .unreadable("a.mdx"), .notAFile("a.mdx"), .changedDuringImport,
        .cancelled, .serviceFailed,
    ]

    @Test func eachRefusalHasItsOwnSentence() {
        let sentences = Self.refusals.map { String(localized: LibrarySentences.refusal($0)) }
        #expect(Set(sentences).count == Self.refusals.count, "\(sentences)")
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }

    @Test func theNamedRefusalsSayWhatTheyName() {
        #expect(String(localized: LibrarySentences.refusal(.formatVersion("4.0"))).contains("4.0"))
        #expect(String(localized: LibrarySentences.refusal(.encoding("KOI8-R"))).contains("KOI8-R"))
        #expect(String(localized: LibrarySentences.refusal(.missingFile("a.mdx"))).contains("a.mdx"))
        #expect(String(localized: LibrarySentences.refusal(.notAFile("a.mdx"))).contains("a.mdx"))
        #expect(String(localized: LibrarySentences.refusal(.resourceLibraryV3)).contains("3.0"))
        #expect(String(localized: LibrarySentences.refusal(.registrationCode)).contains("registration code"))
        #expect(String(localized: LibrarySentences.refusal(.damaged)).contains("damaged"))
    }

    @Test func notesNameTheirFiles() {
        let notes: [EntryNote] = [.missingVolume(fileName: "x.1.mdd"), .outsideChosenFolder(fileName: "x.css"),
                                  .volumeUnreadable(fileName: "x.mdd", reason: .resourceLibraryV3)]
        for (note, name) in zip(notes, ["x.1.mdd", "x.css", "x.mdd"]) {
            #expect(String(localized: LibrarySentences.note(note)).contains(name), "\(note)")
        }
        #expect(String(localized: LibrarySentences.note(.sidecarsOmitted(count: 19))).contains("19"))
    }

    @Test func missingAndUnsupportedSoundsAreToldApart() {
        let missing = String(localized: LibrarySentences.sound(.missing(path: "gone.mp3")))
        let unsupported = String(localized: LibrarySentences.sound(.unsupported(format: "spx")))
        #expect(missing != unsupported && missing.contains("gone.mp3") && unsupported.contains("spx"))
    }

    @Test func noticesAndLibraryFailuresAreSentences() {
        let notices: [LibraryNotice] = [
            .finder(.notADictionaryFile(fileName: "a.txt")), .finder(.noDictionaryIn(folderName: "f")),
            .finder(.volumesWithoutDictionary(fileNames: ["o.mdd"])), .finder(.outsideChosenFolder(fileName: "far.mdx")),
            .finder(.unreadable(fileName: "u")), .alreadyInLibrary(name: "N"), .relinked(name: "R"),
            .notSaved(.unavailable(errno: 28)),
        ]
        let sentences = notices.map { String(localized: LibrarySentences.notice($0)) }
        #expect(Set(sentences).count == notices.count, "\(sentences)")
        #expect(String(localized: LibrarySentences.unreadable(.damaged))
                != String(localized: LibrarySentences.unreadable(.newerVersion(2))))
    }

    /// ADR-0010: where the base size came from, why a font is kept and what changed are each their own sentence; the
    /// dictionary's own words (a selector, a family) are quoted, never translated.
    @Test func theReadingStyleIsToldInSentences() {
        let sources: [BaseSource] = [.page(selector: "body"), .prose(weight: 12), .text(chars: 900, share: 0.75),
                                     .browserDefault]
        let said = sources.map { String(localized: LibrarySentences.baseSize(px: 14, from: $0)) }
        #expect(Set(said).count == sources.count, "\(said)")
        #expect(said[0].contains("body") && said[0].contains("14"))
        #expect(said[2].contains("75"))
        let reasons = FontReason.allCases.map { String(localized: LibrarySentences.fontReason($0)) }
        #expect(Set(reasons).count == FontReason.allCases.count)
        let none = StyleChanges(important: 0, page: 0, family: 0, size: 0, lineHeight: 0, colour: 0, weight: 0, space: 0,
                                dropped: 0)
        #expect(LibrarySentences.styleChanges(none).count == 1, "nothing changed is said once")
        let some = StyleChanges(important: 3, page: 0, family: 9, size: 40, lineHeight: 0, colour: 0, weight: 0, space: 0,
                                dropped: 0)
        let changes = LibrarySentences.styleChanges(some).map { String(localized: $0) }
        #expect(changes.count == 3 && changes.contains { $0.contains("40") }, "\(changes)")
        #expect(String(localized: LibrarySentences.styleStatus(.unavailable))
                != String(localized: LibrarySentences.styleStatus(.reading)))
    }

    /// WI-12: one sentence per kind of finding, each its own and each saying how many; a missing file is named.
    @Test func eachHealthFindingIsItsOwnSentenceWithItsCount() {
        let findings = FindingKind.allCases.map {
            HealthFinding(kind: $0, count: 4_321, name: $0 == .missingFile ? "OED.css" : nil, examples: [])
        }
        let sentences = findings.map { String(localized: LibrarySentences.health($0)) }
        #expect(Set(sentences).count == FindingKind.allCases.count, "\(sentences)")
        for sentence in sentences {
            #expect(sentence.contains("4,321") || sentence.contains("4321"), "\(sentence)")
        }
        #expect(sentences[0].contains("OED.css"))
    }

    /// Checking, healthy, checked with findings, and a check that could not finish are told apart.
    @Test func theCheckSaysWhereItIs() {
        let healthy = Health(version: 1, entries: 706_524, findings: [], classes: [])
        let repaired = Health(version: 1, entries: 9, findings: [HealthFinding(kind: .repaired, count: 2, name: nil,
                                                                                examples: [])], classes: [])
        let found = Health(version: 1, entries: 9, findings: [HealthFinding(kind: .emptyEntries, count: 1, name: nil,
                                                                             examples: [])], classes: [])
        let states: [HealthState] = [.checking(done: 2, total: 5), .checked(healthy), .checked(found), .unavailable]
        let sentences = states.map { String(localized: LibrarySentences.healthStatus($0)) }
        #expect(Set(sentences).count == states.count, "\(sentences)")
        #expect(sentences[0].contains("40"))
        #expect(sentences[1].contains("706,524") || sentences[1].contains("706524"))
        #expect(String(localized: LibrarySentences.healthStatus(.checked(repaired))) == sentences[1]
                    .replacingOccurrences(of: "706,524", with: "9").replacingOccurrences(of: "706524", with: "9"),
                "what XDict repairs itself leaves a dictionary healthy")
    }
}
