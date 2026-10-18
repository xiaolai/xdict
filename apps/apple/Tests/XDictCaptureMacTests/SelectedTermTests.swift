import Foundation
import Testing
import XDictCaptureMac

/// **The term a selection stands for** (moved by name from `XDictAnywhereTests`' `LookupTextTests` with `SelectedTerm`,
/// plan-capture WI-2; from XiaolaiDict's `SelectedTermTests` before that): the selection less its wrapping punctuation,
/// Unicode and phrases kept exactly.
struct SelectedTermTests {
    @Test(arguments: [
        ("“ephemeral,”", "ephemeral"), ("  spaced \n", "spaced"), ("(word)", "word"), ("[note]", "note"),
        ("etc.", "etc"), ("word...", "word"), ("word…", "word"), ("Really?!", "Really"), ("'quoted'", "quoted"),
        ("—dash—", "dash"), ("“学习”。", "学习"), ("¿qué?", "qué"), (".NET.", ".NET"), ("example.com.", "example.com"),
    ])
    func wrappingAndEndingPunctuationComesOff(selection: String, term: String) {
        #expect(SelectedTerm(from: selection)?.text == term)
    }

    /// Trimming every punctuation mark turned C# into C and .NET into NET in XiaolaiDict.
    @Test(arguments: ["C#", ".NET", "U.S.", "e.g.", "Ph.D.", "a.m.", "don't", "word(s)", "-ish", "'tis", "rock-'n'-roll",
                      "C++", "(a) or (b)", "take off", "abbé", "crème brûlée 煎饼"])
    func punctuationThatBelongsToTheTermStays(term: String) {
        #expect(SelectedTerm(from: term)?.text == term)
    }

    @Test(arguments: ["", "   ", "...", "“”", "()", "!?"])
    func aSelectionOfOnlyPunctuationHasNoTerm(selection: String) {
        #expect(SelectedTerm(from: selection) == nil)
    }

    @Test func theTermKnowsWhereItSatInTheSelection() throws {
        let term = try #require(SelectedTerm(from: " “ephemeral,” "))
        #expect(term.range == NSRange(location: 2, length: 9))
    }

    /// **The admission is the consumer's, and it refuses rather than cuts** (XDict ADR-0014 decision 3): counted in
    /// characters, the limit itself admitted, one more not.
    @Test func anAdmissionCountsCharactersAndNeverCuts() {
        let admission = TermAdmission(maximumCharacters: 3)
        #expect(admission.admits("煎饼果"))
        #expect(admission.admits("e\u{301}e\u{301}e\u{301}"), "a combining mark is part of its character")
        #expect(!admission.admits("abcd"))
    }
}
