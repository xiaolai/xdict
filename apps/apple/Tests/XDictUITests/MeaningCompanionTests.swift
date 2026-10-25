import Foundation
import Testing
import XDictAI
import XDictContract
@testable import XDictUI

/// **The pane's two pure selections** (plan-companion WI-7, WI-12; Codex refutation, 2026-10-25): which language a term is
/// spoken in, and which dictionary a pair's source opens.
struct MeaningCompanionTests {
    static let entry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32)),
                                key: "hold", occurrence: 0)
    static let target = MeaningTarget(dictionary: DictId(rawValue: "1a2b3c4d00000001"), entry: entry)

    @Test func theAnswersDictionaryLanguageWinsOverTheShownFrame() {
        // **Only the target's dictionary answers "zh-Hans"** (audit round 2, 2026-10-25): a closure that ignored its
        // argument could not tell a correct lookup from one that read another dictionary.
        #expect(SearchWindowState.termLanguage(for: Self.target, languageOf: { dictionary in
            dictionary == Self.target.dictionary ? "zh-Hans" : "en"
        }, presented: "en") == "zh-Hans")
    }

    @Test func withoutATargetTheShownEntrysLanguageIsUsed() {
        #expect(SearchWindowState.termLanguage(for: nil, languageOf: { _ in "zh-Hans" }, presented: "en") == "en")
    }

    @Test func aDictionaryTheLibraryDoesNotKnowFallsBackToTheShownEntry() {
        #expect(SearchWindowState.termLanguage(for: Self.target, languageOf: { _ in nil }, presented: "en") == "en")
    }

    /// Each source carries its own edition and occurrence, so a lookup that returns the right key with another
    /// source's edition or occurrence fails (audit round 2, 2026-10-25).
    static func hit(_ dictionaries: [String]) -> ExampleHit {
        ExampleHit(english: "They hold that view.", chinese: "他们持那种看法。", start: 0, len: 6, sentence: false,
                   sources: dictionaries.enumerated().map { index, dict in
                       ExampleSource(dict: DictId(rawValue: dict),
                                     entry: EntryRef(edition: Edition(rawValue: "edition-" + dict),
                                                     key: "hold-" + dict, occurrence: UInt32(index)),
                                     headword: "hold")
                   })
    }

    /// **A pair's plain click opens the first source the library has**: a removed dictionary is skipped, never opened in
    /// another's frame (plan-companion WI-12).
    @Test func theFirstAvailableSourceSkipsADictionaryThatIsGone() {
        let hit = Self.hit(["alpha", "beta"])
        #expect(SearchWindowState.firstAvailableSource(hit, isAvailable: { $0.rawValue == "beta" }) == hit.sources[1])
        #expect(SearchWindowState.firstAvailableSource(hit, isAvailable: { _ in false }) == nil)
        #expect(SearchWindowState.firstAvailableSource(hit, isAvailable: { _ in true }) == hit.sources[0])
    }

    /// **A named source resolves to its own entry**, not the first source's: two dictionaries can carry the same pair.
    @Test func aNamedSourceIsThatDictionarysEntry() {
        let hit = Self.hit(["alpha", "beta"])
        for source in hit.sources {
            #expect(SearchWindowState.exampleEntry(hit, in: source.dict) == source.entry,
                    "\(source.dict) opened another source's record")
        }
        #expect(SearchWindowState.exampleEntry(hit, in: DictId(rawValue: "gamma")) == nil)
    }
}

