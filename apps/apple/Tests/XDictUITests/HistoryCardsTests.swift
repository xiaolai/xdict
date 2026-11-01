import Foundation
import Testing
import XDictContract
import XDictUI

/// **The resting context's window** (ADR-0037): one line around the word, never the word dropped, and an ellipsis only
/// at an end the window or the capture actually cut. The view supplies the budget; these are the pure cases.
struct HistoryPreviewTests {
    static func span(of word: String, in sentence: String) -> LedgerSpan {
        let range = (sentence as NSString).range(of: word)
        return LedgerSpan(start: UInt32(range.location), len: UInt32(range.length))
    }

    static func joined(_ runs: [HistoryRuns.Run]) -> String {
        runs.map { run in
            switch run {
            case .text(let part), .word(let part): part
            }
        }.joined()
    }

    static func word(_ runs: [HistoryRuns.Run]) -> String? {
        for run in runs {
            if case .word(let part) = run { return part }
        }
        return nil
    }

    @Test func theWordAndBothSidesAreKeptInOneLine() {
        let sentence = "The quick brown fox jumps over the lazy dog."
        let runs = HistoryPreview.context(sentence: sentence, span: Self.span(of: "fox", in: sentence),
                                          cut: 0, budget: 24)
        #expect(Self.word(runs) == "fox")
        let text = Self.joined(runs)
        #expect(text.contains("fox"))
        #expect(text.hasPrefix("…") && text.hasSuffix("…"), "both sides were clipped: \(text)")
        let graphemes = text.filter { $0 != "…" }.count
        #expect(graphemes <= 24, "the window spent more than its budget: \(text)")
    }

    @Test func aWordAtTheStartKeepsRightHandContext() {
        let sentence = "Hold that view about the quiet river."
        let runs = HistoryPreview.context(sentence: sentence, span: Self.span(of: "Hold", in: sentence),
                                          cut: 0, budget: 16)
        #expect(Self.word(runs) == "Hold")
        let text = Self.joined(runs)
        #expect(!text.hasPrefix("…"), "nothing was cut at the start: \(text)")
        #expect(text.hasSuffix("…"), "the end was cut: \(text)")
    }

    @Test func aWordAtTheEndKeepsLeftHandContext() {
        let sentence = "They quietly hold"
        let runs = HistoryPreview.context(sentence: sentence, span: Self.span(of: "hold", in: sentence),
                                          cut: 0, budget: 16)
        #expect(Self.word(runs) == "hold")
        let text = Self.joined(runs)
        #expect(text.hasPrefix("…"), "the start was cut: \(text)")
        #expect(!text.hasSuffix("…"), "nothing was cut at the end: \(text)")
    }

    @Test func aShortSentenceIsShownWhole() {
        let sentence = "Hold it."
        let runs = HistoryPreview.context(sentence: sentence, span: Self.span(of: "Hold", in: sentence),
                                          cut: 0, budget: 64)
        #expect(Self.joined(runs) == sentence)
        #expect(Self.word(runs) == "Hold")
    }

    @Test func cjkAndEmojiUseUTF16Spans() {
        let cjk = "他们 hold 这个观点。"
        let cjkRuns = HistoryPreview.context(sentence: cjk, span: Self.span(of: "hold", in: cjk), cut: 0, budget: 32)
        #expect(Self.word(cjkRuns) == "hold")
        #expect(Self.joined(cjkRuns).contains("他们"), "the left-hand CJK stayed: \(Self.joined(cjkRuns))")

        let emoji = "They 😀 hold 😀 it."
        let emojiRuns = HistoryPreview.context(sentence: emoji, span: Self.span(of: "hold", in: emoji), cut: 0,
                                               budget: 32)
        #expect(Self.word(emojiRuns) == "hold")
        #expect(Self.joined(emojiRuns).contains("😀"), "the surrogate pair survived: \(Self.joined(emojiRuns))")
    }

