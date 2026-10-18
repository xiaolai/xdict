import Foundation
import Synchronization
import Testing
@testable import XDictCapture

/// **A context still being read, and its one ending** (ADR-0014 decisions 2 and 8; plan-capture WI-4, the handle's cancel
/// carried from WI-1's verification). The word is handed over at once and the rest of its sentence goes on being read; this
/// is what that reading settles to — exactly once, as the work's answer, a cancellation (replacement, closing, refusal), or
/// overdue past its bound with the first reading standing — and the work itself is waited for apart from that ending, since
/// a capture that cannot be stopped still holds the one capture until it returns.
struct PendingContextTests {
    static let first = ContextOutcome.available(sentence: "The tide", term: NSRange(location: 4, length: 4), cut: [.end], gap: nil)
    static let grown = ContextOutcome.available(
        sentence: "The tide was high that night.", term: NSRange(location: 4, length: 4), cut: [], gap: nil)

    /// A work the test answers by hand, which hears its cancellation.
    final class Work: Sendable {
        private let waiting = Mutex<CheckedContinuation<ContextOutcome?, Never>?>(nil)
        private let answered = Mutex<ContextOutcome??>(nil)
        let cancelled = Mutex(false)
        let started = Mutex(false)

        func run() async -> ContextOutcome? {
            started.withLock { $0 = true }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let early = answered.withLock { answered -> ContextOutcome?? in
                        if let answered { return answered }
                        waiting.withLock { $0 = continuation }
                        return nil
                    }
                    if let early { continuation.resume(returning: early) }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }

        func answer(_ outcome: ContextOutcome?) {
            let continuation = answered.withLock { answered -> CheckedContinuation<ContextOutcome?, Never>? in
                answered = .some(outcome)
                return waiting.withLock { taken in defer { taken = nil }; return taken }
            }
            continuation?.resume(returning: outcome)
        }
    }

