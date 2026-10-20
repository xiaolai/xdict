import Synchronization

/// **The one ephemeral session a captured sentence lives in** (ADR-0014 decision 9): owned by the capture side, handed
/// the context of the request being presented, and nothing else. Only the term goes to search, the service, the trail and
/// the observation hooks; the context stays here.
///
/// - **One context at a time**: the next presentation's replaces it.
/// - **In memory only**: nothing here is `Codable`, nothing writes it anywhere, and presentation's end drops it.
/// - **Metadata only in every description** (`CustomStringConvertible`, `CustomDebugStringConvertible`, an empty
///   mirror), so a log line, a `dump` or an observation hook that touches the session writes no word of the sentence.
///   `.private` logging is still logging; the guarantee is no persistence or diagnostic written by the application.
public final class CaptureContextSession: Sendable {
    private struct Held: Sendable {
        let request: Int
        let generation: Int
        /// The word the context's range must hold, kept so a **settled** context is validated as the constructor's was.
        let term: String
        let context: ContextOutcome
    }

    private let held = Mutex<Held?>(nil)

    /// **The contexts still being read** (plan-capture WI-4): a held `.pending(handle)` is found here, becomes what its
    /// reading settles to, and is cancelled when the presentation it was held for is replaced, ends or closes — so it never
    /// outlives that presentation (ADR-0014 decision 8). The reader starts its pending contexts in this same book.
    public let pending: PendingContexts

    public init(pending: PendingContexts = PendingContexts()) {
        self.pending = pending
    }

    /// Holds `term`'s context for `request`'s delivery of `generation`, dropping whatever was held before — and
    /// cancelling the reading a dropped pending context was waiting for. The context passes the constructor's boundary
    /// here too (a value the term's own `make` already checked; checked again so no path reaches this session unvalidated),
    /// with a refusal held as no context (fail-closed). A pending handle the book does not hold is no context either
    /// (fail-closed: never a context waiting forever).
    public func hold(_ term: CapturedTerm, request: Int, generation: Int) {
        var context = (try? CapturedTerm.checkedContext(term.context, term: term.term)) ?? .unavailable(.notCaptured)
        var waiting: PendingContext?
        if case .pending(let handle) = context {
            waiting = pending.context(handle)
            if waiting == nil { context = .unavailable(.notCaptured) }
        }
        let held = context
        let dropped = self.held.withLock { current -> PendingContextHandle? in
            defer {
                current = Held(request: request, generation: generation, term: term.term, context: held)
            }
            return current.flatMap { Self.handle(of: $0.context) }
        }
        if let dropped, dropped != Self.handle(of: held) { pending.cancel(dropped) }
        waiting?.onEnd { [weak self] end in self?.settle(request: request, generation: generation, end) }
    }

    /// The reading behind a held pending context ended: what it settled to replaces it, if it is still the one held —
    /// **and the book forgets it**, so the sentence lives here alone and goes with its request (`end`, `clear`).
    private func settle(request: Int, generation: Int, _ end: PendingContextEnd) {
        // The term is read under the lock, the validation runs outside it, and the store re-checks that this request's
        // pending context is still the one held — a newer hold in between wins.
        guard let (pendingHandle, term) = held.withLock({ held -> (PendingContextHandle, String)? in
            guard let current = held, current.request == request, current.generation == generation,
                  case .pending(let handle) = current.context else { return nil }
            return (handle, current.term)
        }) else { return }
        let outcome: ContextOutcome
        switch end {
        case .settled(let settled), .overdue(let settled):
            // **A settled context passes the boundary the constructor holds**: an over-ceiling sentence, a range outside
            // its sentence or one holding another term is refused as no context (fail-closed), never installed as read.
            // A settlement that is itself pending is no settlement: a reader's handle is not a sentence.
            if case .pending = settled {
                outcome = .unavailable(.notCaptured)
            } else {
                outcome = (try? CapturedTerm.checkedContext(settled, term: term)) ?? .unavailable(.notCaptured)
            }
        case .cancelled: outcome = .unavailable(.notCaptured)
        }
        let taken = held.withLock { held -> PendingContextHandle? in
            guard let current = held, current.request == request, current.generation == generation,
                  case .pending(let handle) = current.context, handle == pendingHandle else { return nil }
            held = Held(request: request, generation: generation, term: term, context: outcome)
            return handle
        }
        if let taken { pending.forget(taken) }
    }

    private static func handle(of context: ContextOutcome) -> PendingContextHandle? {
        if case .pending(let handle) = context { return handle }
        return nil
    }

    /// The context held for exactly this request and generation, or nil.
    public func context(request: Int, generation: Int) -> ContextOutcome? {
        held.withLock { held in
            guard let held, held.request == request, held.generation == generation else { return nil }
            return held.context
        }
    }

    /// `request`'s presentation ended: its context goes, and a reading it was waiting for is cancelled. Another request's
    /// end leaves it.
    public func end(request: Int) {
        let dropped = held.withLock { held -> PendingContextHandle? in
            guard let current = held, current.request == request else { return nil }
            held = nil
            return Self.handle(of: current.context)
        }
        if let dropped { pending.cancel(dropped) }
    }

    /// Everything goes: presentation closed. A reading the held context was waiting for is cancelled.
    public func clear() {
        let dropped = held.withLock { held -> PendingContextHandle? in
            defer { held = nil }
            return held.flatMap { Self.handle(of: $0.context) }
        }
        if let dropped { pending.cancel(dropped) }
    }

    public var isEmpty: Bool { held.withLock { $0 == nil } }
}

extension CaptureContextSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        held.withLock { held in
            held.map { "CaptureContextSession(request \($0.request), generation \($0.generation), \($0.context))" }
                ?? "CaptureContextSession(empty)"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
