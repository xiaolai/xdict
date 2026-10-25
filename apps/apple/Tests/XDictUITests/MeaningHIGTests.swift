import Foundation
import Testing
import XDictAI
import XDictContract
import XDictEntryView
@testable import XDictUI

/// **The answer pane after the HIG audit of 2026-10-23** (UI04, UI09, UI11, UI12, UI15, UI19, UI20, UI23): the request
/// carries its own sentence and dictionary, a reader's incidental click on another sense keeps a finished answer
/// labelled with the sense it was about, each recoverable failure names its next step, and the words claim no more
/// certainty than the pipeline establishes.
@MainActor
struct MeaningHIGTests {
    typealias Base = MeaningSessionTests

    static let settings = MeaningSettings(source: .claudeCLI, sendEntryText: true, language: "en")

    // MARK: - UI09: the sentence belongs to the request

    @Test func theRequestCarriesTheSentenceItWasComposedFrom() async {
        let (session, _, _) = Base.session()
        session.ask()
        #expect(await Base.waitUntil { session.state != .asking })
        let context = session.sent?.questionContext
        #expect(context?.sentence == "They hold that view.")
        #expect(context?.term == "hold")
        #expect(context?.range == NSRange(location: 5, length: 4))
        let shown = MeaningPresenter.present(session.state, settings: Self.settings, sent: session.sent)
        #expect(shown?.questionContext == context, "the pane's context is the request's own field")
        // **The negative control**: another sentence, the one a stale read would have to come from, is not what it shows.
        let other = MeaningContext(term: "run", sentence: "They run daily.", range: NSRange(location: 5, length: 3))
        #expect(shown?.questionContext != other)
    }

