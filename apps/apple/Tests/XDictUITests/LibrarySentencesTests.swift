import Foundation
import Testing
import XDictLibrary
import XDictUI

/// **Every refusal is a sentence that names why** (AGENTS.md: never a silent skip; ADR-0007 decision 10: the shell words
/// the kinds). One sentence per kind, each its own, naming what it names; read here in the source language — the
/// catalog's completeness in English and Simplified Chinese is `StringCatalogTests`'.
struct LibrarySentencesTests {
    static let refusals: [ImportRefusal] = [
        .formatVersion("4.0"), .resourceLibraryV3, .registrationCode, .encrypted, .compression, .encoding("KOI8-R"),
        .damaged, .tooLarge, .missingFile("a.mdx"), .unreadable("a.mdx"), .changedDuringImport, .cancelled, .serviceFailed,
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
}
