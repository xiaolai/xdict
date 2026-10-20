import Foundation
import Testing
@testable import XDictCapture

/// **The one ephemeral session the sentence lives in** (ADR-0014 decision 9): the context of the request being presented,
/// in memory only, replaced by the next, dropped when presentation ends — and described by metadata alone, so no log,
/// dump or observation hook that touches it can write the reader's text.
struct CaptureContextSessionTests {
    private static let sentence = "The tide was high that night."

    private func available() -> ContextOutcome {
        .available(sentence: Self.sentence, term: NSRange(location: 4, length: 4), cut: [], gap: nil)
    }

    /// A term carrying `context`: the session holds a term's context, and validates it as `make` does. The fixtures'
    /// sentences all hold "tide" at 4...8.
    private func term(_ context: ContextOutcome) throws -> CapturedTerm {
        try CapturedTerm.make(term: "tide", trigger: .pointerGesture, acquisition: .textRange, confidence: 1,
                               source: SourceApp(bundleID: nil), pointer: nil, box: .absent, context: context)
    }

    @Test func itHoldsOneContextAndTheNextReplacesIt() throws {
        let session = CaptureContextSession()
        session.hold(try term(available()), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == available())
        #expect(session.context(request: 3, generation: 6) == nil, "another generation's context was handed out")
        session.hold(try term(.unavailable(.notCaptured)), request: 4, generation: 8)
        #expect(session.context(request: 3, generation: 7) == nil, "two contexts were kept")
        #expect(session.context(request: 4, generation: 8) == .unavailable(.notCaptured))
    }

    @Test func endingThePresentationDropsIt() throws {
        let session = CaptureContextSession()
        session.hold(try term(available()), request: 3, generation: 7)
        session.end(request: 2)
        #expect(session.context(request: 3, generation: 7) != nil, "another request's end dropped this one")
        session.end(request: 3)
        #expect(session.context(request: 3, generation: 7) == nil)
        session.hold(try term(available()), request: 5, generation: 9)
        session.clear()
        #expect(session.isEmpty)
    }

    // MARK: - A pending context (plan-capture WI-4; ADR-0014 decision 8)

