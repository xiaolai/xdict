import Foundation
import Testing
import XDictTestSupport
import XDictAI
import XDictClient
import XDictContract
@testable import XDictUI

/// **A flag a test sets from the session's own actor** (audit round 4, 2026-10-26): a non-Sendable local captured by a
/// `@MainActor` closure is the compiler's argument, not the test's.
@MainActor final class Began {
    var value = false
}

/// A counter a `@Sendable` settings closure can advance, without importing `Synchronization` into this target.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

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
            makeProvider: { _, _ in provider })
        session.settings = settings
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.", range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 7, generation: 2)))
        if drawn { session.drawn(Self.subject, target: (Self.dict, Self.entry)) }
        return (session, provider, fetcher)
    }

    /// **A session whose fetch and provider are the caller's** (audit round 2, 2026-10-25): the hand-off, settings and
    /// first draw are this factory's, as in every other test; the caller keeps its own fetcher and provider to observe.
    static func session(
        settings: MeaningSettings = MeaningSettings(source: .http, model: "m", sendEntryText: true),
        fetch: @escaping @Sendable (DictId, EntryRef, UInt64) async -> Result<EntryText, ClientFailure>,
        presented: @escaping @MainActor () -> (DictId, EntryRef)?,
        makeProvider: @escaping @Sendable (MeaningSettings, AIMode) throws(AIProviderError) -> any AIProvider,
        drawn: Bool = true
    ) -> MeaningSession {
        let session = MeaningSession(fetchEntryText: fetch, presented: presented, makeProvider: makeProvider)
        session.settings = settings
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.", range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 5, generation: 1)))
        if drawn { session.drawn(Self.subject, target: (Self.dict, Self.entry)) }
        return session
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

    /// **A no-entry failure carries none of the earlier request's evidence** (audit round 4, 2026-10-26): the prompt and
    /// provenance of the last answer never attach to the reason a tap could not be grounded, and the sentence stays.
    @Test func noEntryDropsTheEarlierRequestsEvidence() async {
        let (session, _, _) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent != nil)
        session.noEntry()
        #expect(session.state == .unavailable(.noEntry))
        #expect(session.sent == nil, "the previous request's evidence stayed")
        #expect(session.held != nil, "the sentence is kept: the tap can still be made")
    }

    /// **A new ask tells the window the failed tap's retry is over** (audit round 4, 2026-10-26): otherwise Ask Again on
    /// the new answer would repeat the lookup of a phrase the reader has moved past.
    @Test func anAskBeginsNotifiesTheWindow() async {
        let (session, _, _) = Self.session()
        let began = Began()
        session.onAskBegins = { began.value = true }
        session.ask()
        #expect(began.value)
        #expect(await Self.waitUntil { session.state != .asking })
    }

    /// **A phrase lookup that failed says why and keeps the sentence** (audit round 4, 2026-10-26).
    @Test func aFailedPhraseLookupKeepsTheSentence() {
        let (session, _, _) = Self.session()
        session.entryLookupFailed(.wire(.interrupted))
        #expect(session.state == .unavailable(.entryFailure(.wire(.interrupted))))
        #expect(session.held != nil)
    }

    /// **A request refused after composing is not marked sent** (audit rounds 1–4, 2026-10-26): the switch goes off while
    /// the entry is read, the ask is refused `consentChanged`, and the pane's evidence and a note's provenance must not
    /// name a request that never reached the source.
    @Test func aRequestRefusedAfterComposingIsNotMarkedSent() async {
        let (session, _, _) = Self.session()
        let calls = Counter()
        let on = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        let off = MeaningSettings(source: .http, model: "m", sendEntryText: false)
        session.settings = on
        session.settingsProvider = { calls.next() == 1 ? on : off }
        session.ask()
        #expect(await Self.waitUntil { session.state == .unavailable(.consentChanged) })
        #expect(session.sent == nil, "a refused request was marked sent")
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
        #expect(session.state == .unavailable(.entryFailure(.wire(.interrupted))))
        #expect(await provider.questions.isEmpty, "no question goes without the entry it promised")
    }

    @Test func escapingTheAskLeavesTheLateAnswerUnshown() async {
        // **The answer really arrives** (audit round 2, 2026-10-25): a provider that throws on cancellation never delivered
        // the late answer this test claims to reject.
        let release = Flag()
        let provider = StubbornProvider(answers: [.success(Self.matched)], release: release)
        let entryText = Self.entryText
        let session = Self.session(fetch: { _, _, _ in .success(entryText) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in provider })
        session.ask()
        #expect(session.state == .asking)
        // **The call is in flight and held** (audit round 3): no delay can let it finish before the cancellation.
        #expect(await Self.waitUntil { await provider.questions.count == 1 }, "the provider never got the question")
        let before = session.settled
        session.cancel()
        #expect(session.state == .cancelled)
        release.set()
        // The provider's answer arrives after the cancellation and the session's task ends: it changed nothing.
        #expect(await Self.waitUntil { session.settled > before }, "the late answer never finished")
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
        // Send from the preview is an ask of exactly those bytes, and reads no entry again.
        session.sendPreview()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await provider.questions == [sent.text])
        #expect(await fetcher.calls.count == 1, "Send read the entry again")
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

    /// **The window a binding test moves**: it still shows `Self.entry` when the sentence's hand-off arrives, and the
    /// test changes it later (audit round 4, 2026-10-25 — the three tests below had this fixture line for line).
    final class Shown { var value: (DictId, EntryRef)? }

    static func movingWindow() -> (session: MeaningSession, shown: Shown, fetcher: Fetcher, provider: StubProvider,
                                   expected: MeaningSession.Subject, ada: EntryRef) {
        let shown = Shown()
        shown.value = (Self.dict, Self.entry)
        let fetcher = Fetcher(.success(Self.entryText))
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = MeaningSession(
            fetchEntryText: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
            presented: { shown.value },
            makeProvider: { _, _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        return (session, shown, fetcher, provider,
                MeaningSession.Subject(dictionary: UUID(), key: "ada", occurrence: 0),
                EntryRef(edition: Self.edition, key: "ada", occurrence: 0))
    }

    /// **A manual ask before the sentence's entry draws waits for that entry** (verification finding, 2026-10-20): the
    /// window still shows the entry from before the hand-off, and grounding in it would send the wrong entry.
    @Test func anAskBeforeTheEntryDrawsWaitsForIt() async {
        let window = Self.movingWindow()
        window.session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                           range: NSRange(location: 0, length: 3),
                                           origin: MeaningOrigin(request: 13, generation: 7)),
                            asking: false, expecting: window.expected)
        window.session.ask()
        #expect(await window.fetcher.calls.isEmpty, "the entry from before the hand-off is never read")
        #expect(await window.provider.questions.isEmpty)
        window.shown.value = (Self.dict, window.ada)
        window.session.drawn(window.expected, target: (Self.dict, window.ada))
        #expect(await Self.waitUntil { window.session.state != .asking && window.session.state != .idle })
        #expect(await window.fetcher.calls.first?.1.key == "ada", "the ask reads the entry the sentence belongs to")
        #expect(await window.provider.questions.count == 1)
    }

    /// **Cancelling stops the ask, not the binding** (verification finding, 2026-10-20): a second Ask after Cancel still
    /// waits for the sentence's own entry instead of sampling the window's old one.
    @Test func cancelKeepsTheEntryTheSentenceBelongsTo() async {
        let window = Self.movingWindow()
        window.session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                           range: NSRange(location: 0, length: 3),
                                           origin: MeaningOrigin(request: 15, generation: 9)),
                            asking: false, expecting: window.expected)
        window.session.ask()
        window.session.cancel()
        window.session.ask()
        #expect(await window.fetcher.calls.isEmpty, "the old presentation is never read, before or after Cancel")
        #expect(await window.provider.questions.isEmpty)
        window.shown.value = (Self.dict, window.ada)
        window.session.drawn(window.expected, target: (Self.dict, window.ada))
        #expect(await Self.waitUntil { window.session.state != .asking && window.session.state != .idle })
        #expect(await window.fetcher.calls.first?.1.key == "ada")
    }

    /// **Only the adopted lookup's presentation binds the sentence** (verification finding, 2026-10-20): a presentation
    /// queued before the adoption still equals the model's value, and must not become the sentence's entry.
    @Test func aPresentationFromBeforeTheAdoptionDoesNotBind() async {
        let window = Self.movingWindow()
        window.session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                           range: NSRange(location: 0, length: 3),
                                           origin: MeaningOrigin(request: 16, generation: 10)),
                            asking: true, expecting: window.expected, adopted: true)
        // Before the adoption's own lookup begins, no presentation binds — whatever its serial.
        window.session.drawn(window.expected, target: (Self.dict, window.ada), lookup: 1)
        #expect(window.session.subject == nil)
        #expect(await window.provider.questions.isEmpty)
        // The adoption begins (lookup 2); a presentation from the lookup before it still cannot bind.
        window.session.adopted(2, handoff: window.session.handoffToken)
        window.session.drawn(window.expected, target: (Self.dict, window.ada), lookup: 1)
        #expect(window.session.subject == nil, "an earlier lookups presentation never binds the sentence")
        #expect(await window.provider.questions.isEmpty)
        window.shown.value = (Self.dict, window.ada)
        window.session.drawn(window.expected, target: (Self.dict, window.ada), lookup: 2)
        #expect(await Self.waitUntil { window.session.state != .asking && window.session.state != .idle })
        #expect(await window.fetcher.calls.first?.1.key == "ada")
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
            makeProvider: { _, _ in provider })
        session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 10, generation: 4)))
        session.drawn(Self.subject, target: (Self.dict, Self.entry))
        session.preview()
        #expect(await Self.waitUntil {
            if case .preview = session.state { true } else { false }
        })
        session.sendPreview()
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

    @Test func clearingDropsTheLastPromptsText() async {
        let (session, _, _) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent != nil)
        session.clear()
        #expect(session.sent == nil, "the prompt holds the sentence; the next presentation drops it")
    }

    @Test func twoWindowsAskingTheSameSourceSerialize() async {
        // **Held, not delayed** (audit round 4, 2026-10-25): serialization used to depend on a 120 ms overlap that a broken
        // queue could still satisfy by timing alone.
        let release = Flag()
        let provider = StubbornProvider(answers: [.success(Self.matched)], release: release)
        let entryText = Self.entryText
        let first = Self.session(fetch: { _, _, _ in .success(entryText) },
                                 presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
        let second = Self.session(fetch: { _, _, _ in .success(entryText) },
                                  presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
        first.ask()
        #expect(await Self.waitUntil { await provider.questions.count == 1 }, "the first ask never reached the source")
        second.ask()
        #expect(await Self.waitUntil { await MeaningQueue.shared.waitingCount == 1 }, "the second ask did not queue")
        release.set()
        #expect(await Self.waitUntil { first.state != .asking && second.state != .asking })
        #expect(await provider.peak == 1, "two asks reached one kind of source at once")
        #expect(await provider.questions.count == 2, "both asks were answered, one after the other")
    }

    @Test func anAskCancelledWhileItWaitsNeverReachesTheSource() async {
        let release = Flag()
        let provider = StubbornProvider(answers: [.success(Self.matched)], release: release)
        let entryText = Self.entryText
        let first = Self.session(fetch: { _, _, _ in .success(entryText) },
                                 presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
        let second = Self.session(fetch: { _, _, _ in .success(entryText) },
                                  presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
        first.ask()
        #expect(await Self.waitUntil { await provider.questions.isEmpty == false },
                "the provider never got the question")
        second.ask()
        // **Queued before it is cancelled** (audit round 2, 2026-10-25): a cancel racing the task's start exercised a
        // different path than the queue's.
        #expect(await Self.waitUntil { await MeaningQueue.shared.waitingCount == 1 }, "the second ask never queued")
        second.cancel()
        #expect(second.state == .cancelled)
        let beforeFirst = first.settled
        let beforeSecond = second.settled
        release.set()
        #expect(await Self.waitUntil { first.settled > beforeFirst && second.settled > beforeSecond },
                "an ask never finished")
        // **The cancelled ask never reached the source** (audit round 4, 2026-10-25): settlement alone would also hold
        // if it had run to a second answer.
        #expect(await provider.questions.count == 1, "the cancelled ask reached the source")
    }

    /// **The reader can ground the question in another dictionary's entry** (owner, 2026-10-26): the page showed one
    /// dictionary's entry, and an explicit choice sends the other dictionary's text and records it as the answer's target.
    @Test func anAskCanBeGroundedInAChosenDictionary() async {
        let fetcher = EchoFetcher()
        let provider = StubProvider(answers: [.success(Self.matched)])
        let session = Self.session(fetch: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
                                   presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
        let otherDictionary = DictId(rawValue: "feedface00000002")
        let otherEntry = EntryRef(edition: Self.edition, key: "resource", occurrence: 0)
        // A sense chosen on the entry the page showed belongs to that entry, not to the chosen one.
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        session.ask(in: MeaningTarget(dictionary: otherDictionary, entry: otherEntry))
        #expect(session.selection == nil, "a sense chosen on the old entry survived the change")
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await fetcher.calls.map(\.0) == [otherDictionary], "the chosen dictionary's entry was not read")
        #expect(await fetcher.calls.map(\.1) == [otherEntry])
        #expect(session.sent?.target == MeaningTarget(dictionary: otherDictionary, entry: otherEntry))
        #expect(await provider.questions.count == 1)
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
        Self.session(fetch: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
                     presented: { (Self.dict, Self.entry) }, makeProvider: { _, _ in provider })
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
        // **The ask is waiting for the source's permit** (audit round 3): observed, not guessed by a sleep.
        #expect(await Self.waitUntil { await MeaningQueue.shared.waitingCount == 1 }, "the ask never queued")
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

    @Test func askAgainRepeatsTheChosenSenseAndTheSelectionAskIsTheGroundedOne() async throws {
        let provider = StubProvider(answers: [.success(Self.explained), .success(Self.doesNotFit), .success(Self.matched)])
        let (session, _, _) = Self.senseSession(provider: provider)
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        session.askAgain()
        #expect(await Self.waitUntil { await provider.questions.count == 2 && session.state != .asking })
        session.askSelection()
        #expect(await Self.waitUntil { await provider.questions.count == 3 && session.state != .asking })
        let questions = await provider.questions
        try #require(questions.count == 3, "the three asks did not all reach the source")
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
        session.sendPreview()
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
        let release = Flag()
        let provider = StubbornProvider(answers: [.success(Self.explained)], release: release)
        let senseEntryText = Self.senseEntryText
        let session = Self.session(fetch: { _, _, _ in .success(senseEntryText) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in provider })
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 2, dictionaryName: "Test"))
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 })
        let before = session.settled
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        #expect(session.state == .idle)
        release.set()
        #expect(await Self.waitUntil { session.settled > before }, "the late answer never finished")
        #expect(session.state == .idle, "the late answer to the old sense was shown")
        #expect(session.sent == nil)
    }

    @Test func aSwitchTurnedOffBetweenPreviewAndSendSendsNothing() async {
        let (session, provider, _) = Self.session()
        session.preview()
        #expect(await Self.waitUntil { if case .preview = session.state { return true } else { return false } })
        session.settings.sendEntryText = false
        session.sendPreview()
        #expect(await Self.waitUntil { session.state == .cancelled })
        #expect(await provider.questions.isEmpty,
                "a preview composed with the switch on was sent after it was turned off")
    }

    // MARK: - What a new action does to the work already under way (audit findings, 2026-10-25)

    /// **An ask made while a preview is shown sends its own operation**, never the preview (audit finding, 2026-10-25):
    /// the reader's tap is about the question it names, and the preview is dropped.
    @Test func anAskWhileAPreviewIsShownSendsItsOwnOperation() async {
        let (session, provider, fetcher) = Self.senseSession()
        session.preview()
        #expect(await Self.waitUntil { if case .preview = session.state { return true } else { return false } })
        session.askSelection()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        let question = await provider.questions.first ?? ""
        #expect(question.contains(Self.entryText.text), "the ask composed its own grounded question")
        #expect(!question.contains("The chosen sense above is"), "the previewed chosen-sense request was sent instead")
        #expect(await fetcher.calls.count == 2, "the ask read the entry for itself")
    }

    /// **A deferred ask does not survive another action** (audit finding, 2026-10-25): a refusal while the ask waits for
    /// its entry disarms it, so the draw it was waiting for starts nothing — nothing sends without the reader's Send.
    @Test func aRefusalDisarmsADeferredAsk() async {
        let (session, provider, _) = Self.session()
        let expected = MeaningSession.Subject(dictionary: UUID(), key: "hold", occurrence: 0)
        session.hold(MeaningHandoff(term: "hold", sentence: "They hold that view.",
                                    range: NSRange(location: 5, length: 4),
                                    origin: MeaningOrigin(request: 21, generation: 9)),
                     expecting: expected)
        session.ask()                     // the entry has not drawn yet: the ask waits for it
        #expect(session.state == .asking)
        session.settings.sendEntryText = false
        session.explain()                 // refused, and the deferred ask is disarmed
        #expect(session.state == .unavailable(.entryTextOff))
        session.drawn(expected)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await provider.questions.isEmpty, "the disarmed ask fired on a later draw")
    }

    /// **An early refusal cancels the ask it interrupted** (audit finding, 2026-10-25): the late answer to the old ask
    /// cannot overwrite the reason the refusal gave.
    @Test func aRefusalCancelsTheAskInFlight() async {
        let release = Flag()
        let provider = StubbornProvider(answers: [.success(Self.matched)], release: release)
        let entryText = Self.entryText
        let session = Self.session(fetch: { _, _, _ in .success(entryText) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in provider })
        session.ask()
        #expect(await Self.waitUntil { await provider.questions.count == 1 }, "the ask never reached the source")
        let before = session.settled
        session.settings.sendEntryText = false
        session.explain()
        #expect(session.state == .unavailable(.entryTextOff))
        release.set()
        #expect(await Self.waitUntil { session.settled > before }, "the cancelled ask never finished")
        #expect(session.state == .unavailable(.entryTextOff), "the cancelled ask's late answer overwrote the refusal")
    }

    /// **A refusal or a preview after an answer drops that answer's prompt** (audit finding, 2026-10-25): the prompt is
    /// what the last ask actually sent, and the pane must not show it beside a request that never left.
    @Test func aRefusalAfterAnAnswerDropsTheAnswersPrompt() async {
        let (session, _, _) = Self.session()
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent != nil)
        session.settings.sendEntryText = false
        session.explain()
        #expect(session.state == .unavailable(.entryTextOff))
        #expect(session.sent == nil, "the refused ask kept the previous attempt's prompt")
    }

    /// **Clearing the chosen sense invalidates a chosen-sense preview still being composed** (audit finding, 2026-10-25):
    /// the preview would describe a sense the reader has cleared, so it must never appear.
    @Test func clearingTheSenseInvalidatesAComposingPreview() async {
        let fetcher = GatedFetcher(.success(Self.senseEntryText))
        let provider = StubProvider(answers: [.success(Self.explained)])
        let session = Self.session(fetch: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in provider })
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 2, dictionaryName: "Test"))
        session.preview()
        #expect(await Self.waitUntil { await fetcher.calls == 1 }, "the preview never read the entry")
        let before = session.settled
        session.clearSelection()
        await fetcher.open()
        #expect(await Self.waitUntil { session.settled > before }, "the released preview never finished")
        #expect(session.state == .idle, "the cleared sense's preview appeared")
    }

    // MARK: - The entry's own senses (plan-companion WI-8)

    /// **The list is the core's projection, verbatim**: ids, labels and each sense's own text, so a row with no label or
    /// a repeated section still reads as itself.
    @Test func theSenseListIsTheProjectionsOwn() {
        let rows = MeaningSession.rows(of: Self.senseEntryText)
        #expect(rows.map(\.id) == [1, 2])
        #expect(rows.map(\.label) == ["1", "2"])
        #expect(rows.map(\.snippet) == ["to keep", "an opinion"])
        #expect(rows.allSatisfy { $0.whole })
    }

    /// **The list loads for the answer's own entry**: one fetch, the rows in document order, the target recorded.
    @Test func theSenseListLoadsForItsEntry() async {
        let (session, _, fetcher) = Self.session(fetched: .success(Self.senseEntryText))
        let target = MeaningTarget(dictionary: Self.dict, entry: Self.entry)
        session.loadSenses(for: target)
        #expect(await Self.waitUntil { !session.senses.isEmpty })
        #expect(session.senses.map(\.id) == [1, 2])
        #expect(session.sensesTarget == target)
        #expect(await fetcher.calls.count == 1)
    }

    /// **A row selects its sense and asks about it**, the way the pane's row does: the ask is the chosen-sense question,
    /// and it sends that sense — never the one that happened to be selected before.
    @Test func aSenseRowAsksAboutItsOwnSense() async {
        let (session, provider, _) = Self.senseSession()
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        session.explain()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(await provider.questions.count == 1)
        #expect(session.sent?.sense?.id == 1, "the ask did not carry the row's sense")
        #expect(session.sent?.mode == .explainSense)
    }

    /// **A late list for an entry the pane has left is dropped** (Codex refutation B4): loads are generation-guarded, so
    /// A's slow answer cannot replace B's rows.
    @Test func aLateSenseListForAnotherEntryIsDropped() async {
        // **By entry, not by arrival order** (audit round 2, 2026-10-25): the first fetch is proven to have started and is
        // released only after the second's rows are shown.
        let other = EntryRef(edition: Self.edition, key: "other", occurrence: 0)
        let fetcher = EntryGatedFetcher(first: Self.entry, firstText: "from the first", secondText: "from the second")
        let matched = Self.matched
        let session = Self.session(fetch: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in StubProvider(answers: [.success(matched)]) })
        session.loadSenses(for: MeaningTarget(dictionary: Self.dict, entry: Self.entry))
        #expect(await Self.waitUntil { await fetcher.started == [Self.entry] }, "the first fetch never started")
        session.loadSenses(for: MeaningTarget(dictionary: Self.dict, entry: other))
        #expect(await Self.waitUntil { session.senses.first?.snippet == "from the second" })
        let before = session.sensesSettled
        await fetcher.openFirst()
        // **The session's own count says the released fetch was processed** (audit round 3), not the fetcher's return.
        #expect(await Self.waitUntil { session.sensesSettled > before }, "the released fetch never finished")
        #expect(session.senses.first?.snippet == "from the second", "a late list for the first entry replaced this one")
        #expect(session.sensesTarget?.entry == other)
    }

    /// **Dropping evidence cancels a load still running** (verification round 3, 2026-10-25): a refused ask cannot leave a
    /// fetch to land rows for the request being replaced, and the release does not repaint them.
    @Test func droppingEvidenceCancelsAPendingSenseLoad() async {
        let fetcher = EntryGatedFetcher(first: Self.entry, firstText: "from the first", secondText: "unused")
        let matched = Self.matched
        let session = Self.session(fetch: { dict, entry, budget in await fetcher.fetch(dict, entry, budget) },
                                   presented: { (Self.dict, Self.entry) },
                                   makeProvider: { _, _ in StubProvider(answers: [.success(matched)]) })
        let entry = Self.entry
        session.loadSenses(for: MeaningTarget(dictionary: Self.dict, entry: entry))
        #expect(await Self.waitUntil { await fetcher.started == [entry] }, "the fetch never started")
        let before = session.sensesSettled
        session.settings.source = nil
        session.ask()                       // refused for lack of a source, after dropping the evidence
        #expect(session.sensesStatus == nil)
        #expect(session.senses.isEmpty)
        await fetcher.openFirst()
        #expect(await Self.waitUntil { session.sensesSettled > before }, "the released fetch never finished")
        #expect(session.senses.isEmpty && session.sensesStatus == nil, "a cancelled load landed rows")
    }

    /// **A failed read is a failure, not an entry with no senses** (audit round 1, 2026-10-25): the status says so, and
    /// the retry asks again rather than the failure passing for an empty entry.
    @Test func aFailedSenseReadIsNotAnEmptyEntry() async {
        let (session, _, fetcher) = Self.session(fetched: .failure(.wire(.interrupted)))
        let target = MeaningTarget(dictionary: Self.dict, entry: Self.entry)
        session.loadSenses(for: target)
        #expect(await Self.waitUntil { session.sensesStatus == .failed })
        #expect(session.senses.isEmpty)
        session.loadSenses(for: target)
        #expect(await Self.waitUntil { await fetcher.calls.count == 2 }, "the retry did not ask again")
    }

    /// **An entry with no senses is loaded, not unasked**: the status, not the row count, decides whether the list is
    /// fetched again (audit round 1, 2026-10-25).
    @Test func aLoadedEmptySenseListIsNotAskedAgain() async {
        let empty = EntryText(entry: Self.entry, text: "hold", spans: [], senses: [], style: 13, complete: true,
                              omittedBytes: 0, cutAt: 4, spansDropped: 0)
        let (session, _, fetcher) = Self.session(fetched: .success(empty))
        let target = MeaningTarget(dictionary: Self.dict, entry: Self.entry)
        session.loadSenses(for: target)
        #expect(await Self.waitUntil { session.sensesStatus == .loaded })
        #expect(await Self.waitUntil { session.sensesSettled == 1 })
        #expect(session.senses.isEmpty)
        session.loadSenses(for: target)
        // **The decision is synchronous** (audit round 4, 2026-10-25): a load would set `.loading` again before returning,
        // so this read is a deterministic barrier where a sleep or a later count was not.
        #expect(session.sensesStatus == .loaded, "a loaded empty list was asked again")
        #expect(await fetcher.calls.count == 1, "a loaded empty list was fetched again")
    }

    /// **A running ask keeps the source it was started for** (verification round 1, 2026-10-25): a Settings change while
    /// it runs must not relabel the pane's "Asking …" line, and the frozen source clears when the answer lands.
    @Test func aRunningAskKeepsItsOwnSource() async {
        let provider = StubProvider(answers: [.success(Self.matched)], delay: .milliseconds(150))
        let (session, _, _) = Self.session(provider: provider)
        session.ask()
        #expect(session.state == .asking)
        session.settings.source = .claudeCLI
        #expect(session.askingSource == .http)
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.askingSource == nil)
    }

    /// **Ask Again repeats the newest attempt, even one refused before it reached a target**: a refused ask does not
    /// leave an earlier answer's operation as the one to repeat (audit round 1, 2026-10-25).
    @Test func askAgainRepeatsTheLatestAttemptNotThePreviousAnswer() async {
        let (session, provider, _) = Self.senseSession()
        session.explain()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent?.mode == .explainSense)
        session.settings.source = nil
        session.ask()
        #expect(session.state == .unavailable(.noSource))
        session.settings.source = .http
        session.askAgain()
        #expect(await Self.waitUntil { session.state != .asking })
        #expect(session.sent?.mode == .grounded, "Ask Again repeated the earlier answer's operation")
        #expect(await provider.questions.count == 2)
    }

    /// **The model is frozen at compose time** (Codex refutation, 2026-10-25): an HTTP ask records the model it named, so
    /// a later Settings change cannot relabel the answer; a CLI source records none, because its provider chooses.
    @Test func theAskedModelIsFrozenIntoTheSentRecord() async {
        let (http, _, _) = Self.session(settings: MeaningSettings(source: .http, model: "listed-alpha",
                                                                  sendEntryText: true))
        http.ask()
        #expect(await Self.waitUntil { http.state != .asking })
        #expect(http.sent?.model == "listed-alpha")
        http.settings.model = "listed-beta"
        #expect(http.sent?.model == "listed-alpha", "a later Settings change relabelled the answer")

        let (cli, _, _) = Self.session(settings: MeaningSettings(source: .claudeCLI, model: "ignored",
                                                                 sendEntryText: true))
        cli.ask()
        #expect(await Self.waitUntil { cli.state != .asking })
        #expect(cli.sent?.model == nil, "a CLI source has no model XDict asked for")
    }

    /// **The reader's answer language reaches the question** (audit finding, 2026-10-25): the session composes from the
    /// language and templates the settings carry, so a reader who chose Chinese reads a Chinese prompt.
    @Test func theQuestionIsComposedInTheChosenLanguage() async {
        let settings = MeaningSettings(source: .http, model: "m", sendEntryText: false, language: "zh-Hans")
        let (session, provider, _) = Self.session(settings: settings)
        session.ask()
        #expect(await Self.waitUntil { session.state != .asking })
        let question = await provider.questions.first ?? ""
        #expect(question.hasPrefix("单词「hold」在这个句子里是什么意思？"),
                "the question is not in the language the reader chose: \(question.prefix(40))")
    }

    /// **The selection ask follows the answer shown, not a later selection** (audit finding, 2026-10-25): the button
    /// follows up a `doesNotFit` verdict about the frame's own entry, wherever the reader's next click lands.
    @Test func aSelectionAskKeepsTheFrameOfTheAnswerShown() async {
        let otherDict = DictId(rawValue: "feedface00000002")
        let otherEntry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "cd", count: 32)),
                                  key: "hold", occurrence: 0)
        let provider = StubProvider(answers: [.success(Self.doesNotFit), .success(Self.matched)])
        let (session, _, fetcher) = Self.senseSession(provider: provider, dictionary: otherDict, entry: otherEntry)
        session.explain()
        #expect(await Self.waitUntil { await provider.questions.count == 1 && session.state != .asking })
        // The reader chooses a sense in another entry after the answer; the follow-up still asks about the answer's frame.
        session.select(MeaningSelection(dictionary: Self.dict, entry: Self.entry, sense: 1, dictionaryName: "Test"))
        session.askSelection()
        #expect(await Self.waitUntil { await provider.questions.count == 2 && session.state != .asking })
        let calls = await fetcher.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.0 == otherDict && $0.1 == otherEntry },
                "the follow-up moved to the reader's later selection: \(calls)")
    }

    /// **A phrase ask's term is the sentence's own words** (AI contract 5; plan-phrase-recognition WI-9): the model
    /// reads the surface span, marked over the whole span, and the dictionary's spelling never enters the question —
    /// it is the lookup key, not the term.
    @Test func aPhraseAskTermsTheSurfaceWordsAndCarriesTheDictionarySpelling() async throws {
        let (session, provider, _) = Self.session()
        session.hold(MeaningHandoff(term: "took the delay into account",
                                    sentence: "they took the delay into account before deciding",
                                    range: NSRange(location: 5, length: 27),
                                    origin: MeaningOrigin(request: 8, generation: 1),
                                    phrase: "take something into account"))
        session.drawn(Self.subject, target: (Self.dict, Self.entry))
        session.ask(in: MeaningTarget(dictionary: Self.dict, entry: Self.entry))
        #expect(await Self.waitUntil { await provider.questions.count == 1 })
        let question = try #require(await provider.questions.first)
        #expect(question.contains("«took the delay into account»"), "the span is marked as one")
        #expect(!question.contains("take something into account"), "the dictionary's spelling is no question's term")
        #expect(session.sent?.questionContext?.phrase == "take something into account")
        #expect(session.sent?.target == MeaningTarget(dictionary: Self.dict, entry: Self.entry))
    }

    /// **Without the entry switch a phrase ask is refused before anything is fetched or sent**, like any grounded ask.
    @Test func aPhraseAskWithoutTheEntrySwitchSendsNothing() async throws {
        let (session, provider, fetcher) = Self.session(
            settings: MeaningSettings(source: .http, model: "m", sendEntryText: false))
        session.hold(MeaningHandoff(term: "took the delay into account",
                                    sentence: "they took the delay into account before deciding",
                                    range: NSRange(location: 5, length: 27),
                                    origin: MeaningOrigin(request: 9, generation: 1),
                                    phrase: "take something into account"))
        session.drawn(Self.subject, target: (Self.dict, Self.entry))
        session.ask(in: MeaningTarget(dictionary: Self.dict, entry: Self.entry))
        #expect(session.state == .unavailable(.entryTextOff))
        #expect(await provider.questions.isEmpty)
        #expect(await fetcher.calls.isEmpty)
    }
}

