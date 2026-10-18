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

    @Test func itHoldsOneContextAndTheNextReplacesIt() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == available())
        #expect(session.context(request: 3, generation: 6) == nil, "another generation's context was handed out")
        session.hold(.unavailable(.notCaptured), request: 4, generation: 8)
        #expect(session.context(request: 3, generation: 7) == nil, "two contexts were kept")
        #expect(session.context(request: 4, generation: 8) == .unavailable(.notCaptured))
    }

    @Test func endingThePresentationDropsIt() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        session.end(request: 2)
        #expect(session.context(request: 3, generation: 7) != nil, "another request's end dropped this one")
        session.end(request: 3)
        #expect(session.context(request: 3, generation: 7) == nil)
        session.hold(available(), request: 5, generation: 9)
        session.clear()
        #expect(session.isEmpty)
    }

    // MARK: - A pending context (plan-capture WI-4; ADR-0014 decision 8)

    private func pending(_ session: CaptureContextSession, _ work: PendingContextTests.Work) -> PendingContext {
        session.pending.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { await work.run() })
    }

    /// **The held context becomes what its reading settles to**, for the request it was held for.
    @Test func aPendingContextIsReplacedByWhatItSettlesTo() async {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(.pending(context.handle), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == .pending(context.handle))
        work.answer(PendingContextTests.grown)
        await PendingContextTests.settle { session.context(request: 3, generation: 7) != .pending(context.handle) }
        #expect(session.context(request: 3, generation: 7) == PendingContextTests.grown)
    }

    /// **It never outlives its presentation**: the next presentation, the request's end and closing each cancel the
    /// reading the held context was waiting for. Red if any of the three only drops the handle.
    @Test func replacingEndingOrClosingCancelsThePendingContext() {
        let session = CaptureContextSession()
        let replaced = pending(session, PendingContextTests.Work())
        session.hold(.pending(replaced.handle), request: 3, generation: 7)
        session.hold(available(), request: 4, generation: 8)
        #expect(replaced.end == .cancelled, "a replaced context went on being read")

        let ended = pending(session, PendingContextTests.Work())
        session.hold(.pending(ended.handle), request: 5, generation: 9)
        session.end(request: 4)
        #expect(ended.end == nil, "another request's end cancelled this one")
        session.end(request: 5)
        #expect(ended.end == .cancelled, "an ended request's context went on being read")

        let closed = pending(session, PendingContextTests.Work())
        session.hold(.pending(closed.handle), request: 6, generation: 10)
        session.clear()
        #expect(closed.end == .cancelled, "closing left a context being read")
        #expect(session.pending.count == 0, "a cancelled context stayed in the book")
    }

    /// A reading that settles after its context was replaced changes nothing held now.
    @Test func aSettlementForAContextNoLongerHeldChangesNothing() async {
        let session = CaptureContextSession()
        let work = PendingContextTests.Work()
        let context = pending(session, work)
        session.hold(.pending(context.handle), request: 3, generation: 7)
        session.hold(.unavailable(.notCaptured), request: 4, generation: 8)
        work.answer(PendingContextTests.grown)
        await context.finished()
        #expect(session.context(request: 4, generation: 8) == .unavailable(.notCaptured))
    }

    /// **Fail-closed**: a handle the book does not hold (cancelled, or never started) is held as no context, never as a
    /// context waiting forever.
    @Test func anUnknownHandleIsHeldAsNoContext() {
        let session = CaptureContextSession()
        session.hold(.pending(PendingContextHandle(id: 999)), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == .unavailable(.notCaptured))
    }

    /// **Metadata only**: neither its description, its debug description nor a dump names a word of the sentence.
    @Test func noDescriptionOfTheSessionCarriesTheSentence() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        var dumped = ""
        dump(session, to: &dumped)
        for text in [String(describing: session), String(reflecting: session), dumped] {
            #expect(!text.contains("tide") && !text.contains("night"), "the session described its sentence: \(text)")
        }
    }
}