    private func pending(_ session: CaptureContextSession, _ work: PendingContextTests.Work) -> PendingContext {
        session.pending.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { await work.run() })
    }

    /// **The held context becomes what its reading settles to**, for the request it was held for.
    @Test func aPendingContextIsReplacedByWhatItSettlesTo() async throws {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(try term(.pending(context.handle)), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == .pending(context.handle))
        work.answer(PendingContextTests.grown)
        await PendingContextTests.settle { session.context(request: 3, generation: 7) != .pending(context.handle) }
        #expect(session.context(request: 3, generation: 7) == PendingContextTests.grown)
    }

    /// **It never outlives its presentation**: the next presentation, the request's end and closing each cancel the
    /// reading the held context was waiting for. Red if any of the three only drops the handle.
    @Test func replacingEndingOrClosingCancelsThePendingContext() throws {
        let session = CaptureContextSession()
        let replaced = pending(session, PendingContextTests.Work())
        session.hold(try term(.pending(replaced.handle)), request: 3, generation: 7)
        session.hold(try term(available()), request: 4, generation: 8)
        #expect(replaced.end == .cancelled, "a replaced context went on being read")

        let ended = pending(session, PendingContextTests.Work())
        session.hold(try term(.pending(ended.handle)), request: 5, generation: 9)
        session.end(request: 4)
        #expect(ended.end == nil, "another request's end cancelled this one")
        session.end(request: 5)
        #expect(ended.end == .cancelled, "an ended request's context went on being read")

        let closed = pending(session, PendingContextTests.Work())
        session.hold(try term(.pending(closed.handle)), request: 6, generation: 10)
        session.clear()
        #expect(closed.end == .cancelled, "closing left a context being read")
        #expect(session.pending.count == 0, "a cancelled context stayed in the book")
    }

    /// A reading that settles after its context was replaced changes nothing held now.
    @Test func aSettlementForAContextNoLongerHeldChangesNothing() async throws {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(try term(.pending(context.handle)), request: 3, generation: 7)
        session.hold(try term(.unavailable(.notCaptured)), request: 4, generation: 8)
        work.answer(PendingContextTests.grown)
        await context.finished()
        #expect(session.context(request: 4, generation: 8) == .unavailable(.notCaptured))
    }

    // MARK: - The sentence's lifetime: never past its request

    /// **A settled sentence lives in the session alone, and goes with its request** (decisions 8 and 9): once the held
    /// context settles, the book keeps no copy of it, and after `end(request:)` — or `clear()` — nothing of the sentence
    /// is left anywhere in the session, read through its seams (the held context and the book), not its description. Red
    /// while the book keeps a settled context until eight newer push it out.
    @Test(arguments: [true, false])
    func nothingOfASettledSentenceOutlivesItsRequest(endingByRequest: Bool) async throws {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(try term(.pending(context.handle)), request: 3, generation: 7)
        work.answer(PendingContextTests.grown)
        await PendingContextTests.settle { session.context(request: 3, generation: 7) == PendingContextTests.grown }
        #expect(session.context(request: 3, generation: 7) == PendingContextTests.grown)
        #expect(session.pending.count == 0, "the book kept a copy of a sentence the session already holds")
        #expect(session.pending.context(context.handle) == nil)
        if endingByRequest { session.end(request: 3) } else { session.clear() }
        #expect(session.isEmpty && session.pending.count == 0, "something of the sentence outlived its request")
    }

    /// **A context let go by whoever held it leaves the book**: cancelled through its own handle — as the watcher does for
    /// a word it will not present — it is no longer found, so its first reading is not kept for later. Red while only the
    /// book's own `cancel` forgets.
    @Test func aContextCancelledByItsHolderLeavesTheBook() {
        let book = PendingContexts()
        let context = book.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { nil })
        let held = book.start(fallback: PendingContextTests.first, bound: .seconds(5), work: {
            await PendingContextTests.Work().run()
        })
        held.cancel()
        #expect(book.context(held.handle) == nil, "a cancelled context stayed in the book")
        context.cancel()
        #expect(book.count == 0, "the book holds \(book.count) contexts nobody wants")
    }

    /// **A settlement for an older generation of the same request changes nothing held now** (the generation check in
    /// `settle`): the request presented again with another pending context, and the first one's end arrives. Red without
    /// the check, which would replace the newer pending context with the older one's ending.
    @Test func aSettlementForAnOlderGenerationChangesNothing() throws {
        let session = CaptureContextSession()
        let older = pending(session, PendingContextTests.Work())
        session.hold(try term(.pending(older.handle)), request: 3, generation: 7)
        let newer = pending(session, PendingContextTests.Work())
        // The older one is cancelled inside this call, and its ending reaches the session before it returns.
        session.hold(try term(.pending(newer.handle)), request: 3, generation: 8)
        #expect(older.end == .cancelled)
        #expect(session.context(request: 3, generation: 8) == .pending(newer.handle),
                "an older generation's ending replaced the context held now")
        newer.cancel()
    }

    /// **Fail-closed**: a handle the book does not hold (cancelled, or never started) is held as no context, never as a
    /// context waiting forever.
    @Test func anUnknownHandleIsHeldAsNoContext() throws {
        let session = CaptureContextSession()
        session.hold(try term(.pending(PendingContextHandle(id: 999))), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == .unavailable(.notCaptured))
    }

    // MARK: - A settlement passes the constructor's boundary (Codex objection 5)

    /// **A settled context is validated as the constructor's is** — the gap the refutation found: the session installed
    /// whatever the reading answered. An over-ceiling sentence, a range outside its sentence, a range holding another
    /// term or another pending handle is held as no context, fail-closed.
    @Test(arguments: [
        ContextOutcome.available(sentence: String(repeating: "a", count: CaptureLimits.contextCeilingUTF16 + 1),
                                 term: NSRange(location: 0, length: 1), cut: [], gap: nil),
        ContextOutcome.available(sentence: "The tide", term: NSRange(location: 8, length: 4), cut: [], gap: nil),
        ContextOutcome.available(sentence: "The tide", term: NSRange(location: 4, length: 3), cut: [], gap: nil),
        ContextOutcome.pending(PendingContextHandle(id: 999)),
    ])
    func anInvalidSettlementIsHeldAsNoContext(_ settled: ContextOutcome) async throws {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(try term(.pending(context.handle)), request: 3, generation: 7)
        work.answer(settled)
        await PendingContextTests.settle { session.context(request: 3, generation: 7) != .pending(context.handle) }
        #expect(session.context(request: 3, generation: 7) == .unavailable(.notCaptured))
    }

    /// And a valid settlement is **cleaned exactly as the constructor cleans it**, its range moved: the transformation
    /// is the constructor's, not a copy of it.
    @Test func aValidSettlementIsCleanedAndItsRangeMoved() async throws {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(try term(.pending(context.handle)), request: 3, generation: 7)
        work.answer(.available(sentence: "a\u{0} tide", term: NSRange(location: 3, length: 4), cut: [], gap: nil))
        await PendingContextTests.settle { session.context(request: 3, generation: 7) != .pending(context.handle) }
        #expect(session.context(request: 3, generation: 7)
                == .available(sentence: "a tide", term: NSRange(location: 2, length: 4), cut: [], gap: nil))
    }

    /// **Metadata only**: neither its description, its debug description nor a dump names a word of the sentence.
    @Test func noDescriptionOfTheSessionCarriesTheSentence() throws {
        let session = CaptureContextSession()
        session.hold(try term(available()), request: 3, generation: 7)
        var dumped = ""
        dump(session, to: &dumped)
        for text in [String(describing: session), String(reflecting: session), dumped] {
            #expect(!text.contains("tide") && !text.contains("night"), "the session described its sentence: \(text)")
        }
    }
}
