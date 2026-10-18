import Synchronization

/// How a pending context ended — **exactly once** (ADR-0014 decision 8).
public enum PendingContextEnd: Sendable, Equatable {
    /// The reading answered: the context it settled to (the first reading, where nothing grew).
    case settled(ContextOutcome)
    /// Nobody will show it any more — replaced, closed or refused — and nothing it answers later is used.
    case cancelled
    /// Not answered within its bound: the first reading stands. The work may still be running, and whatever it holds
    /// (the one capture) stays held until it returns.
    case overdue(ContextOutcome)
}

/// **The rest of a sentence still being read** (ported from XiaolaiDict's `PendingContext`, plan-capture WI-4): a pixel
/// read hands the word over at once, with `.pending(handle)` as its context, and a taller strip goes on being read. This is
/// what that reading settles to, and the handle that cancels it.
///
/// - **Exactly one ending**: the work's answer, a cancellation, or overdue past `bound` with `fallback` (the first reading)
///   standing; whichever comes first is the only one, and every listener hears it once.
/// - **Cancelling ends it at once** and cancels the work; **the work is waited for apart from the ending** (`finished`),
///   because a capture blocked in the framework cannot be stopped and the guard it holds must not be let go while it runs.
/// - **Memory only, described by metadata alone** (decision 9): nothing here is `Codable`, and no description, debug
///   description or dump names a word of the sentence.
public final class PendingContext: Sendable {
    public let handle: PendingContextHandle
    private let fallback: ContextOutcome

    private struct State {
        var end: PendingContextEnd?
        var listeners: [@Sendable (PendingContextEnd) -> Void] = []
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    /// The work, started at once. Set once, in `init`, before anything can read it.
    private let work = Mutex<Task<Void, Never>?>(nil)
    /// What the book that numbered it does when it is cancelled: forget it. Set once, by `PendingContexts.start`.
    private let release = Mutex<(@Sendable () -> Void)?>(nil)

    /// Starts `work` now. It answers the grown context, or nil where the first reading stands. `sleep` is the bound's
    /// clock, a seam for the tests.
    public init(
        handle: PendingContextHandle, fallback: ContextOutcome, bound: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        work body: @escaping @Sendable () async -> ContextOutcome?
    ) {
        self.handle = handle
        self.fallback = fallback
        let task = Task { [fallback] in
            let answer = await body()
            self.finish(.settled(answer ?? fallback))
        }
        work.withLock { $0 = task }
        let timer = Task { [fallback] in
            await sleep(bound)
            guard !Task.isCancelled else { return }
            self.finish(.overdue(fallback))
        }
        let ended = state.withLock { state -> Bool in
            guard state.end == nil else { return true }
            state.timer = timer
            return false
        }
        if ended { timer.cancel() }
    }

    /// How it ended, or nil while it is still being read.
    public var end: PendingContextEnd? { state.withLock { $0.end } }

    /// Tells `handler` the one ending — now, where it has already ended, otherwise when it does — outside the lock.
    public func onEnd(_ handler: @escaping @Sendable (PendingContextEnd) -> Void) {
        let ended = state.withLock { state -> PendingContextEnd? in
            if let end = state.end { return end }
            state.listeners.append(handler)
            return nil
        }
        if let ended { handler(ended) }
    }

    /// Nobody will show this context: it ends cancelled now, the work is told, **and the book forgets it** — whoever
    /// cancels it, and whether or not it had already ended, so a context let go keeps no sentence for later.
    public func cancel() {
        finish(.cancelled)
        work.withLock { $0 }?.cancel()
        release.withLock { $0 }?()
    }

    /// The book's hook, set once.
    fileprivate func released(by forget: @escaping @Sendable () -> Void) {
        release.withLock { $0 = forget }
    }

    /// Returns when the work itself has returned — which may be long after the context ended.
    public func finished() async {
        await work.withLock { $0 }?.value
    }

    private func finish(_ end: PendingContextEnd) {
        let (listeners, timer) = state.withLock { state -> ([@Sendable (PendingContextEnd) -> Void], Task<Void, Never>?) in
            guard state.end == nil else { return ([], nil) }
            state.end = end
            defer { state.listeners = []; state.timer = nil }
            return (state.listeners, state.timer)
        }
        timer?.cancel()
        for listener in listeners { listener(end) }
    }
}

extension PendingContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let end: String = switch self.end {
        case nil: "pending"
        case .settled: "settled"
        case .cancelled: "cancelled"
        case .overdue: "overdue"
        }
        return "PendingContext(\(handle.id), \(end))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension PendingContextEnd: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .settled(let outcome): "settled(\(outcome))"
        case .cancelled: "cancelled"
        case .overdue(let outcome): "overdue(\(outcome))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// **The contexts still being read, by handle**: where whoever holds a term's `.pending(handle)` finds the reading, and
/// the one place a handle is numbered. A context leaves when it is cancelled, by the book or by whoever holds it, and
/// when the session that held it has taken what it settled to (`forget`). **Bounded**: past `capacity` the oldest is
/// cancelled and forgotten, so a context nobody claimed cannot outlive its request by more than a few newer ones.
public final class PendingContexts: Sendable {
    /// How many contexts may be held at once. A count, not a design value: one is presented at a time, and a few more may
    /// be in flight between a read and its presentation.
    public static let capacity = 8

    private struct State {
        var issued: UInt64 = 0
        var live: [UInt64: PendingContext] = [:]
        var order: [UInt64] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// A context for `work`, started now, under a fresh handle.
    public func start(
        fallback: ContextOutcome, bound: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        work: @escaping @Sendable () async -> ContextOutcome?
    ) -> PendingContext {
        let handle = state.withLock { state -> PendingContextHandle in
            state.issued += 1
            return PendingContextHandle(id: state.issued)
        }
        let context = PendingContext(handle: handle, fallback: fallback, bound: bound, sleep: sleep, work: work)
        context.released { [weak self] in self?.forget(handle) }
        let evicted = state.withLock { state -> [PendingContext] in
            state.live[handle.id] = context
            state.order.append(handle.id)
            var evicted: [PendingContext] = []
            while state.order.count > Self.capacity {
                let oldest = state.order.removeFirst()
                if let gone = state.live.removeValue(forKey: oldest) { evicted.append(gone) }
            }
            return evicted
        }
        for gone in evicted { gone.cancel() }
        return context
    }

    /// The context under `handle`, or nil where it was cancelled or never started here.
    public func context(_ handle: PendingContextHandle) -> PendingContext? {
        state.withLock { $0.live[handle.id] }
    }

    /// Cancels the context under `handle` and forgets it. Nothing where there is none.
    public func cancel(_ handle: PendingContextHandle) {
        let gone = state.withLock { state -> PendingContext? in
            state.order.removeAll { $0 == handle.id }
            return state.live.removeValue(forKey: handle.id)
        }
        gone?.cancel()
    }

    /// Forgets the context under `handle` without cancelling it: its holder has what it ended with.
    public func forget(_ handle: PendingContextHandle) {
        state.withLock { state in
            state.order.removeAll { $0 == handle.id }
            state.live[handle.id] = nil
        }
    }

    public var count: Int { state.withLock { $0.live.count } }
}
