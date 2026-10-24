import Foundation
import Testing
import XDictTestSupport
import XDictAI
import XDictClient
import XDictContract
@testable import XDictUI

/// **One ask, from the reader's tap to the answer** (plan-ai-meaning WI-5; `conformance/ai/CONTRACT.md` §8.3): the entry's
/// text only under the switch, one source with no fallback, one ask at a time, and cancellation that nothing late can
/// undo. Every seam is a fake here: no network, no CLI, no service.
@MainActor
@Suite(.serialized) struct MeaningSessionTests {
    static let dict = DictId(rawValue: "1a2b3c4d00000001")
    static let edition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32))
    static let entry = EntryRef(edition: edition, key: "hold", occurrence: 0)
    static let entryText = EntryText(
        entry: entry, text: "hold\n  to keep\n  an opinion", spans: [
            TextSpan(start: 0, len: 4, role: "headword", label: nil, section: nil),
            TextSpan(start: 6, len: 21, role: "definition", label: "1", section: "verb"),
        ], complete: true, omittedBytes: 0, cutAt: 27, spansDropped: 0)
    static let matched = #"{"outcome":"matched","quotes":["to keep"],"explanation":"It means to keep."}"#
    /// The same entry with the senses ADR-0029's projection would carry: "hold" at 0, "to keep" at 7, "an opinion" at 17.
    static let senseEntryText = EntryText(
        entry: entry, text: "hold\n  to keep\n  an opinion", spans: [], senses: [
            Sense(id: 1, start: 7, len: 7, label: "1", section: "verb", parent: nil, whole: true),
            Sense(id: 2, start: 17, len: 10, label: "2", section: "verb", parent: nil, whole: true),
        ], style: 13, complete: true, omittedBytes: 0, cutAt: 27, spansDropped: 0)
    static let explained = #"{"outcome":"explained","quotes":["an opinion"],"explanation":"It means the view they keep."}"#
    static let doesNotFit = #"{"outcome":"doesNotFit","quotes":[],"explanation":"This sense is not the one used here."}"#
    /// The entry the fixture's sentence belongs to; a presentation draws it, as the window's would.
    static let subject = MeaningSession.Subject(
        dictionary: UUID(uuidString: "00000000-0000-0000-0000-00000000a1a1") ?? UUID(),
        key: "hold", occurrence: 0)

    /// An ask's seams: what the service would answer for `entry_text`, what is drawn, and the source.
    static func session(
        settings: MeaningSettings = MeaningSettings(source: .http, model: "m", sendEntryText: true),
        fetched: Result<EntryText, ClientFailure> = .success(entryText),
        drawn: Bool = true,
        provider: StubProvider = StubProvider(answers: [.success(matched)]),
        fetch: Fetcher? = nil
    ) -> (MeaningSession, StubProvider, Fetcher) {
        let fetcher = fetch ?? Fetcher(fetched)
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { drawn ? (Self.dict, Self.entry) : nil },
            makeProvider: { _ in provider })
        session.settings = settings
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.", range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 7, generation: 2)))
        if drawn { session.drawn(Self.subject, target: (Self.dict, Self.entry)) }
        return (session, provider, fetcher)
    }

    /// Shares the async overload's 10-second budget: at full-suite startup the main actor can stall about 3 seconds,
    /// enough to use up the old 3-second deadline on its own.
    static func waitUntil(_ predicate: @MainActor () -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
        await eventually(for: timeout, predicate)
    }

    /// **Waits on what a stub says from its own actor**, with a deadline a loaded build host cannot outrun. The
    /// hand-rolled `for _ in 0..<100 { sleep(5 ms) }` polls gave 500 ms, and mbp16 ran `escapingTheAskLeavesTheLateAnswer-
    /// Unshown` out of it (2026-10-21): the provider never got its question, and the session was not in `.asking` when
    /// Escape arrived. The wait is the check — its failure names the sentence the test meant.
    static func waitUntil(_ predicate: @escaping () async -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
        // The one wait whose answer is itself asynchronous: the shared `eventually` takes a main-actor condition,
        // and a sending closure cannot carry this suite's main-actor state (2026-10-24).
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    @Test func theWholeEntryAndTheMarkedSentenceAreSentUnderTheSwitch() async {
        let (session, provider, fetcher) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        #expect(mode == .grounded)
        #expect(answer.outcome == .matched && answer.quotes == ["to keep"])
        let questions = await provider.questions
        #expect(questions.count == 1)
        let question = questions.first ?? ""
        #expect(question.contains(Self.entryText.text), "the whole entry's text is sent")
        #expect(question.contains("«hold»"), "the term is marked in its sentence")
        #expect(await fetcher.calls.count == 1)
        #expect(await fetcher.calls.first?.2 == MeaningBudget.entryTextBytes)
    }

    @Test func withTheSwitchOffNothingOfTheEntryIsFetchedOrSent() async {
        let settings = MeaningSettings(source: .http, model: "m", sendEntryText: false)
        let (session, provider, fetcher) = Self.session(settings: settings)
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await fetcher.calls.isEmpty, "no entry_text call without the switch")
        let questions = await provider.questions
        let question = questions.first ?? ""
        #expect(!question.contains(Self.entryText.text))
        // A sentence-only answer that quotes is ungrounded, and is shown as the failure it is.
        #expect(session.state == .invalid(.ungrounded))
    }

    @Test func theSentenceBelongsToTheEntryItsPresentationDrew() async {
        let (session, _, _) = Self.session()
        let drawn = Self.subject
        let other = MeaningSession.Subject(dictionary: UUID(), key: "held", occurrence: 0)
        // A fresh presentation, so the first draw is the one that binds.
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 8, generation: 3)))
        session.drawn(drawn)
        session.drawn(drawn)
        #expect(session.subject == drawn && session.held != nil, "the same entry keeps the sentence")
        // The reader moved on: another word's entry is drawn (a typed lookup, a link, another list row).
        session.drawn(other)
        #expect(session.held == nil && session.subject == nil)
        session.ask()
        #expect(session.state == .unavailable(.noContext))
    }

    @Test func noSourceAsksNothing() async {
        let (session, _, fetcher) = Self.session(settings: .off)
        session.ask()
        #expect(session.state == .unavailable(.noSource))
        #expect(await fetcher.calls.isEmpty)
        #expect(session.state != .asking)
    }

    @Test func noContextAsksNothing() async {
        let (session, _, fetcher) = Self.session()
        session.clear()
        #expect(session.held == nil)
        session.ask()
        #expect(session.state == .unavailable(.noContext))
        #expect(await fetcher.calls.isEmpty, "nothing is read for an ask with no presentation")
    }

    @Test func aGroundedAskWithNoEntryDrawnSendsNothing() async {
        let (session, provider, fetcher) = Self.session(drawn: false)
        session.ask()
        // Nothing is drawn yet: the tap waits for the entry instead of sampling one (verification finding, 2026-10-20).
        #expect(session.state == .asking)
        // What a lookup that settles with nothing to show does: the tap ends typed, and nothing was sent.
        session.noEntry()
        #expect(session.state == .unavailable(.noEntry))
        #expect(await fetcher.calls.isEmpty)
        #expect(await provider.questions.isEmpty)
    }

    /// **An ask about another entry is refused, not sent** (verification finding, 2026-10-20): the sentence is bound to one
    /// entry; a window presenting another between the draw and the ask must send nothing rather than answer about it.
    @Test func anAskForAReplacedEntryIsRefused() async {
        let (session, provider, _) = Self.session()
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "hold", occurrence: 0)
        let other = EntryRef(edition: Self.edition, key: "other", occurrence: 1)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 12, generation: 6)))
        session.drawn(expected, target: (Self.dict, other))
        #expect(session.subject == expected)
        session.ask()
        #expect(session.state == .unavailable(.noContext))
        #expect(await provider.questions.isEmpty, "the wrong entry is never sent")
    }

    @Test func anEntryThatCannotBeReadIsUnavailable() async {
        let (session, provider, _) = Self.session(fetched: .failure(.wire(.interrupted)))
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .unavailable(.entryUnreadable))
        #expect(await provider.questions.isEmpty, "no question goes without the entry it promised")
    }

    @Test func escapingTheAskLeavesTheLateAnswerUnshown() async {
        let provider = StubProvider(answers: [.success(Self.matched)], delay: .milliseconds(300))
        let (session, _, _) = Self.session(provider: provider)
        session.ask()
        #expect(session.state == .asking)
        // The provider has the question before Escape, so the cancellation interrupts a call in flight.
        #expect(await Self.waitUntil { await provider.questions.isEmpty == false },
                "the provider never got the question")
        #expect(await provider.questions.count == 1)
        session.cancel()
        #expect(session.state == .cancelled)
        // The provider's answer arrives after the cancellation: it changes nothing.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(session.state == .cancelled)
        #expect(await provider.questions.count == 1)
    }

    @Test func aNewerAskReplacesTheOlderOne() async {
        let second = #"{"outcome":"matched","quotes":["an opinion"],"explanation":"It means an opinion."}"#
        let provider = StubProvider(answers: [.success(Self.matched), .success(second)], delay: .milliseconds(200))
        let (session, _, fetcher) = Self.session(provider: provider)
        session.ask()
        #expect(await Self.waitUntil { await provider.questions.isEmpty == false },
                "the provider never got the question")
        #expect(await provider.questions.count == 1, "the first ask reached its source before the second")
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        guard case .answer(let answer, _) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        // The later ask's answer, not the earlier one that finishes around it.
        #expect(answer.quotes == ["an opinion"])
        #expect(await fetcher.calls.count == 2, "each ask reads the entry once")
    }

    @Test func anAnswerThatQuotesNothingInTheEntryIsInvalid() async {
        let fabricated = #"{"outcome":"matched","quotes":["to hold dear"],"explanation":"It means to value."}"#
        let (session, _, _) = Self.session(provider: StubProvider(answers: [.success(fabricated)]))
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .invalid(.quoteNotFound))
    }

    @Test func aCutEntryIsNeverAnsweredWithNoMatchingSense() async {
        let cut = EntryText(entry: Self.entry, text: "hold\n  to keep", spans: [], complete: false, omittedBytes: 40,
                            cutAt: 15, spansDropped: 2)
        let answer = #"{"outcome":"noMatchingSense","quotes":[],"explanation":"The entry does not define it."}"#
        let (session, _, _) = Self.session(fetched: .success(cut), provider: StubProvider(answers: [.success(answer)]))
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .invalid(.noMatchingSenseOnPartial))
    }

    @Test func aBrokenTemplateIsSaidSo() async {
        let settings = MeaningSettings(source: .http, model: "m", sendEntryText: true,
                                       templates: [.grounded: "{term} only"])
        let (session, provider, _) = Self.session(settings: settings)
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .template(.missingPlaceholder("entry")))
        #expect(await provider.questions.isEmpty, "an uncomposed question is never sent")
    }

    @Test func aPreviewComposesWithoutAskingAndSendSendsTheSameBytes() async {
        let (session, provider, fetcher) = Self.session()
        session.preview()
        #expect(await Self.waitUntil {
            if case .preview = session.state { true } else { false }
        })
        guard case .preview(let sent) = session.state else {
            Issue.record("no preview: \(session.state)")
            return
        }
        #expect(await provider.questions.isEmpty, "a preview never reaches the source")
        #expect(await fetcher.calls.count == 1, "the entry is read locally, once")
        #expect(session.sent?.text == sent.text)
        // Send from the preview is an ask of exactly those bytes.
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await provider.questions == [sent.text])
    }

    /// **A deferred ask waits for its own entry** (verification finding, 2026-10-20): a stale presentation's draw must
    /// not start the ask about the new capture.
    @Test func aDeferredAskWaitsForItsOwnEntry() async {
        let (session, provider, _) = Self.session()
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "hold", occurrence: 0)
        let stale = MeaningSession.Subject(dictionary: UUID(), key: "held", occurrence: 0)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 9, generation: 3)),
                     asking: true, expecting: expected)
        session.drawn(stale)
        #expect(session.state == .idle && session.held != nil, "a stale draw must not ask")
        session.drawn(expected)
        #expect(await Self.waitUntil { session.state != .asking && session.state != .idle })
        #expect(await provider.questions.count == 1)
    }

    /// **A hold without an ask never asks, whatever it expected** (verification finding, 2026-10-20): an expansion's
    /// ordinary redraw used to send when an expectation was present while `asking` was false.
    @Test func aHoldWithoutAnAskDrawsWithoutAsking() async {
        let (session, provider, _) = Self.session()
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "hold", occurrence: 0)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 11, generation: 5)),
                     asking: false, expecting: expected)
        session.drawn(expected)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .idle)
        #expect(await provider.questions.isEmpty, "no tap, no ask")
    }

    /// **A tap the adopted lookup cannot ground ends typed** (verification finding, 2026-10-20): the sentence stays for
    /// the pane, the reason is `noEntry`, and nothing reaches the source.
    @Test func anAskWithNoEntryEndsTypedWithNothingSent() async {
        let (session, provider, fetcher) = Self.session()
        session.noEntry()
        #expect(session.state == .unavailable(.noEntry))
        #expect(session.held != nil, "the pane still holds the sentence it could not ask about")
        #expect(await fetcher.calls.isEmpty)
        #expect(await provider.questions.isEmpty)
    }

    /// **A manual ask before the sentence's entry draws waits for that entry** (verification finding, 2026-10-20): the
    /// window still shows the entry from before the hand-off, and grounding in it would send the wrong entry.
    @Test func anAskBeforeTheEntryDrawsWaitsForIt() async {
        // The window still shows the entry from before the hand-off; the adopted entry draws a moment later.
        final class Shown { var value: (DictId, EntryRef)? }
        let shown = Shown()
        shown.value = (Self.dict, Self.entry)
        let fetcher = Fetcher(.success(Self.entryText))
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { shown.value },
            makeProvider: { _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0)
        let ada = EntryRef(edition: Self.edition, key: "ada", occurrence: 0)
        session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 13, generation: 7)),
                     asking: false, expecting: expected)
        session.ask()
        #expect(await fetcher.calls.isEmpty, "the entry from before the hand-off is never read")
        #expect(await provider.questions.isEmpty)
        shown.value = (Self.dict, ada)
        session.drawn(expected, target: (Self.dict, ada))
        #expect(await Self.waitUntil { session.state != .asking && session.state != .idle })
        #expect(await fetcher.calls.first?.1.key == "ada", "the ask reads the entry the sentence belongs to")
        #expect(await provider.questions.count == 1)
    }

    /// **Cancelling stops the ask, not the binding** (verification finding, 2026-10-20): a second Ask after Cancel still
    /// waits for the sentence's own entry instead of sampling the window's old one.
    @Test func cancelKeepsTheEntryTheSentenceBelongsTo() async {
        final class Shown { var value: (DictId, EntryRef)? }
        let shown = Shown()
        shown.value = (Self.dict, Self.entry)
        let fetcher = Fetcher(.success(Self.entryText))
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { shown.value },
            makeProvider: { _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0)
        let ada = EntryRef(edition: Self.edition, key: "ada", occurrence: 0)
        session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 15, generation: 9)),
                     asking: false, expecting: expected)
        session.ask()
        session.cancel()
        session.ask()
        #expect(await fetcher.calls.isEmpty, "the old presentation is never read, before or after Cancel")
        #expect(await provider.questions.isEmpty)
        shown.value = (Self.dict, ada)
        session.drawn(expected, target: (Self.dict, ada))
        #expect(await Self.waitUntil { session.state != .asking && session.state != .idle })
        #expect(await fetcher.calls.first?.1.key == "ada")
    }

    /// **Only the adopted lookup's presentation binds the sentence** (verification finding, 2026-10-20): a presentation
    /// queued before the adoption still equals the model's value, and must not become the sentence's entry.
    @Test func aPresentationFromBeforeTheAdoptionDoesNotBind() async {
        final class Shown { var value: (DictId, EntryRef)? }
        let shown = Shown()
        shown.value = (Self.dict, Self.entry)
        let fetcher = Fetcher(.success(Self.entryText))
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { shown.value },
            makeProvider: { _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0)
        let ada = EntryRef(edition: Self.edition, key: "ada", occurrence: 0)
        session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 16, generation: 10)),
                     asking: true, expecting: expected, adopted: true)
        // Before the adoption's own lookup begins, no presentation binds — whatever its serial.
        session.drawn(expected, target: (Self.dict, ada), lookup: 1)
        #expect(session.subject == nil)
        #expect(await provider.questions.isEmpty)
        // The adoption begins (lookup 2); a presentation from the lookup before it still cannot bind.
        session.adopted(2, handoff: session.handoffToken)
        session.drawn(expected, target: (Self.dict, ada), lookup: 1)
        #expect(session.subject == nil, "an earlier lookups presentation never binds the sentence")
        #expect(await provider.questions.isEmpty)
        shown.value = (Self.dict, ada)
        session.drawn(expected, target: (Self.dict, ada), lookup: 2)
        #expect(await Self.waitUntil { session.state != .asking && session.state != .idle })
        #expect(await fetcher.calls.first?.1.key == "ada")
    }

    /// **A superseded hand-off's adoption cannot name the lookup for the sentence now held** (verification finding,
    /// 2026-10-20): A's adoption reporting late must not let A's presentation bind C's sentence.
    @Test func aSupersededHandoffsCallbackIsIgnored() async {
        let (session, provider, _) = Self.session()
        let first = MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0)
        let ada = EntryRef(edition: Self.edition, key: "ada", occurrence: 0)
        session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 17, generation: 11)),
                     asking: false, expecting: first, adopted: true)
        let staleToken = session.handoffToken
        let second = MeaningSession.Subject(dictionary: UUID(), key: "bee", occurrence: 0)
        let bee = EntryRef(edition: Self.edition, key: "bee", occurrence: 0)
        // **The second hand-off is unresolved**: it names no entry, so only the token can tell the two adoptions apart.
        session.hold(MeaningHandoff(term: "bee", sentence: "The bee flew home.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 18, generation: 12)),
                     asking: false, expecting: nil, adopted: true)
        // The first hand-off's adoption reports its lookup after the second sentence replaced it.
        session.adopted(2, handoff: staleToken)
        session.drawn(first, target: (Self.dict, ada), lookup: 2)
        #expect(session.subject == nil, "an earlier hand-off's presentation cannot bind the held sentence")
        #expect(await provider.questions.isEmpty)
        // The held sentence's own adoption binds its own lookup's presentation.
        session.adopted(3, handoff: session.handoffToken)
        session.drawn(second, target: (Self.dict, bee), lookup: 3)
        #expect(session.subject == second)
    }

    /// **A draw of another entry never satisfies a waiting ask** (verification finding, 2026-10-20): it binds nothing and
    /// sends nothing while the sentence's own entry has not drawn.
    @Test func anotherEntryDoesNotSatisfyAWaitingAsk() async {
        let (session, provider, _) = Self.session()
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0)
        let other = MeaningSession.Subject(dictionary: UUID(), key: "hold", occurrence: 0)
        session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                    range: NSRange(location: 0, length: 3),
                                    origin: MeaningOrigin(request: 14, generation: 8)),
                     asking: false, expecting: expected)
        session.ask()
        session.drawn(other, target: (Self.dict, Self.entry))
        #expect(session.subject == nil, "the sentence is not bound to another presentation")
        #expect(await provider.questions.isEmpty)
    }

    /// **Send transmits the previewed bytes, not a recomposition** (verification finding, 2026-10-20): an entry that
    /// changes between Preview and Send cannot change what leaves.
    @Test func sendTransmitsThePreviewedBytesEvenIfTheEntryChanged() async {
        let first = EntryText(entry: Self.entry, text: "hold\n  to keep", spans: [], complete: true,
                              omittedBytes: 0, cutAt: 15, spansDropped: 0)
        let second = EntryText(entry: Self.entry, text: "hold\n  something else", spans: [], complete: true,
                               omittedBytes: 0, cutAt: 23, spansDropped: 0)
        let fetcher = ChangingFetcher([.success(first), .success(second)])
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { (Self.dict, Self.entry) },
            makeProvider: { _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 10, generation: 4)))
        session.drawn(Self.subject, target: (Self.dict, Self.entry))
        session.preview()
        #expect(await Self.waitUntil {
            if case .preview = session.state { true } else { false }
        })
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        let question = await provider.questions.first ?? ""
        #expect(question.contains("hold\n  to keep"), "the previewed entry's text is what left")
        #expect(!question.contains("something else"))
        #expect(await fetcher.calls == 1, "Send must not refetch the entry")
    }

    @Test func thePromptTheReaderCanSeeIsTheQuestionTheSourceReceived() async {
        let (session, provider, _) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        let question = await provider.questions.first ?? ""
        #expect(session.sent?.text == question, "View the prompt must show exactly the bytes that were sent")
        #expect(session.sent?.mode == .grounded)
        #expect(session.sent?.complete == true)
        #expect(session.sent?.cutAt == Self.entryText.cutAt)
    }

    @Test func anEditedTemplateIsTheInstructionSent() async {
        let edit = "Explain {term} in {language}.\n{sentence}\n{entry}"
        let settings = MeaningSettings(source: .http, model: "m", sendEntryText: true,
                                       templates: [.grounded: edit])
        let (session, provider, _) = Self.session(settings: settings)
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        let question = await provider.questions.first ?? ""
        #expect(question.hasPrefix("Explain hold in en.\n"), "the reader's edit is the instruction sent")
        #expect(!question.contains("What does the word"), "the shipped default is not also sent")
    }

    @Test func aNewAskDropsTheLastPromptsText() async {
        let (session, _, _) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent != nil)
        session.clear()
        #expect(session.sent == nil, "the prompt holds the sentence; the next presentation drops it")
    }

    @Test func twoWindowsAskingTheSameSourceSerialize() async {
        let provider = StubProvider(answers: [.success(Self.matched)], delay: .milliseconds(120))
        let (first, _, _) = Self.session(provider: provider)
        let (second, _, _) = Self.session(provider: provider)
        first.ask()
        second.ask()
        #expect(await Self.waitUntil { first.state != .asking && second.state != .asking })
        #expect(await provider.peak == 1, "two asks reached one kind of source at once")
        #expect(await provider.questions.count == 2, "both asks were answered, one after the other")
    }

    @Test func anAskCancelledWhileItWaitsNeverReachesTheSource() async {
        let provider = StubProvider(answers: [.success(Self.matched)], delay: .milliseconds(150))
        let (first, _, _) = Self.session(provider: provider)
        let (second, _, _) = Self.session(provider: provider)
        first.ask()
        #expect(await Self.waitUntil { await provider.questions.isEmpty == false },
                "the provider never got the question")
        second.ask()
        second.cancel()
        #expect(second.state == .cancelled)
        #expect(await Self.waitUntil { first.state != .asking })
        #expect(await provider.questions.count == 1, "the cancelled ask never reached the source")
    }

    @Test func aProviderFailureIsTypedAndNotRetriedElsewhere() async {
        let (session, provider, _) = Self.session(provider: StubProvider(answers: [.failure(.unauthorised)]))
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .unavailable(.provider(.unauthorised)))
        #expect(await provider.questions.count == 1, "one source, one try, no chain")
    }

    @Test func aProviderCancellationIsTheSessionsOwn() async {
        let (session, _, _) = Self.session(provider: StubProvider(answers: [.failure(.cancelled)]))
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .cancelled)
    }

    // MARK: - Consent at the send boundary (plan-explain-sense WI-2)

    /// A session whose fetch the test gates, so the switch can be turned off while the entry is being read.
    static func gatedSession(_ fetcher: GatedFetcher, _ provider: StubProvider) -> MeaningSession {
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { (Self.dict, Self.entry) },
            makeProvider: { _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 7, generation: 2)))
        session.drawn(Self.subject, target: (Self.dict, Self.entry))
        return session
    }

    @Test func aSwitchTurnedOffWhileTheEntryIsReadSendsNothing() async {
        let fetcher = GatedFetcher(.success(Self.entryText))
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = Self.gatedSession(fetcher, provider)
        session.ask()
        #expect(await Self.waitUntil { await fetcher.calls == 1 })
        session.settings.sendEntryText = false
        await fetcher.open()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await provider.questions.isEmpty, "the entry's text left after the switch was turned off")
        #expect(session.state == .unavailable(.consentChanged))
    }

    @Test func aSwitchTurnedOffWhileWaitingForTheSourceSendsNothing() async {
        let (session, provider, fetcher) = Self.session()
        let ticket = UUID()
        #expect(await MeaningQueue.shared.acquire(.http, id: ticket), "the test could not hold the source")
        session.ask()
        #expect(await Self.waitUntil { await fetcher.calls.count == 1 })
        // The ask has read the entry and waits for the source's permit.
        try? await Task.sleep(for: .milliseconds(100))
        session.settings.sendEntryText = false
        await MeaningQueue.shared.release(.http)
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await provider.questions.isEmpty, "the entry's text left after the switch was turned off")
        #expect(session.state == .unavailable(.consentChanged))
    }

    // MARK: - The chosen sense (plan-explain-sense WI-5)

    /// A session with the sentence bound, a sense selected, and `senseEntryText` as the projection.
    static func senseSession(provider: StubProvider = StubProvider(answers: [.success(explained)]),
                             fetched: Result<EntryText, ClientFailure> = .success(senseEntryText),
                             selection: UInt32 = 2, dictionary: DictId = dict,
                             entry: EntryRef = entry) -> (MeaningSession, StubProvider, Fetcher) {
        let (session, provider, fetcher) = Self.session(
            settings: MeaningSettings(source: .http, model: "m", sendEntryText: true), fetched: fetched, provider: provider)
        session.select(MeaningSelection(dictionary: dictionary, entry: entry, sense: selection, dictionaryName: "Test"))
        return (session, provider, fetcher)
    }

    @Test func theChosenSenseQuestionCarriesTheEntryTheSenseAndItsState() async {
        let (session, provider, fetcher) = Self.senseSession()
        session.explain()
        #expect(await Self.waitUntil { session.state != .asking })
        guard case .answer(let answer, let mode) = session.state else {
            Issue.record("no answer: \(session.state)")
            return
        }
        #expect(mode == .explainSense)
        #expect(answer.outcome == .explained && answer.quotes == ["an opinion"])
        let question = await provider.questions.first ?? ""
        #expect(question.contains("an opinion"), "the chosen sense's text is sent")
        #expect(question.contains("The chosen sense above is complete: every part of it was sent."))
        #expect(question.contains("\"outcome\":\"explained|doesNotFit|insufficientContext|incompleteInput"),
                "the chosen-sense contract is appended")
        #expect(!question.contains("\"outcome\":\"matched|ambiguous|noMatchingSense|insufficientContext"),
                "the selection contract is not")
        #expect(await fetcher.calls.count == 1)
        #expect(session.sent?.sense?.id == 2 && session.sent?.dictionaryName == "Test")
    }

    @Test func aChosenSenseTheProjectionDoesNotHoldSendsNothing() async {
        let (session, provider, _) = Self.senseSession(
            fetched: .success(EntryText(entry: Self.entry, text: "hold", spans: [], senses: [], complete: true,
                                        omittedBytes: 0, cutAt: 4, spansDropped: 0)))
        session.explain()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.state == .unavailable(.noSense))
        #expect(await provider.questions.isEmpty)
    }

    @Test func theChosenSenseAskNeedsTheSwitchAndNeverFallsBackToTheSentence() async {
        let (session, provider, fetcher) = Self.senseSession()
        session.settings.sendEntryText = false
        session.explain()
        #expect(session.state == .unavailable(.entryTextOff))
        #expect(await fetcher.calls.isEmpty)
        #expect(await provider.questions.isEmpty)
    }

    @Test func aNewSelectionDropsThePreviewOfTheOldOne() async {
        let (session, provider, _) = Self.senseSession()
        session.preview()
        #expect(await Self.waitUntil { if case .preview = session.state { return true } else { return false } })
        guard case .preview(let previewed) = session.state else { return }
        #expect(previewed.mode == .explainSense && previewed.sense?.id == 2)
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        #expect(session.state == .idle)
        #expect(session.sent == nil)
        #expect(session.selection?.sense == 1)
        #expect(await provider.questions.isEmpty, "selecting a sense sends nothing")
    }

    @Test func askAgainRepeatsTheChosenSenseAndTheSelectionAskIsTheGroundedOne() async {
        let provider = StubProvider(answers: [.success(Self.explained), .success(Self.doesNotFit), .success(Self.matched)])
        let (session, _, _) = Self.senseSession(provider: provider)
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        session.askAgain()
        #expect(await Self.waitUntil { await provider.questions.count == 2 && session.state != .asking })
        session.askSelection()
        #expect(await Self.waitUntil { await provider.questions.count == 3 && session.state != .asking })
        let questions = await provider.questions
        #expect(questions[1].contains("The chosen sense above is complete"), "Ask Again repeated the chosen sense")
        #expect(!questions[2].contains("The chosen sense above is"), "the selection ask is the grounded one")
        #expect(questions[2].contains(Self.entryText.text), "the grounded ask carries the whole entry")
    }

    @Test func aSentenceOnlyPreviewSendsEvenWhileASenseStaysSelected() async {
        let (session, provider, _) = Self.senseSession()
        // The switch goes off after the selection: the preview is the sentence-only request, which ignores the sense.
        session.settings.sendEntryText = false
        session.preview()
        #expect(await Self.waitUntil { if case .preview = session.state { return true } else { return false } })
        guard case .preview(let previewed) = session.state else { return }
        #expect(previewed.mode == .sentenceOnly && previewed.sense == nil)
        session.ask()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        #expect(await provider.questions.first == previewed.text, "Send sent other bytes than the preview showed")
    }

    @Test func theFollowUpAfterDoesNotFitKeepsTheFramesEntry() async {
        let otherDict = DictId(rawValue: "feedface00000002")
        let otherEntry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "cd", count: 32)),
                                  key: "hold", occurrence: 0)
        let provider = StubProvider(answers: [.success(Self.doesNotFit), .success(Self.matched)])
        let (session, _, fetcher) = Self.senseSession(provider: provider, dictionary: otherDict, entry: otherEntry)
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        session.askSelection()
        #expect(await Self.waitUntil { await provider.questions.count == 2 && session.state != .asking })
        let calls = await fetcher.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.0 == otherDict && $0.1 == otherEntry },
                "the follow-up asked about another frame's entry: \(calls)")
    }

    @Test func aSelectionCancelsTheAskInFlightAndItsLateAnswerIsNotShown() async {
        let provider = StubProvider(answers: [.success(Self.explained)], delay: .milliseconds(300))
        let (session, _, _) = Self.senseSession(provider: provider)
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 })
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        #expect(session.state == .idle)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(session.state == .idle, "the late answer to the old sense was shown")
        #expect(session.sent == nil)
    }

    @Test func aSwitchTurnedOffBetweenPreviewAndSendSendsNothing() async {
        let (session, provider, _) = Self.session()
        session.preview()
        #expect(await Self.waitUntil { if case .preview = session.state { return true } else { return false } })
        session.settings.sendEntryText = false
        session.ask()
        #expect(await Self.waitUntil { session.state == .cancelled })
        #expect(await provider.questions.isEmpty,
                "a preview composed with the switch on was sent after it was turned off")
    }
}

