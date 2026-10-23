import Foundation
import Testing
import XDictAI
import XDictTestSupport
import XDictUI

/// **Every answer-pane state, and what it says** (plan-ai-meaning WI-6; ADR-0021 d.2, d.3): source, grounding, outcome,
/// coverage, the quoted sense and its explanation, or the typed reason nothing came back. The sentences are the view
/// layer's, in both catalogues; the model only hands kinds.
struct MeaningPresenterTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    static let settings = MeaningSettings(source: .claudeCLI, sendEntryText: true, language: "en")

    static func sent(complete: Bool = true, cutAt: UInt64 = 200) -> MeaningSent {
        MeaningSent(text: "composed", mode: .grounded, source: .claudeCLI, complete: complete, cutAt: cutAt)
    }

    static func answer(_ outcome: AIOutcome, _ quotes: [String], _ explanation: String = "It means that here.",
                       mode: AIMode = .grounded) -> MeaningSession.State {
        .answer(AIAnswer(outcome: outcome, quotes: quotes, explanation: explanation), mode: mode)
    }

    @Test func aGroundedAnswerCarriesItsSourceSenseAndQuote() {
        let shown = MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings, sent: Self.sent())
        let presentation = shown ?? Self.missing()
        #expect(Self.text(presentation.source ?? "none") == "Claude")
        #expect(presentation.grounding == .grounded)
        #expect(Self.text(presentation.outcome ?? "none") == "Chose a sense from the entry")
        #expect(presentation.quotes == ["to keep"])
        #expect(presentation.explanation == "It means that here.")
        #expect(presentation.coverage == nil)
        #expect(presentation.problem == nil)
        #expect(Self.text(Self.grounding(presentation) ?? "") == "Uses this dictionary entry")
    }

    @Test func anUngroundedAnswerSaysSo() {
        let sentenceOnly = MeaningSession.State.answer(
            AIAnswer(outcome: .explanationOnly, quotes: [], explanation: "It likely means to keep."), mode: .sentenceOnly)
        let presentation = MeaningPresenter.present(sentenceOnly, settings: Self.settings, sent: Self.sent()) ?? Self.missing()
        #expect(presentation.grounding == .ungrounded)
        #expect(Self.text(Self.grounding(presentation) ?? "") == "Uses only the sentence")
        #expect(Self.text(presentation.outcome ?? "none") == "From the sentence alone")
        // A sentence-only ask has no entry, so nothing to be partial about.
        #expect(presentation.coverage == nil)
    }

    @Test func twoQuotesAreAmbiguous() {
        let presentation = MeaningPresenter.present(Self.answer(.ambiguous, ["to keep", "to contain"]),
                                                    settings: Self.settings, sent: Self.sent()) ?? Self.missing()
        #expect(presentation.quotes == ["to keep", "to contain"])
        #expect(Self.text(presentation.outcome ?? "none") == "More than one sense")
    }

    @Test func aPartialEntryIsSaidOnTheAnswer() {
        let presentation = MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings,
                                                    sent: Self.sent(complete: false, cutAt: 4096)) ?? Self.missing()
        #expect(presentation.coverage != nil)
        #expect(Self.text(presentation.coverage ?? "none")
            == "Part of this entry could not be read, so the answer may be missing something.")
    }

    @Test func aRefusedAnswerIsAProblemWithItsOutcome() {
        let presentation = MeaningPresenter.present(Self.answer(.refused, []), settings: Self.settings, sent: Self.sent())
            ?? Self.missing()
        #expect(Self.text(presentation.outcome ?? "none") == "The model declined")
        #expect(presentation.quotes.isEmpty)
        #expect(presentation.problem == nil, "the model answered; the answer is the refusal")
    }

    @Test func aGuardrailOutcomeIsAProblemWithItsOutcome() {
        let presentation = MeaningPresenter.present(Self.answer(.guardrail, []), settings: Self.settings, sent: Self.sent())
            ?? Self.missing()
        #expect(Self.text(presentation.outcome ?? "none") == "The model's guardrails declined")
    }

    @Test func aGuardrailFailureFromTheSourceIsAProblem() {
        let state = MeaningSession.State.unavailable(.provider(.guardrail))
        let presentation = MeaningPresenter.present(state, settings: Self.settings, sent: Self.sent()) ?? Self.missing()
        #expect(presentation.isProblem)
        #expect(Self.text(presentation.problem ?? "none") == "The model's guardrails declined to answer this.")
        #expect(presentation.code == "provider.guardrail")
    }

    @Test func noSourceSaysWhereToChooseOne() {
        let state = MeaningSession.State.unavailable(.noSource)
        let presentation = MeaningPresenter.present(state, settings: .off, sent: nil) ?? Self.missing()
        #expect(presentation.isProblem)
        #expect(Self.text(presentation.problem ?? "none") == "Choose a source in Settings ▸ AI.")
        #expect(presentation.source == nil)
    }

    @Test func everyUnavailableStateHasASentence() {
        for state in [MeaningSession.State.unavailable(.noContext), .unavailable(.noEntry),
                      .unavailable(.entryUnreadable), .unavailable(.provider(.notSignedIn))] {
            let presentation = MeaningPresenter.present(state, settings: Self.settings, sent: nil) ?? Self.missing()
            #expect(presentation.isProblem)
            #expect(Self.text(presentation.problem ?? "") != "the catalog did not compile")
        }
    }

    @Test func anInvalidAnswerKeepsItsStableCode() {
        let presentation = MeaningPresenter.present(.invalid(.quoteNotFound), settings: Self.settings,
                                                    sent: Self.sent()) ?? Self.missing()
        #expect(presentation.isProblem)
        #expect(presentation.code == "answer.quote.notFound")
        #expect(Self.text(presentation.problem ?? "") == "The source's answer did not pass XDict's check.")
    }

    @Test func aBrokenTemplateNamesWhatIsWrong() {
        let presentation = MeaningPresenter.present(.template(.missingPlaceholder("entry")), settings: Self.settings,
                                                    sent: nil) ?? Self.missing()
        #expect(presentation.code == "template.missingPlaceholder")
        #expect(Self.text(presentation.problem ?? "") == "The prompt must include {entry}.")
    }

    @Test func idleAndAskingAreNotPresented() {
        #expect(MeaningPresenter.present(.idle, settings: Self.settings, sent: nil) == nil)
        #expect(MeaningPresenter.present(.asking, settings: Self.settings, sent: nil) == nil)
    }

    @Test func thePaneSaysItInChinese() {
        let presentation = MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings,
                                                    sent: Self.sent()) ?? Self.missing()
        #expect(Self.text(presentation.outcome ?? "", "zh-Hans") == "从词条中选了一个义项")
        #expect(Self.text(Self.grounding(presentation) ?? "", "zh-Hans") == "使用此词条")
    }

    /// The grounding label as one resource; the view shows it beside the outcome.
    static func grounding(_ presentation: MeaningPresentation) -> LocalizedStringResource? {
        MeaningSentences.grounding(presentation.grounding)
    }

    static func missing() -> MeaningPresentation {
        Issue.record("no presentation")
        return MeaningPresentation(source: nil, grounding: .none, outcome: nil, coverage: nil, quotes: [],
                                   explanation: "", problem: nil, code: nil)
    }
}