    @Test func aSpanOutsideTheSentenceIsClampedAndNeverCrashes() {
        let sentence = "They hold that view."
        let runs = HistoryPreview.context(sentence: sentence, span: LedgerSpan(start: 100, len: 10), cut: 0,
                                          budget: 12)
        #expect(Self.word(runs) == nil)
        #expect(Self.joined(runs) == "They hold th…")
    }

    /// **A span that falls inside a grapheme names no word and never traps** (audit 2026-10-31): "𝄞" is one character
    /// of two UTF-16 units, and offset 2 is inside it. The expanded sentence and the resting window share the check.
    @Test func aSpanInsideAGraphemeNamesNoWordAndCannotTrap() {
        let sentence = "a𝄞b"
        let inside = LedgerSpan(start: 2, len: 1)
        let runs = HistoryPreview.context(sentence: sentence, span: inside, cut: 0, budget: 10)
        #expect(Self.word(runs) == nil)
        #expect(Self.joined(runs) == "a𝄞b")
        #expect(HistoryRuns.runs(sentence: sentence, span: inside, cut: 0) == [.text("a𝄞b")])
    }

    @Test func cutEndsShowOneEllipsisEach() {
        let sentence = "Hold that view about the quiet river."
        let span = Self.span(of: "Hold", in: sentence)

        let startCut = HistoryPreview.context(sentence: sentence, span: span, cut: 1, budget: 64)
        #expect(Self.joined(startCut).hasPrefix("…"))
        #expect(Self.joined(startCut).filter { $0 == "…" }.count == 1)

        let endCut = HistoryPreview.context(sentence: sentence, span: span, cut: 2, budget: 12)
        let text = Self.joined(endCut)
        #expect(text.hasSuffix("…"))
        // The window also clipped the end; the capture's end mark must not add a second one.
        #expect(text.filter { $0 == "…" }.count == 1, "a double end ellipsis: \(text)")
    }

    @Test func aLongWordIsNeverDropped() {
        let sentence = "They pneumonoultramicroscopicsilicovolcanoconiosis here."
        let runs = HistoryPreview.context(sentence: sentence,
                                          span: Self.span(of: "pneumonoultramicroscopicsilicovolcanoconiosis",
                                                          in: sentence),
                                          cut: 0, budget: 8)
        #expect(Self.word(runs) == "pneumonoultramicroscopicsilicovolcanoconiosis")
    }

    @Test func anEmptySentenceHasNoRuns() {
        #expect(HistoryPreview.context(sentence: "", span: nil, cut: 0).isEmpty)
    }
}

/// **The card's content, precedence included** (ADR-0037): the reader's answer first, the recorded edition's gloss
/// second, nothing third; the lemma only when the dictionary's form differs; the times and the provenance unchanged.
struct HistoryCardContentTests {
    static func reading(surface: String = "hold", lemma: String = "hold", sentence: String = "They hold that view.",
                        span: LedgerSpan? = LedgerSpan(start: 5, len: 4), cut: UInt8 = 0,
                        dictionary: String = "Tiny") -> LedgerReading {
        LedgerReading(surface: surface, lemma: lemma, sentence: sentence, span: span, cut: cut, quality: "complete",
                      edition: "mdx-sha256-v1:ab", entryKey: "hold", occurrence: 0, dictionaryName: dictionary,
                      language: "en", at: 1_790_641_800, device: "d")
    }

    static func card(_ reading: LedgerReading, times: UInt32 = 1) -> LedgerCard {
        LedgerCard(reading: reading, times: times, events: ["e1"])
    }

    @Test func anAIGlossWinsAndKeepsTheDictionarysPartOfSpeech() {
        let dictionary = HistoryCardGloss(text: "to keep; to maintain", pos: "verb", source: .dictionary)
        let content = HistoryCardContent(card: Self.card(Self.reading()), answer: "Here, to maintain a view.",
                                         dictionaryGloss: dictionary)
        #expect(content.gloss == HistoryCardGloss(text: "Here, to maintain a view.", pos: "verb", source: .ai))
    }