/// **The sources this plan changed keep the decisions it made** (plan-companion WI-2, WI-5, WI-6): a font is not
/// Equatable in a unit test and a caption has no state, so these read the source the way this repository's other wiring
/// checks do — a regression reverted in code fails here.
struct CompanionSourceTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// **The file's code with whole-line comments removed** (audit round 3, 2026-10-25): a wiring check that matched a
    /// comment proved nothing.
    static func code(_ path: String) throws -> String {
        try source(path).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The matched run in an example keeps the reading face** (Codex refutation B2): only the weight changes; the
    /// old selected-row font, at another size and in the UI's sans, is gone.
    @Test func theMatchedExampleRunUsesTheReadingFace() throws {
        let source = try Self.code("Sources/XDictUI/ExamplesSection.swift")
        #expect(source.contains("match.font = ReadingText.emphasized.font"))
        #expect(!source.contains("match.font = Tokens.TextRole.sidebarRowSelected.font"))
    }

    /// **The sense list's decision, tested as behaviour** (audit round 1, 2026-10-25; round 2): rows are shown only for
    /// the entry they were read from, a failed read is named, and an entry with no senses shows nothing.
    @Test func theSenseListBelongsToItsOwnEntry() {
        let target = MeaningCompanionTests.target
        let other = MeaningTarget(dictionary: target.dictionary,
                                  entry: EntryRef(edition: MeaningCompanionTests.entry.edition, key: "other",
                                                  occurrence: 0))
        func decision(_ sent: MeaningTarget?, _ senses: MeaningTarget?, _ status: MeaningSession.SensesStatus?,
                      _ count: Int) -> SenseListDecision {
            SenseListDecision.of(sentTarget: sent, sensesTarget: senses, status: status, count: count)
        }
        #expect(decision(target, other, .loaded, 2) == .hidden, "another entry's rows were shown for this one")
        // **Every part of the target matters** (audit round 3): a comparison by key alone would pass these.
        let otherDictionary = MeaningTarget(dictionary: DictId(rawValue: "feedface00000009"), entry: target.entry)
        let otherEdition = MeaningTarget(dictionary: target.dictionary,
                                         entry: EntryRef(edition: Edition(rawValue: "edition-other"),
                                                         key: target.entry.key, occurrence: target.entry.occurrence))
        let otherOccurrence = MeaningTarget(dictionary: target.dictionary,
                                            entry: EntryRef(edition: target.entry.edition, key: target.entry.key,
                                                            occurrence: target.entry.occurrence + 1))
        for stale in [otherDictionary, otherEdition, otherOccurrence] {
            #expect(decision(target, stale, .loaded, 2) == .hidden, "\(stale) was accepted as the same entry")
        }
        #expect(decision(nil, target, .loaded, 2) == .hidden)
        #expect(decision(target, target, .failed, 0) == .failed(target))
        #expect(decision(target, target, .loading, 0) == .hidden)
        #expect(decision(target, target, .loaded, 0) == .hidden)
        #expect(decision(target, target, .loaded, 2) == .rows(target))
    }

    /// The view draws that decision and routes its retry to the session (the behaviour above is the gate itself).
    @Test func theViewDrawsTheSenseDecision() throws {
        let source = try Self.code("Sources/XDictUI/MeaningAnswerView.swift")
        #expect(source.contains("switch senseDecision"))
        // The rows reload for each new answer, not only when the target changes (verification round 3).
        #expect(source.contains(".task(id: state.meaning.sent)"))
        // **The retry button's own line** (audit round 3, 2026-10-25): the substring alone also matched the pane's
        // initial `.task` load, so removing the retry action left the check green.
        #expect(source.contains(#"Button("Try Again") { state.meaning.loadSenses(for: target) }"#))
        #expect(source.contains("The senses could not be read."))
    }

    /// **The pane's save goes through the wired state** (plan-companion WI-9): the control exists only with a study model,
    /// and the text is the note builder's.
    @Test func thePaneSavesANoteThroughTheStatesModel() throws {
        let source = try Self.code("Sources/XDictUI/MeaningAnswerView.swift")
        #expect(source.contains("state.noteSaver != nil"))
        #expect(source.contains("state.saveNote(for: target, text: text)"))
        #expect(source.contains("MeaningPresenter.noteText("))
        #expect(source.contains(#"Button("Save as Note")"#))
    }

    /// **Settings' own preview carries the answer language**: it composes through `AIComposer`, so the preview a reader
    /// reads is the request that will leave, line included.
    @Test func theSettingsPreviewCarriesTheLanguageLine() throws {
        let composed = try MeaningPreview.compose(template: "{term} {sentence} {entry}", language: "zh-Hans",
                                                  mode: .grounded).get()
        #expect(composed.contains("The explanation must be written in the language whose BCP 47 tag is \"zh-Hans\""))
    }

    /// **The settings caption says what the choice does** (plan-companion WI-6), beside the picker it explains.
    @Test func theAnswerLanguageRowSaysWhatItDoes() throws {
        let source = try Self.code("Sources/XDictUI/AISettings.swift")
        #expect(source.contains("ai.language.caption"))
        #expect(source.contains("Quotes stay in the dictionary’s own language"))
    }
}
