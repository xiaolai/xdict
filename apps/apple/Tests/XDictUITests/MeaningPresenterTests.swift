import Foundation
import Testing
import XDictAI
import XDictClient
import XDictContract
import XDictTestSupport
import XDictUI

/// **Every answer-pane state, and what it says** (plan-ai-meaning WI-6; ADR-0021 d.2, d.3): source, grounding, outcome,
/// coverage, the quoted sense and its explanation, or the typed reason nothing came back. The sentences are the view
/// layer's, in both catalogues; the model only hands kinds.
struct MeaningPresenterTests {
    /// **A catalog that cannot compile fails its test** (audit round 2, 2026-10-25): `try?` here turned a broken or
    /// missing translation into a generic string mismatch.
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") throws -> String {
        try CompiledCatalog.text(resource, in: language)
    }

    static let settings = MeaningSettings(source: .claudeCLI, sendEntryText: true, language: "en")

    static func sent(complete: Bool = true, cutAt: UInt64 = 200) -> MeaningSent {
        MeaningSent(text: "composed", mode: .grounded, source: .claudeCLI, complete: complete, cutAt: cutAt)
    }

    static func answer(_ outcome: AIOutcome, _ quotes: [String], _ explanation: String = "It means that here.",
                       mode: AIMode = .grounded) -> MeaningSession.State {
        .answer(AIAnswer(outcome: outcome, quotes: quotes, explanation: explanation), mode: mode)
    }

    @Test func aGroundedAnswerCarriesItsSourceSenseAndQuote() throws {
        let shown = MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings, sent: Self.sent())
        let presentation = try #require(shown)
        #expect(try Self.text(presentation.source ?? "none") == "Claude")
        #expect(presentation.grounding == .grounded)
        #expect(try Self.text(presentation.outcome ?? "none") == "Chose a sense from the entry")
        #expect(presentation.quotes == ["to keep"])
        #expect(presentation.explanation == "It means that here.")
        #expect(presentation.coverage == nil)
        #expect(presentation.problem == nil)
        #expect(try Self.text(Self.grounding(presentation) ?? "") == "Uses this dictionary entry")
    }

    @Test func anUngroundedAnswerSaysSo() throws {
        let sentenceOnly = MeaningSession.State.answer(
            AIAnswer(outcome: .explanationOnly, quotes: [], explanation: "It likely means to keep."), mode: .sentenceOnly)
        let presentation = try #require(MeaningPresenter.present(sentenceOnly, settings: Self.settings, sent: Self.sent()))
        #expect(presentation.grounding == .ungrounded)
        #expect(try Self.text(Self.grounding(presentation) ?? "") == "Uses only the sentence")
        #expect(try Self.text(presentation.outcome ?? "none") == "From the sentence alone")
        // A sentence-only ask has no entry, so nothing to be partial about — even when the request itself was cut
        // (audit round 2, 2026-10-25).
        #expect(presentation.coverage == nil)
        let cut = try #require(MeaningPresenter.present(sentenceOnly, settings: Self.settings,
                                           sent: Self.sent(complete: false, cutAt: 4096)))
        #expect(cut.coverage == nil, "a sentence-only answer named a cut entry")
    }

    @Test func twoQuotesAreAmbiguous() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.ambiguous, ["to keep", "to contain"]),
                                                    settings: Self.settings, sent: Self.sent()))
        #expect(presentation.quotes == ["to keep", "to contain"])
        #expect(try Self.text(presentation.outcome ?? "none") == "More than one sense")
    }

    @Test func aPartialEntryIsSaidOnTheAnswer() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings,
                                                    sent: Self.sent(complete: false, cutAt: 4096)))
        #expect(presentation.coverage != nil)
        #expect(try Self.text(presentation.coverage ?? "none")
            == "Part of this entry could not be read, so the answer may be missing something.")
    }

    @Test func aRefusedAnswerIsAnAnswerWithItsOutcome() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.refused, []), settings: Self.settings, sent: Self.sent()))
        #expect(try Self.text(presentation.outcome ?? "none") == "The model declined")
        #expect(presentation.quotes.isEmpty)
        #expect(!presentation.isProblem, "the model answered; the answer is the refusal")
    }

    @Test func aGuardrailOutcomeIsAnAnswerWithItsOutcome() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.guardrail, []), settings: Self.settings, sent: Self.sent()))
        #expect(try Self.text(presentation.outcome ?? "none") == "The model's guardrails declined")
        #expect(!presentation.isProblem, "a guardrail outcome is the model's answer, not a failure")
    }

    @Test func aGuardrailFailureFromTheSourceIsAProblem() throws {
        let state = MeaningSession.State.unavailable(.provider(.guardrail))
        let presentation = try #require(MeaningPresenter.present(state, settings: Self.settings, sent: Self.sent()))
        #expect(presentation.isProblem)
        #expect(try Self.text(presentation.problem ?? "none") == "The model's guardrails declined to answer this.")
        #expect(presentation.code == "provider.guardrail")
    }

    @Test func noSourceSaysWhereToChooseOne() throws {
        let state = MeaningSession.State.unavailable(.noSource)
        let presentation = try #require(MeaningPresenter.present(state, settings: .off, sent: nil))
        #expect(presentation.isProblem)
        #expect(try Self.text(presentation.problem ?? "none") == "Choose a source in Settings ▸ AI.")
        #expect(presentation.source == nil)
    }

    /// **The entry's own failure decides the next step** (audit finding, 2026-10-25): a transport interruption or a
    /// superseded call is worth another ask; a file the service cannot open, or one that now needs an import, is not a
    /// button that would loop.
    @Test func anEntryFailureOffersARetryOnlyWhereItCanHelp() throws {
        // **A failure with no presentation is a failure of the test** (audit round 2, 2026-10-25): optional chaining
        // used to pass a missing presentation off as "nothing to offer".
        func recovery(_ unavailable: MeaningSession.Unavailable) throws -> MeaningRecovery? {
            let presentation = try #require(MeaningPresenter.present(.unavailable(unavailable), settings: Self.settings,
                                                                     sent: nil), "no presentation")
            return presentation.recovery
        }
        #expect(try recovery(.entryFailure(.wire(.interrupted))) == .retry)
        #expect(try recovery(.entryFailure(.superseded)) == .retry)
        #expect(try recovery(.entryFailure(.fileUnavailable(file: UUID(), errno: 2))) == nil)
        #expect(try recovery(.entryFailure(.reopenNeedsImport(dict: DictId(rawValue: "1a2b3c4d00000001"),
                                                             reason: .changed))) == nil)
        #expect(try recovery(.entryFailure(.needsFiles)) == nil)
    }

    @Test func everyUnavailableStateHasASentence() throws {
        // **Every case, not a representative four** (audit round 3, 2026-10-25).
        let states: [MeaningSession.Unavailable] = [
            .noSource, .noContext, .noEntry, .entryFailure(.wire(.interrupted)), .entryFailure(.superseded),
            .consentChanged, .noSense, .entryTextOff, .provider(.unauthorised), .provider(.guardrail),
        ]
        for unavailable in states {
            let presentation = try #require(MeaningPresenter.present(.unavailable(unavailable), settings: Self.settings,
                                                                     sent: nil))
            #expect(presentation.isProblem, "\(unavailable) is not a problem")
            let sentence = try Self.text(try #require(presentation.problem))
            #expect(!sentence.isEmpty, "\(unavailable) has no sentence")
        }
    }

    @Test func anInvalidAnswerKeepsItsStableCode() throws {
        let presentation = try #require(MeaningPresenter.present(.invalid(.quoteNotFound), settings: Self.settings,
                                                    sent: Self.sent()))
        #expect(presentation.isProblem)
        #expect(presentation.code == "answer.quote.notFound")
        #expect(try Self.text(presentation.problem ?? "") == "The source's answer did not pass XDict's check.")
    }

    /// **The note a save writes** (plan-companion WI-9; owner, 2026-10-25): the explanation, each quote in the pane's
    /// quotation marks, then a provenance line naming the source, the model and the day; the sentence never goes in.
    @Test func theSavedNoteIsTheExplanationItsQuotesAndItsProvenance() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.matched, ["to keep"]),
                                                                 settings: Self.settings, sent: Self.sent()))
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 25
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        // **The presentation's own facts carry the source and the model** (audit round 4, 2026-10-25).
        let sourced = MeaningPresentation(facts: MeaningRequestFacts(source: MeaningSentences.source(.claudeCLI),
                                                                    model: "a-model"),
                                          grounding: presentation.grounding, outcome: presentation.outcome,
                                          coverage: nil, quotes: presentation.quotes,
                                          explanation: presentation.explanation, problem: nil, code: nil)
        let text = MeaningPresenter.noteText(presentation: sourced, date: date) { resource in
            (try? CompiledCatalog.text(resource, in: "en")) ?? "<missing text>"
        }
        let lines = text.components(separatedBy: "\n")
        try #require(lines.count == 3, "the note is not three parts: \(text)")
        #expect(lines[0] == "It means that here.")
        #expect(lines[1] == "“to keep”")
        // The whole provenance is the catalog's sentence, with this source, model and day.
        let source = try Self.text(try #require(MeaningSentences.source(.claudeCLI)))
        let provenance = MeaningSentences.noteProvenance(source: source, model: "a-model", day: "2026-10-25")
        #expect(lines[2] == (try Self.text(provenance)))
    }

    /// **Copy Answer is the explanation and its quotes as text** (plan-companion WI-10): each quote its own paragraph,
    /// quotation marks the pane's own, nothing that is not shown.
    @Test func theCopiedAnswerIsTheExplanationAndItsQuotes() throws {
        let withQuotes = try #require(MeaningPresenter.present(Self.answer(.ambiguous, ["to keep", "to hold"]), settings: Self.settings,
                                                  sent: Self.sent()))
        #expect(withQuotes.copyText == "It means that here.\n\n“to keep”\n\n“to hold”")
        let without = try #require(MeaningPresenter.present(Self.answer(.explanationOnly, []), settings: Self.settings,
                                               sent: Self.sent()))
        #expect(without.copyText == "It means that here.")
        let empty = try #require(MeaningPresenter.present(Self.answer(.explained, [], ""), settings: Self.settings,
                                             sent: Self.sent()))
        #expect(empty.copyText == "", "an empty answer copies nothing, not a stray blank line")
    }

    @Test func aBrokenTemplateNamesWhatIsWrong() throws {
        let presentation = try #require(MeaningPresenter.present(.template(.missingPlaceholder("entry")), settings: Self.settings,
                                                    sent: nil))
        #expect(presentation.code == "template.missingPlaceholder")
        #expect(try Self.text(presentation.problem ?? "") == "The prompt must include {entry}.")
    }

    @Test func idleAndAskingAreNotPresented() throws {
        #expect(MeaningPresenter.present(.idle, settings: Self.settings, sent: nil) == nil)
        #expect(MeaningPresenter.present(.asking, settings: Self.settings, sent: nil) == nil)
    }

    @Test func thePaneSaysItInChinese() throws {
        let presentation = try #require(MeaningPresenter.present(Self.answer(.matched, ["to keep"]), settings: Self.settings,
                                                    sent: Self.sent()))
        #expect(try Self.text(presentation.outcome ?? "", "zh-Hans") == "从词条中选了一个义项")
        #expect(try Self.text(Self.grounding(presentation) ?? "", "zh-Hans") == "使用此词条")
    }

    /// The grounding label as one resource; the view shows it beside the outcome.
    static func grounding(_ presentation: MeaningPresentation) -> LocalizedStringResource? {
        MeaningSentences.grounding(presentation.grounding)
    }}
