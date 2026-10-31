import Foundation
import Testing
import XDictContract
@testable import XDictSearch
import XDictTestSupport
@testable import XDictUI

/// **What an Explore tab that cannot answer says** (owner, 2026-10-31): a capability the system does not provide is
/// named where the reader would choose it — the data it needs, why XDict does not ship it, and where to get it — in
/// both of the app's languages, never a bare "nothing".
@MainActor
struct ExploreSentencesTests {
    static func text(_ page: ExploreModel.Page, tab: ExploreModel.Tab, word: String = "decision",
                     _ language: String = "en") -> String {
        guard let sentence = ExploreSentences.state(page, tab: tab, word: word) else { return "" }
        return (try? CompiledCatalog.text(sentence, in: language)) ?? "the catalog did not compile"
    }

    /// **The Collocations tab, empty**, names the dictionary collocations come from and where the reader adds it.
    /// The core cannot say whether the library has no such dictionary or the word has none in it, so the sentence
    /// says both, in each language.
    @Test func anEmptyCollocationsTabNamesTheDictionaryAndWhereToAddIt() {
        let empty = ExploreModel.Page(rows: [], state: .answered)
        for (language, dictionary, settings) in
            [("en", "Oxford Collocations Dictionary", "Settings ▸ Dictionaries"),
             ("zh-Hans", "牛津英语搭配词典", "“设置”▸“词典”")] {
            let text = Self.text(empty, tab: .collocations, language)
            #expect(!text.isEmpty, "\(language): the empty Collocations tab says nothing")
            #expect(text.contains(dictionary), "\(language): \(text)")
            #expect(text.contains(settings), "\(language): \(text)")
            #expect(text.contains(language == "en" ? "already in the library" : "已在"), "\(language): \(text)")
        }
    }

    /// **A mode with nothing for the word keeps its own wording**: the dictionary sentence belongs to the tab whose
    /// data may be absent, not to every empty answer.
    @Test func anEmptyModeStillSaysNothingWasFound() {
        let empty = ExploreModel.Page(rows: [], state: .answered)
        #expect(Self.text(empty, tab: .rhymes, word: "nation") == "Nothing in this mode for “nation”.")
        #expect(Self.text(empty, tab: .rhymes, word: "nation", "zh-Hans") == "这个模式下没有“nation”。")
    }

    /// **No word data**: the sentence names the data, why XDict does not ship it, where it is built, and the second
    /// meaning of `noData` — an installed pack that holds none of this kind.
    @Test func noWordDataNamesWhyWhereAndTheSecondCase() {
        let missing = ExploreModel.Page(rows: [], state: .noData)
        for (language, reason, build, settings, installed) in [
            ("en", "does not come with XDict", "Build Word Data…", "Settings ▸ Dictionaries ▸ Word data",
             "installed already"),
            ("zh-Hans", "不随 XDict 附带", "构建词数据…", "“设置”▸“词典”▸“词数据”", "已经安装"),
        ] {
            let text = Self.text(missing, tab: .synonyms, word: "happy", language)
            #expect(text.contains(reason), "\(language): \(text)")
            #expect(text.contains(build), "\(language): \(text)")
            #expect(text.contains(settings), "\(language): \(text)")
            #expect(text.contains(installed), "\(language): \(text)")
        }
    }

    /// Every tab that reads the word data says it, not only the one this test happens to choose.
    @Test func everyPackBackedTabSaysWhatItNeeds() {
        let missing = ExploreModel.Page(rows: [], state: .noData)
        let sentences = ExploreModel.Tab.allCases.filter { $0.mode != nil }.map { Self.text(missing, tab: $0) }
        #expect(sentences.count == 6, "\(sentences.count) pack-backed tabs: \(sentences)")
        #expect(Set(sentences).count == 1, "\(sentences)")
        #expect(!sentences[0].isEmpty)
    }

    /// A failure and a cut answer keep their own sentences; the empty-tab wording is for an answer that was given.
    @Test func aFailureIsSaidAsItself() {
        var failed = ExploreModel.Page()
        failed.failure = .timedOut
        #expect(Self.text(failed, tab: .collocations) == "The dictionaries took too long. Try again.")
        let cut = ExploreModel.Page(rows: [ExploreRow(word: "make", dict: DictId(rawValue: "handle-1"),
                                                      entry: EntryRef(edition: Edition(rawValue: "e1"),
                                                                      key: "decision", occurrence: 0),
                                                      reason: .collocation(.verbPlusHeadword))],
                                    cut: true)
        #expect(Self.text(cut, tab: .collocations) == "Cut short by the work budget: there may be more.")
    }
}
