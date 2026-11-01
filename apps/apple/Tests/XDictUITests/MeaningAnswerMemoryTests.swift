import Foundation
import Testing
import XDictAI
import XDictContract
@testable import XDictUI

/// **The reader's answers, in memory only** (ADR-0037): the exact reading is the key; a different sentence, edition,
/// occurrence, term, span or cut never reuses one; only a meaning answer is kept; the latest valid one wins; a failed
/// ask never evicts it; the memory forgets what the reader removed and describes nothing.
@MainActor
struct MeaningAnswerMemoryTests {
    static let edition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32))
    static let entry = EntryRef(edition: edition, key: "hold", occurrence: 0)
    static let dictionary = DictId(rawValue: "1a2b3c4d00000001")
    static let sentence = "They hold that view about the quiet river."
    static let range = NSRange(location: 5, length: 4)
    static let answerText = "Here, to maintain a view."

    static func sent(mode: AIMode = .grounded, sentence: String = sentence, range: NSRange? = range,
                     phrase: String? = nil, edition: Edition = edition, key: String = "hold",
                     occurrence: UInt32 = 0, term: String = "hold") -> MeaningSent {
        let target = MeaningTarget(dictionary: dictionary,
                                   entry: EntryRef(edition: edition, key: key, occurrence: occurrence))
        return MeaningSent(text: "question", mode: mode, source: .http, complete: true, cutAt: 0,
                           questionContext: MeaningContext(term: term, sentence: sentence, range: range, phrase: phrase),
                           // What the request sent, and the reading it belongs to: a sentence-only request sends no
                           // entry and still names the card.
                           target: mode.carriesEntry ? target : nil, reading: target)
    }

    static func reading(surface: String = "hold", sentence: String = sentence, edition: Edition = edition,
                        key: String = "hold", occurrence: UInt32 = 0,
                        span: LedgerSpan? = LedgerSpan(start: 5, len: 4), cut: UInt8 = 0) -> LedgerReading {
        LedgerReading(surface: surface, lemma: "hold", sentence: sentence, span: span, cut: cut, quality: "complete",
                      edition: edition.rawValue, entryKey: key, occurrence: occurrence, dictionaryName: "Tiny",
                      language: "en", at: 1_790_641_800, device: "d")
    }

    static func state(_ outcome: AIOutcome = .matched, mode: AIMode = .grounded,
                      text: String = answerText) -> MeaningSession.State {
        .answer(AIAnswer(outcome: outcome, quotes: [], explanation: text), mode: mode)
    }

    @Test func aMeaningAnswerIsKeptForItsExactReading() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        #expect(memory.answer(for: Self.reading()) == Self.answerText)
    }

    @Test func anotherSentenceIsNotTheSameReading() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        #expect(memory.answer(for: Self.reading(sentence: "Another sentence entirely.")) == nil)
    }

    @Test func anotherEditionOccurrenceOrWordIsNotTheSameReading() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        let otherEdition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "cd", count: 32))
        #expect(memory.answer(for: Self.reading(edition: otherEdition)) == nil)
        #expect(memory.answer(for: Self.reading(occurrence: 1)) == nil)
        #expect(memory.answer(for: Self.reading(surface: "held")) == nil)
    }

    @Test func anotherSpanOrCutIsNotTheSameReading() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        #expect(memory.answer(for: Self.reading(span: LedgerSpan(start: 5, len: 5))) == nil)
        #expect(memory.answer(for: Self.reading(cut: 2)) == nil)
        #expect(memory.answer(for: Self.reading(span: nil)) == nil)
    }

    @Test func aTranslationAGrammarReadingOrASenseVerdictIsNotAGloss() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(.translated, mode: .translate), sent: Self.sent(mode: .translate))
        #expect(memory.answer(for: Self.reading()) == nil)
        memory.publish(Self.state(.matched, mode: .explainGrammar), sent: Self.sent(mode: .explainGrammar))
        #expect(memory.answer(for: Self.reading()) == nil)
        memory.publish(Self.state(.explained, mode: .explainSense), sent: Self.sent(mode: .explainSense))
        #expect(memory.answer(for: Self.reading()) == nil)
    }

    @Test func aRefusalOrAnAmbiguityIsNotAGloss() {
        let memory = MeaningAnswerMemory()
        for outcome in [AIOutcome.refused, .doesNotFit, .ambiguous, .noMatchingSense, .guardrail, .insufficientContext] {
            memory.publish(Self.state(outcome), sent: Self.sent())
            #expect(memory.answer(for: Self.reading()) == nil, "\(outcome) became a gloss")
        }
    }

    @Test func aSentenceOnlyAnswerIsAcceptedBecauseTheSwitchDefaultsOff() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(.explanationOnly, mode: .sentenceOnly),
                       sent: Self.sent(mode: .sentenceOnly, range: Self.range))
        #expect(memory.answer(for: Self.reading()) == Self.answerText)
    }

    @Test func aPhraseAnswerIsNotThisWordsReading() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent(phrase: "hold that view"))
        #expect(memory.answer(for: Self.reading()) == nil)
    }

    @Test func theLatestValidAnswerReplacesTheEarlier() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(text: "the first"), sent: Self.sent())
        memory.publish(Self.state(text: "the second"), sent: Self.sent())
        #expect(memory.answer(for: Self.reading()) == "the second")
    }

    @Test func aFailedAskKeepsTheLastAnswer() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(text: "the good one"), sent: Self.sent())
        memory.publish(.invalid(.shape), sent: Self.sent())
        memory.publish(.unavailable(.noContext), sent: Self.sent())
        memory.publish(.cancelled, sent: Self.sent())
        #expect(memory.answer(for: Self.reading()) == "the good one")
    }

    @Test func aRemovedReadingForgetsItsAnswer() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        memory.forget(Self.reading())
        #expect(memory.answer(for: Self.reading()) == nil)
    }

    @Test func theHistorySwitchedOffClearsEverything() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        memory.clear()
        #expect(memory.answer(for: Self.reading()) == nil)
    }

    /// **A clear invalidates an ask already on its way** (audit 2026-10-31): an answer published under the epoch the ask
    /// began in is not stored once the reader erased or turned history off.
    @Test func anAnswerStartedBeforeAClearIsNotStored() {
        let memory = MeaningAnswerMemory()
        let epoch = memory.epoch
        memory.clear()
        memory.publish(Self.state(), sent: Self.sent(), epoch: epoch)
        #expect(memory.answer(for: Self.reading()) == nil)
        memory.publish(Self.state(), sent: Self.sent(), epoch: memory.epoch)
        #expect(memory.answer(for: Self.reading()) == Self.answerText)
    }

    /// **A removal invalidates an ask already on its way**: the hidden reading's answer is never stored after the
    /// reader removed the card.
    @Test func anAnswerStartedBeforeARemovalIsNotStored() {
        let memory = MeaningAnswerMemory()
        let epoch = memory.epoch
        memory.forget(Self.reading())
        memory.publish(Self.state(), sent: Self.sent(), epoch: epoch)
        #expect(memory.answer(for: Self.reading()) == nil)
    }

    /// **The history switch gates storage**: with history off nothing is kept, whatever the ask's epoch.
    @Test func theHistorySwitchOffStoresNothing() {
        let memory = MeaningAnswerMemory()
        memory.isHistoryEnabled = { false }
        memory.publish(Self.state(), sent: Self.sent(), epoch: memory.epoch)
        #expect(memory.answer(for: Self.reading()) == nil)
        memory.isHistoryEnabled = { true }
        memory.publish(Self.state(), sent: Self.sent(), epoch: memory.epoch)
        #expect(memory.answer(for: Self.reading()) == Self.answerText)
    }

    @Test func theOldestAnswerLeavesAtTheBound() {
        let memory = MeaningAnswerMemory()
        for index in 0...MeaningAnswerMemory.capacity {
            let sentence = "Sentence \(index)."
            memory.publish(Self.state(text: "answer \(index)"), sent: Self.sent(sentence: sentence, range: nil))
        }
        #expect(memory.answer(for: Self.reading(sentence: "Sentence 0.", span: nil)) == nil,
                "the oldest reading's answer was not evicted")
        #expect(memory.answer(for: Self.reading(sentence: "Sentence \(MeaningAnswerMemory.capacity).", span: nil))
                == "answer \(MeaningAnswerMemory.capacity)")
    }

    @Test func descriptionsNameNoSentenceOrAnswer() {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(text: "private generated explanation"), sent: Self.sent())
        for line in [String(describing: memory), String(reflecting: memory), memory.debugDescription] {
            #expect(!line.contains("quiet river"), "the sentence reached a description: \(line)")
            #expect(!line.contains("private generated explanation"), "the answer reached a description: \(line)")
        }
        #expect(Mirror(reflecting: memory).children.isEmpty, "dump would walk into the answers")
    }

    @Test func theMemoryCanBeDescribedOffTheMainActor() async {
        let memory = MeaningAnswerMemory()
        memory.publish(Self.state(), sent: Self.sent())
        let (described, empty) = await Task.detached {
            (String(describing: memory), Mirror(reflecting: memory).children.isEmpty)
        }.value
        #expect(described == "MeaningAnswerMemory")
        #expect(empty)
    }
}