    /// A bound that never passes unless the test says so.
    final class Bound: Sendable {
        private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
        private let passed = Mutex(false)
        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                let now = passed.withLock { passed -> Bool in
                    if !passed { waiting.withLock { $0.append(continuation) } }
                    return passed
                }
                if now { continuation.resume() }
            }
        }
        func pass() {
            passed.withLock { $0 = true }
            for continuation in waiting.withLock({ taken in defer { taken = [] }; return taken }) { continuation.resume() }
        }
    }

    /// What a listener heard.
    final class Heard: Sendable {
        private let ends = Mutex<[PendingContextEnd]>([])
        func append(_ end: PendingContextEnd) { ends.withLock { $0.append(end) } }
        var all: [PendingContextEnd] { ends.withLock { $0 } }
    }

    static func ends(_ context: PendingContext) -> Heard {
        let heard = Heard()
        context.onEnd { heard.append($0) }
        return heard
    }

    static func settle(until condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end, !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func make(_ work: Work, bound: Bound = Bound(), handle: UInt64 = 1) -> PendingContext {
        PendingContext(handle: PendingContextHandle(id: handle), fallback: Self.first, bound: .seconds(5),
                       sleep: { await bound.sleep($0) }, work: { await work.run() })
    }

    @Test func itSettlesToWhatTheWorkAnswered() async {
        let work = Work()
        let context = make(work)
        let heard = Self.ends(context)
        await Self.settle { work.started.withLock { $0 } }
        #expect(context.end == nil, "it ended before the work answered")
        work.answer(Self.grown)
        await Self.settle { context.end != nil }
        #expect(context.end == .settled(Self.grown))
        await Self.settle { !heard.all.isEmpty }
        #expect(heard.all == [.settled(Self.grown)])
    }

    /// **Nothing grown leaves the first reading**: a work that answers nil settles to the reading handed over first.
    @Test func nothingGrownLeavesTheFirstReading() async {
        let work = Work()
        let context = make(work)
        work.answer(nil)
        await Self.settle { context.end != nil }
        #expect(context.end == .settled(Self.first))
    }

    /// **The handle's cancel** (carried from WI-1): it ends the context at once, cancelled, tells the work, and an answer that
    /// comes after changes nothing. Red if `cancel` only cancels the work and waits for it to say so.
    @Test func cancellingEndsItOnceAndStopsTheWork() async {
        let work = Work()
        let context = make(work)
        let heard = Self.ends(context)
        await Self.settle { work.started.withLock { $0 } }
        context.cancel()
        #expect(context.end == .cancelled, "cancel did not end the context at once")
        await Self.settle { work.cancelled.withLock { $0 } }
        #expect(work.cancelled.withLock { $0 }, "the work was never told")
        work.answer(Self.grown)
        await context.finished()
        context.cancel()
        #expect(context.end == .cancelled)
        #expect(heard.all == [.cancelled], "heard \(heard.all)")
    }

    /// **Past its bound the first reading stands, and the work is still waited for** (decision 8): the context ends overdue
    /// with the reading handed over first, while `finished` — what the capture guard waits on — returns only when the work
    /// itself does. Red if the bound releases the work's waiter, or the work's late answer replaces the ending.
    @Test func pastItsBoundTheFirstReadingStandsAndTheWorkIsStillAwaited() async {
        let work = Work(), bound = Bound()
        let context = make(work, bound: bound)
        await Self.settle { work.started.withLock { $0 } }
        bound.pass()
        await Self.settle { context.end != nil }
        #expect(context.end == .overdue(Self.first))
        let finished = Mutex(false)
        let waiter = Task { await context.finished(); finished.withLock { $0 = true } }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!finished.withLock { $0 }, "the work was let go of at the bound")
        work.answer(Self.grown)
        await waiter.value
        #expect(context.end == .overdue(Self.first), "a late answer replaced the ending")
    }

    /// **Exactly one ending, heard once by every listener**, whether it listened before or after.
    @Test func everyListenerHearsTheOneEndOnce() async {
        let work = Work()
        let context = make(work)
        let before = Self.ends(context)
        work.answer(Self.grown)
        await Self.settle { context.end != nil }
        context.cancel()
        let after = Self.ends(context)
        await Self.settle { before.all.count == 1 }
        #expect(before.all == [.settled(Self.grown)])
        #expect(after.all == [.settled(Self.grown)])
    }

    /// **Metadata only**: no description, debug description or dump of a context names a word of its sentence.
    @Test func noDescriptionOfAContextCarriesTheSentence() async {
        let work = Work()
        let context = make(work)
        work.answer(Self.grown)
        await Self.settle { context.end != nil }
        var dumped = ""
        dump(context, to: &dumped)
        for text in [String(describing: context), String(reflecting: context), dumped, String(describing: context.end)] {
            #expect(!text.contains("tide") && !text.contains("night"), "a context described its sentence: \(text)")
        }
    }
}

/// **The contexts still being read, by handle** — where the consumer's session finds the one a term names, and **bounded**,
/// so a context nobody claims cannot outlive its request by more than a few newer ones.
struct PendingContextsTests {
    @Test func aStartedContextIsFoundByItsHandleUntilCancelled() {
        let contexts = PendingContexts()
        let work = PendingContextTests.Work()
        let started = contexts.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { await work.run() })
        #expect(contexts.context(started.handle) === started)
        contexts.cancel(started.handle)
        #expect(contexts.context(started.handle) == nil, "a cancelled context was still offered")
        #expect(started.end == .cancelled)
        work.answer(nil)
    }

    @Test func handlesAreNeverReused() {
        let contexts = PendingContexts()
        let first = contexts.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { nil })
        contexts.cancel(first.handle)
        let second = contexts.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { nil })
        #expect(first.handle != second.handle)
    }

    /// Past its capacity the oldest is cancelled and forgotten. Red without the bound.
    @Test func theOldestIsCancelledPastTheCapacity() {
        let contexts = PendingContexts()
        let work = PendingContextTests.Work()
        let started = (0...PendingContexts.capacity).map { _ in
            contexts.start(fallback: PendingContextTests.first, bound: .seconds(5), work: { await work.run() })
        }
        #expect(started[0].end == .cancelled)
        #expect(contexts.context(started[0].handle) == nil)
        #expect(contexts.count == PendingContexts.capacity)
        for context in started { contexts.cancel(context.handle) }
    }
}