/// **An entry fetch the test can suspend** (plan-explain-sense WI-2): the switch is turned off while it is in flight.
actor GatedFetcher {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let result: Result<EntryText, ClientFailure>

    init(_ result: Result<EntryText, ClientFailure>) {
        self.result = result
    }

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) async -> Result<EntryText, ClientFailure> {
        calls += 1
        if !opened {
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// What the service would answer for `entry_text`, and how often it was asked.
actor Fetcher {
    private(set) var calls: [(DictId, EntryRef, UInt64)] = []
    private let result: Result<EntryText, ClientFailure>

    init(_ result: Result<EntryText, ClientFailure>) {
        self.result = result
    }

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) -> Result<EntryText, ClientFailure> {
        calls.append((dict, entry, budget))
        return result
    }
}

/// A service whose answer for `entry_text` changes between calls, to prove Send reuses the previewed bytes.
actor ChangingFetcher {
    private(set) var calls = 0
    private var results: [Result<EntryText, ClientFailure>]

    init(_ results: [Result<EntryText, ClientFailure>]) {
        self.results = results
    }

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) -> Result<EntryText, ClientFailure> {
        calls += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

/// A source that answers with scripted results, after an optional delay that a cancellation interrupts.
actor StubProvider: AIProvider {
    nonisolated let id = AIProviderID(kind: .http)
    private(set) var questions: [String] = []
    private let answers: [Result<String, AIProviderError>]
    private let delay: Duration?

    init(answers: [Result<String, AIProviderError>], delay: Duration? = nil) {
        self.answers = answers
        self.delay = delay
    }

    private(set) var inFlight = 0
    private(set) var peak = 0

    func answer(to question: String) async throws(AIProviderError) -> String {
        questions.append(question)
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .cancelled
            }
        }
        let index = min(questions.count - 1, answers.count - 1)
        return try answers[index].get()
    }
}