/// **An entry fetch the test can suspend** (plan-explain-sense WI-2): the switch is turned off while it is in flight.
actor GatedFetcher {
    private(set) var calls = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private let result: Result<EntryText, ClientFailure>

    init(_ result: Result<EntryText, ClientFailure>) {
        self.result = result
    }

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) async -> Result<EntryText, ClientFailure> {
        calls += 1
        if !opened {
            await withCheckedContinuation { releases.append($0) }
        }
        return result
    }

    func open() {
        opened = true
        let waiting = releases
        releases = []
        for continuation in waiting { continuation.resume() }
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

/// **A fetcher that holds its first entry's answer until released** (audit round 2, 2026-10-25): by entry, so the stale
/// test proves the first fetch started before the second is asked.
actor EntryGatedFetcher {
    private(set) var started: [EntryRef] = []
    private let first: EntryRef
    private let firstText: String
    private let secondText: String
    private var released = false
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(first: EntryRef, firstText: String, secondText: String) {
        self.first = first
        self.firstText = firstText
        self.secondText = secondText
    }

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) async -> Result<EntryText, ClientFailure> {
        started.append(entry)
        if entry == first, !released { await withCheckedContinuation { releases.append($0) } }
        let text = entry == first ? firstText : secondText
        return .success(EntryText(entry: entry, text: text, spans: [], senses: [
            Sense(id: 1, start: 0, len: UInt64(text.utf8.count), label: nil, section: nil, parent: nil, whole: true),
        ], style: 13, complete: true, omittedBytes: 0, cutAt: UInt64(text.utf8.count), spansDropped: 0))
    }

    func openFirst() {
        released = true
        let waiting = releases
        releases = []
        for continuation in waiting { continuation.resume() }
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

/// **An entry fetch that answers for the entry it was asked about** (owner, 2026-10-26): a chosen dictionary's fetch
/// must carry that entry's own text, not another dictionary's.
actor EchoFetcher {
    private(set) var calls: [(DictId, EntryRef)] = []

    func fetch(_ dict: DictId, _ entry: EntryRef, _ budget: UInt64) -> Result<EntryText, ClientFailure> {
        calls.append((dict, entry))
        // The fixture answer's quote ("to keep") is a byte slice of this text, so the answer validates as usual.
        let text = "resource\n  to keep"
        return .success(EntryText(entry: entry, text: text, spans: [], senses: [], style: 13, complete: true,
                                  omittedBytes: 0, cutAt: UInt64(text.utf8.count), spansDropped: 0))
    }
}

/// **A provider that finishes a call even after it is cancelled** (audit round 2, 2026-10-25): the stub below throws
/// `.cancelled` when interrupted, so the late-answer tests never delivered the answer they claimed to reject. The wait
/// for the release runs in a detached task, which cancellation does not reach.
actor StubbornProvider: AIProvider {
    nonisolated let id = AIProviderID(kind: .http)
    private(set) var questions: [String] = []
    private let answers: [Result<String, AIProviderError>]
    private let release: Flag?
    private(set) var inFlight = 0
    private(set) var peak = 0

    init(answers: [Result<String, AIProviderError>], release: Flag? = nil) {
        self.answers = answers
        self.release = release
    }

    func answer(to question: String) async throws(AIProviderError) -> String {
        questions.append(question)
        let index = min(questions.count - 1, answers.count - 1)
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if let release {
            await Task.detached { while !release.isSet { try? await Task.sleep(for: .milliseconds(10)) } }.value
        }
        return try answers[index].get()
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

    func answer(to question: String) async throws(AIProviderError) -> String {
        questions.append(question)
        // **This call's answer is chosen before it suspends** (audit round 2, 2026-10-25): a later call must not move
        // which scripted answer an earlier one receives.
        let index = min(questions.count - 1, answers.count - 1)
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .cancelled
            }
        }
        return try answers[index].get()
    }
}

/// **A question asked before the entry drew still previews, and still names its own tab** (audit 2026-10-27): the deferred
/// paths used to call the ask directly, so "show the request before asking" was silently skipped for a capture's own
/// question, and the popover's Meaning Here could sit under a remembered translation tab.
@MainActor
struct MeaningDeferredQuestionTests {
    /// A preview owed to a draw is composed at it, and sends nothing.
    @Test func aPreviewOwedToADrawIsComposedAtTheDraw() async {
        let window = MeaningSessionTests.movingWindow()
        window.session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true,
                                                  previewBeforeSending: true)
        window.session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                           range: NSRange(location: 0, length: 3),
                                           origin: MeaningOrigin(request: 21, generation: 7)),
                            expecting: window.expected)
        window.session.choose(.meaning)
        #expect(window.session.state == .asking, "a preview that cannot be composed yet waits, and says so")
        #expect(await window.fetcher.calls.isEmpty, "nothing is composed against an entry not yet drawn")
        window.shown.value = (MeaningSessionTests.dict, window.ada)
        window.session.drawn(window.expected, target: (MeaningSessionTests.dict, window.ada))
        #expect(await MeaningSessionTests.waitUntil {
            if case .preview = window.session.state { true } else { false }
        }, "the owed preview is composed once its entry draws")
        #expect(await window.provider.questions.isEmpty, "a preview sends nothing")
    }

    /// The popover's Meaning Here is the meaning question, so the tabs follow it even with another mode remembered.
    @Test func anExplicitMeaningAskMovesTheTabs() async {
        let window = MeaningSessionTests.movingWindow()
        window.session.settings = MeaningSettings(source: .http, model: "m", sendEntryText: true)
        window.session.choose(.translation)
        window.session.hold(MeaningHandoff(term: "ada", sentence: "Ada ran the engine.",
                                           range: NSRange(location: 0, length: 3),
                                           origin: MeaningOrigin(request: 22, generation: 8)),
                            asking: true, expecting: window.expected)
        window.shown.value = (MeaningSessionTests.dict, window.ada)
        window.session.drawn(window.expected, target: (MeaningSessionTests.dict, window.ada))
        #expect(window.session.chosenMode == .meaning, "the popover's Meaning Here moves the tabs to Meaning")
    }
}
