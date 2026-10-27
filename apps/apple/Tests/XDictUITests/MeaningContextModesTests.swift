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
            // **The tab is the ask** (owner, 2026-10-26): choosing the question sends it.
            session.choose(.translation)
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

    @Test func askingTheSameQuestionAgainSendsAgain() async {
        // **No cache** (plan-context-tools D7): another ask is another operation, so a stale answer can never be served
        // and nothing rests on disk. Choosing the question it already answered shows that answer instead.
        let provider = StubProvider(answers: [.success(Self.translation)])
        let (session, _, _) = MeaningSessionTests.session(provider: provider)
        session.choose(.translation)
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        let before = session.settled
        session.ask()
        #expect(await MeaningSessionTests.waitUntil { session.settled > before }, "the second ask never finished")
        guard case .answer = session.state else {
            Issue.record("the second ask produced no answer: \(session.state)")
            return
        }
        #expect(await provider.questions.count == 2, "a second ask is a second request")
        // The tab, though, shows what it already has: no third request.
        session.choose(.translation)
        #expect(await provider.questions.count == 2, "the chosen tab answers from its own result")
    }

    @Test func eachQuestionKeepsItsAnswerAndSwitchingBackSendsNothing() async {
        let provider = StubProvider(answers: [.success(MeaningSessionTests.matched), .success(Self.translation)])
        let (session, _, _) = MeaningSessionTests.session(provider: provider)
        session.choose(.meaning)
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        guard case .answer(_, let firstMode) = session.state else {
            Issue.record("no meaning answer: \(session.state)")
            return
        }
        #expect(firstMode != .translate)
        // Another question asks for itself…
        session.choose(.translation)
        #expect(await MeaningSessionTests.waitUntil { session.state != .asking })
        guard case .answer(_, let secondMode) = session.state else {
            Issue.record("no translation: \(session.state)")
            return
        }
        #expect(secondMode == .translate)
        // …and coming back shows the first answer again, untouched and unsent.
        let asked = await provider.questions.count
        session.choose(.meaning)
        guard case .answer(_, let backMode) = session.state else {
            Issue.record("the meaning answer did not come back: \(session.state)")
            return
        }
        #expect(backMode != .translate, "the answer of the question chosen before is the one shown")
        #expect(await provider.questions.count == asked, "switching back sends nothing")
        #expect(session.held != nil, "the sentence stays throughout")
    }

    @Test func withThePreferenceOnAChoosenQuestionPreviewsInsteadOfSending() async {
        let provider = StubProvider(answers: [.success(Self.translation)])
        let (session, _, _) = MeaningSessionTests.session(
            settings: MeaningSettings(source: .http, model: "m", sendEntryText: true, previewBeforeSending: true),
            provider: provider)
        let before = session.settled
        session.choose(.translation)
        #expect(await MeaningSessionTests.waitUntil { session.settled > before }, "the preview never composed")
        #expect(await provider.questions.isEmpty, "a preview sends nothing")
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
