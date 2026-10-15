import Foundation
import Testing
import XDictAnywhere

/// **What is looked up, from whatever the reader selected** — by the shortcut (the Accessibility API) or by the
/// Service (the pasteboard macOS hands it). One rule for both: the selection less its wrapping punctuation, Unicode and
/// phrases kept exactly. Moved from XiaolaiDict (`SelectedTermTests`).
struct LookupTextTests {
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

    // MARK: - The Service's text

    /// **The Service's answer is the selection, as the shortcut's is**: a Unicode phrase delivered intact, its
    /// wrapping punctuation off; nothing, only punctuation and too much each refused by kind.
    @Test func theServicesTextIsTheSameRule() {
        #expect(LookupText.term(" crème brûlée 煎饼 ") == .term("crème brûlée 煎饼"))
        #expect(LookupText.term("“take off,”") == .term("take off"))
        #expect(LookupText.term(nil) == .empty)
        #expect(LookupText.term("  \n") == .empty)
        #expect(LookupText.term("“…”") == .noWord)
        let long = String(repeating: "a", count: LookupText.maximumLength + 1)
        #expect(LookupText.term(long) == .tooLong(characters: LookupText.maximumLength + 1))
        #expect(LookupText.term(String(repeating: "a", count: LookupText.maximumLength)) != .tooLong(
            characters: LookupText.maximumLength))
    }
}