    /// **A newer capture does not relabel the request already composed** (audit round 3, 2026-10-25): the session's live
    /// context is a second sentence, and the presentation still shows the request's own.
    @Test func aNewerCaptureDoesNotRelabelTheRequestShown() async throws {
        let (session, _, _) = Base.session()
        session.ask()
        #expect(await Base.waitUntil { session.state != .asking })
        let sent = try #require(session.sent)
        let context = try #require(sent.questionContext)
        session.hold(MeaningHandoff(term: "run", sentence: "They run daily.", range: NSRange(location: 5, length: 3),
                                    origin: MeaningOrigin(request: 8, generation: 3)))
        let answer = AIAnswer(outcome: .matched, quotes: ["to keep"], explanation: "It means that here.")
        let shown = try #require(MeaningPresenter.present(.answer(answer, mode: .grounded), settings: Self.settings,
                                                          sent: sent))
        #expect(shown.questionContext == context)
        #expect(shown.questionContext?.sentence == "They hold that view.")
        #expect(session.held?.sentence == "They run daily.", "the newer capture was not the live context")
    }

    @Test func aPreviewShowsTheSentenceItWouldSend() async {
        let (session, _, _) = Base.session()
        session.preview()
        #expect(await Base.waitUntil { if case .preview = session.state { return true } else { return false } })
        guard case .preview(let previewed) = session.state else { return }
        #expect(previewed.questionContext?.sentence == "They hold that view.")
    }

    // MARK: - UI11: the evidence names its dictionary and frame

    @Test func aGroundedRequestNamesTheDictionaryItsEvidenceComesFrom() async {
        let (session, _, _) = Base.session()
        session.dictionaryNamer = { handle in handle == Base.dict ? "Oxford" : nil }
        session.ask()
        #expect(await Base.waitUntil { session.state != .asking })
        #expect(session.sent?.dictionaryName == "Oxford")
        #expect(session.sent?.target == MeaningTarget(dictionary: Base.dict, entry: Base.entry))
        let shown = MeaningPresenter.present(session.state, settings: Self.settings, sent: session.sent)
        #expect(shown?.evidenceSource == "Oxford")
        #expect(shown?.evidenceTarget == MeaningTarget(dictionary: Base.dict, entry: Base.entry))
    }

    @Test func aSentenceOnlyAnswerHasNoEvidenceSource() async throws {
        let (session, _, _) = Base.session(
            settings: MeaningSettings(source: .http, model: "m", sendEntryText: false),
            provider: StubProvider(answers: [.success(#"{"outcome":"explanationOnly","quotes":[],"explanation":"x"}"#)]))
        session.dictionaryNamer = { _ in "Oxford" }
        session.ask()
        // **The state is the answer the test means** (audit round 2, 2026-10-25): any other settled state used to pass the
        // optional comparisons below without producing one.
        #expect(await Base.waitUntil { session.state != .asking })
        guard case .answer(_, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        #expect(mode == .sentenceOnly)
        let sent = try #require(session.sent)
        #expect(sent.target == nil)
        let shown = try #require(MeaningPresenter.present(session.state, settings: Self.settings, sent: sent))
        #expect(shown.evidenceSource == nil)
    }

    // MARK: - UI23: an incidental sense click keeps a finished answer

    @Test func aFinishedAnswerSurvivesANewSelectionLabelledWithItsOwnSense() async {
        let (session, provider, _) = Base.senseSession()
        session.explain()
        #expect(await Base.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        let sent = session.sent
        session.select(MeaningSelection(dictionary: Base.dict, entry: Base.entry, sense: 1, dictionaryName: "Test"))
        // **The whole answer survives, not just its case** (audit round 2, 2026-10-25): the same explanation, quotes and
        // mode, and the same frozen request.
        #expect(session.state == .answer(answer, mode: mode), "a click on another sense changed the answer")
        #expect(session.sent == sent, "a click on another sense changed the request the answer is about")
        #expect(session.sent?.sense?.id == 2, "the answer stays labelled with the sense it was about")
        #expect(session.selection?.sense == 1)
        let shown = MeaningPresenter.present(session.state, settings: Self.settings, sent: session.sent,
                                             selection: session.selection)
        #expect(shown?.selectionMoved == true, "the pane says the answer is about the sense chosen before")
        #expect(await provider.questions.count == 1, "selecting a sense sends nothing")
        // The current selection is what the next explain asks about.
        let same = MeaningPresenter.present(session.state, settings: Self.settings, sent: session.sent,
                                            selection: MeaningSelection(dictionary: Base.dict, entry: Base.entry,
                                                                        sense: 2))
        #expect(same?.selectionMoved == false)
        // **The next explain is about the new selection** (audit round 3, 2026-10-25): the comment above now has its ask.
        session.explain()
        #expect(await Base.waitUntil { session.state != .asking && session.sent?.sense?.id == 1 },
                "the next explain did not ask about the selection")
        #expect(await provider.questions.count == 2)
    }

    @Test func clearingTheChosenSenseKeepsTheAnswer() async {
        let (session, _, _) = Base.senseSession()
        session.explain()
        #expect(await Base.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        let sent = session.sent
        session.clearSelection()
        #expect(session.selection == nil)
        #expect(!session.hasSenseSelection)
        #expect(session.state == .answer(answer, mode: mode), "clearing the choice changed the answer")
        #expect(session.sent == sent, "clearing the choice changed the request")
        let shown = MeaningPresenter.present(session.state, settings: Self.settings, sent: session.sent,
                                             selection: session.selection)
        // **None chosen is not "another sense"** (audit round 1, 2026-10-25): the label says "You have chosen another
        // sense since", which would be false here; the answer already names its own sense.
        #expect(shown?.selectionMoved == false)
    }

    // MARK: - UI15, UI20: recovery first, the code behind it

    @Test func eachRecoverableFailureNamesItsNextStep() throws {
        // **A state with no presentation is a failure of the test** (audit round 3, 2026-10-25): optional chaining passed a
        // missing presentation off as "no next step".
        func recovery(_ state: MeaningSession.State) throws -> MeaningRecovery? {
            try #require(MeaningPresenter.present(state, settings: Self.settings, sent: nil)).recovery
        }
        #expect(try recovery(.unavailable(.noSource)) == .openAISettings)
        #expect(try recovery(.unavailable(.entryTextOff)) == .openAISettings)
        #expect(try recovery(.template(.templateTooLong)) == .openAISettings)
        #expect(try recovery(.unavailable(.provider(.unauthorised))) == .openAISettings)
        #expect(try recovery(.unavailable(.provider(.notSignedIn))) == .openAISettings)
        #expect(try recovery(.unavailable(.provider(.modelNotFound))) == .openAISettings)
        #expect(try recovery(.unavailable(.provider(.timeout))) == .retry)
        #expect(try recovery(.unavailable(.provider(.unreachable))) == .retry)
        #expect(try recovery(.unavailable(.provider(.rateLimited))) == .retry)
        #expect(try recovery(.unavailable(.consentChanged)) == .openAISettings)
        #expect(try recovery(.unavailable(.provider(.contextExceeded))) == .openAISettings)
        #expect(try recovery(.invalid(.shape)) == .retry)
        #expect(try recovery(.cancelled) == .retry)
        // Nothing the pane could do: the reader moves on in the entry.
        #expect(try recovery(.unavailable(.noContext)) == nil)
        #expect(try recovery(.unavailable(.noEntry)) == nil)
        #expect(try recovery(.unavailable(.provider(.guardrail))) == nil)
        // An answer is not a failure.
        #expect(try recovery(.answer(AIAnswer(outcome: .matched, quotes: ["to keep"], explanation: "x"), mode: .grounded))
                == nil)
    }

    @Test func theCodeStaysAvailableBehindThePlainSentence() {
        let shown = MeaningPresenter.present(.unavailable(.provider(.unauthorised)), settings: Self.settings, sent: nil)
        #expect(shown?.problem != nil)
        #expect(shown?.code == "provider.unauthorised")
        #expect(MeaningSentences.errorDetails(code: "provider.unauthorised").contains("provider.unauthorised"))
    }

    // MARK: - UI12, UI17, UI19: words that claim only what is known

    @Test func groundingSaysWhatWasUsedNotThatItIsRight() {
        #expect(MeaningSentences.grounding(.grounded)?.key == "Uses this dictionary entry")
        #expect(MeaningSentences.grounding(.ungrounded)?.key == "Uses only the sentence")
        #expect(MeaningSentences.outcome(.matched).key == "Chose a sense from the entry")
        #expect(MeaningSentences.generated.key == "AI-generated. It can be wrong; check it against the entry.")
        #expect(MeaningSentences.title.key == "Meaning in Context")
    }

    @Test func aPreviewSaysWillBeSentAndTheRecordSaysWasSent() {
        #expect(MeaningSentences.cut(at: 4096, sent: false).key.contains("will be sent"))
        #expect(MeaningSentences.cut(at: 4096, sent: true).key.contains("was sent"))
        #expect(!MeaningSentences.cut(at: 4096, sent: false).key.contains("was sent"))
    }

    // MARK: - UI04: the pane's content follows the visible column

    @Test func theAnswerFollowsTheVisibleColumnWithinTheInspectorsBounds() {
        let bounds = MeaningPaneWidth.self
        #expect(bounds.content(visible: nil) == bounds.minimum, "before a measurement, the promised minimum")
        #expect(bounds.content(visible: bounds.minimum + 80) == bounds.minimum + 80)
        #expect(bounds.content(visible: bounds.maximum + 400) == bounds.maximum)
        #expect(bounds.content(visible: bounds.minimum - 50) == bounds.minimum)
        #expect(bounds.minimum < bounds.maximum)
    }

    // MARK: - UI11: evidence is revealed in its own frame

    /// **Show in the Entry names the frame the answer quoted** (UI11): the frozen target's dictionary handle, edition
    /// and edition-qualified reference, occurrence included; never the page's text at large.
    @Test func evidenceNamesTheFrameItWasQuotedFrom() {
        let target = MeaningTarget(dictionary: DictId(rawValue: "handle-b"),
                                   entry: EntryRef(edition: Edition(rawValue: "edition-2"), key: "run", occurrence: 1))
        #expect(SearchWindowState.evidenceFrame(target)
                == EntryFrameName(handle: "handle-b", edition: "edition-2", reference: EntryReference(key: "run", occurrence: 1)))
    }
}
