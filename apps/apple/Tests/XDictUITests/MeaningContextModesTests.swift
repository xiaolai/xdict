import Foundation
import Testing
import XDictAI
import XDictClient
import XDictContract
import XDictSearch
import XDictUI

/// **Contract 6's two questions through the session** (plan-context-tools WI-7, WI-11): the pane's mode chooses the
/// question; neither sends the entry, so the disclosure switch neither gates nor enables them; a translation's sentence
/// is unmarked and its language is the target; changing the mode drops the answer and keeps the sentence.
@MainActor
struct MeaningContextModesTests {
    static let translation = #"{"outcome":"translated","translation":"他们持那种看法。","explanation":""}"#
    static let grammar = #"{"outcome":"explained","explanation":"The main verb is hold, in the imperative, and their view is its object."}"#

    @Test func aTranslationAsksWithoutTheEntryAndIgnoresTheSwitch() async {
        for switchOn in [false, true] {
            let provider = StubProvider(answers: [.success(Self.translation)])
            let (session, _, _) = MeaningSessionTests.session(
                settings: MeaningSettings(source: .http, model: "m", sendEntryText: switchOn,
                                          translationLanguage: "zh-Hans"),
                provider: provider)
            session.choose(.translation)
            session.ask()
            #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
            guard case .answer(let answer, let mode) = session.state else {
                Issue.record("no answer with the switch \(switchOn ? "on" : "off"): \(session.state)")
                return
            }
            #expect(mode == .translate)
            #expect(answer.translation == "他们持那种看法。")
            let questions = await provider.questions
            #expect(questions.count == 1)
            let question = questions.first ?? ""
            #expect(question.hasSuffix(AIComposer.translationResponseContract), "the translation's own contract closes it")
            #expect(!question.contains(MeaningSessionTests.entryText.text), "no entry goes, whatever the switch says")
            #expect(question.contains("They hold that view."), "the sentence is sent as it was captured")
            #expect(!question.contains("«hold»"), "a translation is not marked")
            #expect(question.contains("\"zh-Hans\""), "the target language is the question's language")
        }
    }

    @Test func aGrammarAskIsNotGatedByTheEntrySwitchAndMarksItsTerm() async {
        let provider = StubProvider(answers: [.success(Self.grammar)])
        let (session, _, _) = MeaningSessionTests.session(
            settings: MeaningSettings(source: .http, model: "m", sendEntryText: false), provider: provider)
        session.choose(.grammar)
        session.ask()
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        #expect(mode == .explainGrammar)
        #expect(answer.explanation.contains("imperative"))
        let question = await provider.questions.first ?? ""
        #expect(question.hasSuffix(AIComposer.grammarResponseContract))
        #expect(!question.contains(MeaningSessionTests.entryText.text), "grammar needs no entry")
        #expect(question.contains("«hold»"), "the reader's word is marked in its sentence")
        // **The system's reading is never part of the question** (ADR-0034 d.6): the tags are the pane's evidence, and the
        // composed bytes carry none of them.
        #expect(!question.contains("part-of-speech") && !question.contains("lemma"))
    }

    @Test func askingTheSameQuestionTwiceSendsTwoRequests() async {
        // **No cache** (plan-context-tools D7): the second tap is a second operation, so a stale or leaked answer can
        // never be served and nothing rests on disk.
        let provider = StubProvider(answers: [.success(Self.translation)])
        let (session, _, _) = MeaningSessionTests.session(provider: provider)
        session.choose(.translation)
        for attempt in 1...2 {
            let before = session.settled
            session.ask()
            #expect(await MeaningSessionTests.waitUntil { session.settled > before }, "ask \(attempt) never finished")
            guard case .answer = session.state else {
                Issue.record("ask \(attempt) produced no answer: \(session.state)")
                return
            }
        }
        #expect(await provider.questions.count == 2, "the second tap is a second request, never a cached answer")
    }

    @Test func changingTheModeDropsTheAnswerAndKeepsTheSentence() async {
        let provider = StubProvider(answers: [.success(MeaningSessionTests.matched)])
        let (session, _, _) = MeaningSessionTests.session(provider: provider)
        session.ask()
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        guard case .answer = session.state else {
            Issue.record("no answer to drop: \(session.state)")
            return
        }
        session.choose(.translation)
        #expect(session.state == .idle, "another mode's answer is not shown for this question")
        #expect(session.held != nil, "the sentence stays: switching modes is not the presentation's end")
        #expect(session.chosenMode == .translation)
        // The same mode again changes nothing at all.
        session.choose(.translation)
        #expect(session.chosenMode == .translation)
    }

    @Test func aPreviewOfATranslationShowsAndSendsTheTranslationsOwnBytes() async {
        let provider = StubProvider(answers: [.success(Self.translation)])
        let (session, _, _) = MeaningSessionTests.session(provider: provider)
        session.choose(.translation)
        let before = session.settled
        session.preview()
        #expect(await MeaningSessionTests.waitUntil { session.settled > before }, "the preview never composed")
        guard case .preview(let sent) = session.state else {
            Issue.record("no preview: \(session.state)")
            return
        }
        #expect(sent.mode == .translate)
        #expect(sent.text.hasSuffix(AIComposer.translationResponseContract))
        #expect(!sent.text.contains("«hold»"))
        #expect(sent.target == nil, "a translation has no entry to point at")
        session.sendPreview()
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer after Send: \(session.state)")
            return
        }
        #expect(mode == .translate && answer.translation == "他们持那种看法。")
        #expect(await provider.questions.first == sent.text, "Send transmits the previewed bytes themselves")
    }
}
