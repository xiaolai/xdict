import Testing
import XDictLibrary

/// **The reader's search and explanation languages, proposed from the file name and asked when uncertain** (L3: "avoid
/// confident inference from title"). Only a name that states its pair is taken without asking; everything else is a
/// guess the reader confirms, or no proposal at all.
struct LanguageProposalTests {
    @Test(arguments: [
        ("牛津高阶英汉双解词典(第9版)_V3.1.2版", "en", "zh-Hans"),
        ("新世纪英汉大词典(修)", "en", "zh-Hans"),
        ("柯林斯COBUILD高阶英汉双解学习词典", "en", "zh-Hans"),
        ("LDOCE6++ En-Cn V2-19", "en", "zh-Hans"),
        ("Oxford English-Chinese", "en", "zh-Hans"),
        ("汉英词典", "zh-Hans", "en"),
        ("遠東英漢大辭典", "en", "zh-Hant"),
        ("英英词典", "en", "en"),
        ("研究社 和英", "ja", "en"),
        ("French-English Dictionary", "fr", "en"),
    ])
    func aNameThatStatesItsPairIsNotAsked(name: String, search: String, explanation: String) {
        let proposal = LanguageProposal.from(fileName: name)
        #expect(proposal.pair == LanguagePair(search: search, explanation: explanation), "\(name)")
        #expect(proposal.basis == .stated && !proposal.needsAsking, "\(name)")
    }

    @Test(arguments: [
        ("Oxford Advanced Learner's Dictionary 10th", "en", "en"),
        ("Plain Glossary", "en", "en"),
        ("ODECN", "en", "en"),
        ("现代汉语词典", "zh-Hans", "zh-Hans"),
        ("現代漢語詞典", "zh-Hant", "zh-Hant"),
        ("こくご辞典", "ja", "ja"),
    ])
    func aGuessIsProposedAndAsked(name: String, search: String, explanation: String) {
        let proposal = LanguageProposal.from(fileName: name)
        #expect(proposal.pair == LanguagePair(search: search, explanation: explanation), "\(name)")
        #expect(proposal.basis == .guessed && proposal.needsAsking, "\(name)")
    }

    /// Words that only look like a pair are not one: "中华" is Chinese, not Chinese–Chinese.
    @Test func lookalikesAreNotAPair() {
        #expect(LanguageProposal.from(fileName: "中华成语词典").basis == .guessed)
        #expect(LanguageProposal.from(fileName: "Encyclopedia").basis == .guessed)
    }

    @Test func aNameWithNoLettersProposesNothing() {
        let proposal = LanguageProposal.from(fileName: "2020-12-31")
        #expect(proposal.pair == LanguagePair(search: nil, explanation: nil))
        #expect(proposal.basis == .unknown && proposal.needsAsking)
    }

    /// The extension is not part of the name the reader gave the dictionary.
    @Test func theExtensionIsIgnored() {
        #expect(LanguageProposal.from(fileName: "汉英.mdx").pair == LanguagePair(search: "zh-Hans", explanation: "en"))
    }
}