    @Test func theDictionaryGlossShowsWhenTheReaderHasNotAsked() {
        let dictionary = HistoryCardGloss(text: "to keep; to maintain", pos: "verb", source: .dictionary)
        let content = HistoryCardContent(card: Self.card(Self.reading()), answer: nil, dictionaryGloss: dictionary)
        #expect(content.gloss == dictionary)
    }

    @Test func noGlossWhenNeitherSourceHasOne() {
        let content = HistoryCardContent(card: Self.card(Self.reading()), answer: nil, dictionaryGloss: nil)
        #expect(content.gloss == nil)
    }

    @Test func anEmptyAnswerIsNotAGloss() {
        let dictionary = HistoryCardGloss(text: "to keep", source: .dictionary)
        let content = HistoryCardContent(card: Self.card(Self.reading()), answer: "", dictionaryGloss: dictionary)
        #expect(content.gloss == dictionary)
    }

    @Test func theLemmaShowsOnlyWhenTheDictionarysFormDiffers() {
        let inflected = Self.reading(surface: "holding", lemma: "hold")
        #expect(HistoryCardContent(card: Self.card(inflected), answer: nil, dictionaryGloss: nil).lemma == "hold")
        #expect(HistoryCardContent(card: Self.card(Self.reading()), answer: nil, dictionaryGloss: nil).lemma == nil)
        let unknown = Self.reading(surface: "nimbus", lemma: "")
        #expect(HistoryCardContent(card: Self.card(unknown), answer: nil, dictionaryGloss: nil).lemma == nil)
    }

    @Test func theContextIsThePreviewAndTheTimesAndProvenanceAreKept() {
        let reading = Self.reading()
        let content = HistoryCardContent(card: Self.card(reading, times: 3), answer: nil, dictionaryGloss: nil)
        #expect(content.context == HistoryPreview.context(sentence: reading.sentence, span: reading.span,
                                                          cut: reading.cut))
        #expect(content.word == "hold")
        #expect(content.dictionaryName == "Tiny")
        #expect(content.at == reading.at)
        #expect(content.times == 3)
    }

    @Test func theSpokenCardReadsItsFourLinesInOrder() {
        let dictionary = HistoryCardGloss(text: "to keep; to maintain", pos: "verb", source: .dictionary)
        let content = HistoryCardContent(card: Self.card(Self.reading(surface: "holding", lemma: "hold"), times: 3),
                                         answer: "Here, to maintain a view.", dictionaryGloss: dictionary)
        #expect(content.spoken(context: "I brought an apple for lunch.", time: "8:31 AM")
            == "holding as hold ×3\nverb AI answer Here, to maintain a view.\nI brought an apple for lunch.\nTiny\n8:31 AM")
    }

    @Test func aCardWithNoGlossOrContextSpeaksTheRest() {
        let content = HistoryCardContent(card: Self.card(Self.reading(surface: "nimbus", lemma: "")),
                                         answer: nil, dictionaryGloss: nil)
        #expect(content.spoken(context: "", time: "9:00 AM") == "nimbus\nTiny\n9:00 AM")
    }

    @Test func anEmptyDictionaryNameIsSpokenAsUnknown() {
        let content = HistoryCardContent(card: Self.card(Self.reading(dictionary: "")),
                                         answer: nil, dictionaryGloss: nil)
        #expect(content.spoken(context: "They hold that view.", time: "9:00 AM")
            == "hold\nThey hold that view.\nUnknown dictionary\n9:00 AM")
    }
}

/// **The card's spoken context** (plan item 7): the styled preview and sentence runs flattened to the one string a
/// screen reader hears, cut marks included. The accessibility representation consumes this; a dropped run would lose
/// part of the sentence without any visual change.
struct HistoryRunsPlainTests {
    @Test func everyPartIsKeptInOrderIncludingTheCutMarks() {
        let runs: [HistoryRuns.Run] = [.text("…"), .text("I brought an "), .word("apple"), .text(" for lunch.")]
        #expect(HistoryRuns.plain(runs) == "…I brought an apple for lunch.")
    }

    @Test func anEmptyPreviewSpeaksNothing() {
        #expect(HistoryRuns.plain([]) == "")
    }
}
