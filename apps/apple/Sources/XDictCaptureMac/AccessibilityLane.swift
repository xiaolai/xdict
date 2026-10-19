import ApplicationServices
import Synchronization

/// Which kind of read is asking: one the reader asked for (the shortcut, the Service, the menu) or a hover.
public enum LaneWork: String, Sendable, Equatable {
    case explicit
    case hover
}

/// Why a read was not run, or not waited for — **typed, never a silent drop** (XDict ADR-0014 decision 6).
public enum LaneRefusal: Error, Sendable, Equatable {
    /// The caller moved on.
    case cancelled
    /// A newer request made this hover stale: a newer hover took its place in the queue, or an explicit read arrived.
    case superseded
    /// It waited in the queue past its kind's residence bound, behind reads that were still within theirs.
    case overstayed(waited: Duration)
    /// The read ahead of it — or this read itself — has run past its budget and the lane's overrun: **a call blocked in
    /// the framework, which nothing can cancel**. Reported, not hidden; the blocked read stays in the lane as the barrier
    /// every later read waits on, because a second read beside it would run into the same hung app.
    case stuck(blockedFor: Duration)
}

/// What the lane is doing now, for a consumer to word (a "capture stuck" notice is the consumer's, decision 4).
public enum LaneState: Sendable, Equatable {
    case idle
    case running(LaneWork)
    case stuck(LaneWork, blockedFor: Duration)
}

/// The lane's bounds, apart from each read's own budget.
public struct LaneBounds: Sendable, Equatable {
    /// How long an explicit request may wait in the queue: past the read in flight's messaging timeout, so a press that
    /// cancelled the read before it still runs, and short of leaving the reader with nothing behind a hung app.
    public let explicitResidence: Duration
    /// How long a hover may wait: a hover older than this is about a place the pointer has left.
    public let hoverResidence: Duration
    /// How far past its budget a read may run before it is reported stuck: one request in flight at the longest
    /// messaging timeout, which the budget check between requests cannot interrupt.
    public let overrun: Duration

    /// Nil unless every bound is positive: a bound of zero drops everything and says nothing about why.
    public init?(explicitResidence: Duration, hoverResidence: Duration, overrun: Duration) {
        guard explicitResidence > .zero, hoverResidence > .zero, overrun > .zero else { return nil }
        self.init(checked: explicitResidence, hoverResidence, overrun)
    }

    private init(checked explicitResidence: Duration, _ hoverResidence: Duration, _ overrun: Duration) {
        self.explicitResidence = explicitResidence
        self.hoverResidence = hoverResidence
        self.overrun = overrun
    }

    /// Written together with the timeouts they bound: an explicit read's messaging timeout is a second, a hover's a
    /// quarter of one (`AccessibilitySession`, `PointerWordReader`). All positive, so the check is not needed.
    public static let shipped = LaneBounds(checked: .milliseconds(1_500), .milliseconds(250), .seconds(1))
}

/// **Every out-of-process Accessibility read, one at a time** — the selection shortcut's, the Service's and hover's
/// alike (XDict ADR-0014 decision 6; ported from XiaolaiDict's `AccessibilityLane`, ADR-0046 there, and given the rules
/// a plain FIFO lacked).
///
/// One lane because the messaging timeout is process-wide — set on the system-wide element it binds every element this
/// process asks (`AXUIElement.h`) — so two reads at once changed each other's timeout mid-read; and because a read
/// cancelled mid-way is still finishing the one request in flight, and the next must not run beside it into the same app.
/// The lane sets the timeout on entry, for the one read it lets run. Its rules:
///
/// - **explicit requests run before hover work**: an explicit request goes to the front of the queue, ahead of every
///   hover, and makes every hover already queued or running stale — the running one is cancelled between requests and
///   its caller answered at once;
/// - **hover work is coalesced**: a newer hover replaces the one waiting, so a flood leaves at most one queued;
/// - **residence is bounded as well as execution**: an item that waited past its kind's bound is answered
///   `overstayed` (or `stuck`, when what held it is a blocked read) and never run;
/// - **a blocked read is reported**: past its budget and the overrun its caller is answered `stuck`, the lane says so,
///   and it stays as the barrier — a call inside the framework cannot be cancelled, only waited for.
///
/// An Accessibility request about *this* process is not IPC and never comes through here: it is serviced on the calling
/// thread, which must be the main actor (XiaolaiDict ADR-0042; `SelectionReader.read(from:)`, and hover's
/// `SystemPointerWords.ownTarget` and `readOwnUnlessRefused`).
public final class AccessibilityLane: Sendable {
    public static let system = AccessibilityLane { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), $0) }

    private let setTimeout: @Sendable (Float) -> Void
    private let bounds: LaneBounds
    private let state = Mutex(State())

    public init(bounds: LaneBounds = .shipped, setTimeout: @escaping @Sendable (Float) -> Void) {
        self.bounds = bounds
        self.setTimeout = setTimeout
    }

    /// Runs `work` detached, after the read in flight and every explicit request ahead of it, under `timeout`, or answers
    /// why not. `budget` is the read's own (its session's), against which the lane decides it is stuck. Cancellation of
    /// the caller is passed on to the work, which sees it between requests; **the caller is answered at once**, not
    /// after the read finishes its request in flight.
    public func submit<T: Sendable>(
        _ kind: LaneWork, timeout: Float, budget: Duration, _ work: @escaping @Sendable () -> T
    ) async -> Result<T, LaneRefusal> {
        // A caller cancelled already does no work, even on an idle lane.
        if Task.isCancelled { return .failure(.cancelled) }
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.allocated.insert(state.nextID)
            return state.nextID
        }
        let reply = Reply<T>()
        let setTimeout = setTimeout
        let item = Item(
            id: id, kind: kind, enqueued: .now, budget: budget,
            start: { [self] in
                Task.detached(priority: .userInitiated) {
                    setTimeout(timeout)
                    let value = work()
                    self.finished(id)
                    reply.give(.success(value))
                }
            },
            refuse: { reply.give(.failure($0)) })
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply.install(continuation)
                enqueue(item)
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// `submit`, answering a refusal with `refused(…)` — for a caller whose outcome type has its own cancelled case.
    public func run<T: Sendable>(
        _ kind: LaneWork = .explicit, timeout: Float, budget: Duration = .seconds(2), _ work: @escaping @Sendable () -> T,
        refused: @escaping @Sendable (LaneRefusal) -> T
    ) async -> T {
        switch await submit(kind, timeout: timeout, budget: budget, work) {
        case .success(let value): value
        case .failure(let refusal): refused(refusal)
        }
    }

    /// What the lane is doing now.
    public func current() -> LaneState {
        state.withLock { state in
            guard let running = state.running else { return .idle }
            let elapsed = ContinuousClock.now - running.started
            return elapsed > running.budget + bounds.overrun ? .stuck(running.kind, blockedFor: elapsed) : .running(running.kind)
        }
    }

    /// How many explicit requests and hovers wait (at most one hover: they are coalesced).
    public func queued() -> (explicit: Int, hover: Int) {
        state.withLock { ($0.explicit.count, $0.hover == nil ? 0 : 1) }
    }

    // MARK: - The queue

    private struct Item: Sendable {
        let id: UInt64
        let kind: LaneWork
        let enqueued: ContinuousClock.Instant
        let budget: Duration
        let start: @Sendable () -> Task<Void, Never>
        let refuse: @Sendable (LaneRefusal) -> Void
    }

    private struct Running: Sendable {
        let id: UInt64
        let kind: LaneWork
        let started: ContinuousClock.Instant
        let budget: Duration
        let refuse: @Sendable (LaneRefusal) -> Void
        let task: Task<Void, Never>
    }

    private struct State: Sendable {
        var nextID: UInt64 = 0
        /// Numbered and not yet queued: a cancellation for one of these arrives before its item, and is kept for it.
        var allocated: Set<UInt64> = []
        var cancelledEarly: Set<UInt64> = []
        var explicit: [Item] = []
        var hover: Item?
        var running: Running?
    }

    private typealias Refusals = [(refuse: @Sendable (LaneRefusal) -> Void, why: LaneRefusal)]

    private func enqueue(_ item: Item) {
        let refusals = state.withLock { state -> Refusals in
            state.allocated.remove(item.id)
            if state.cancelledEarly.remove(item.id) != nil { return [(item.refuse, .cancelled)] }
            var refusals: Refusals = []
            if let waiting = state.hover {
                refusals.append((waiting.refuse, .superseded))
                state.hover = nil
            }
            switch item.kind {
            case .hover:
                state.hover = item
            case .explicit:
                if let running = state.running, running.kind == .hover {
                    running.task.cancel()
                    refusals.append((running.refuse, .superseded))
                }
                state.explicit.append(item)
            }
            return refusals
        }
        for refusal in refusals { refusal.refuse(refusal.why) }
        let residence = item.kind == .explicit ? bounds.explicitResidence : bounds.hoverResidence
        Task { [self] in
            try? await Task.sleep(for: residence)
            expire(item.id)
        }
        pump()
    }

    /// Starts the next item if nothing runs: explicit first, then the one hover. An item past its residence is answered
    /// and skipped, never started.
    private func pump() {
        let refusals = state.withLock { state -> Refusals in
            var refusals: Refusals = []
            guard state.running == nil else { return refusals }
            while true {
                let item: Item
                if !state.explicit.isEmpty {
                    item = state.explicit.removeFirst()
                } else if let hover = state.hover {
                    state.hover = nil
                    item = hover
                } else {
                    return refusals
                }
                let waited = ContinuousClock.now - item.enqueued
                if waited > (item.kind == .explicit ? bounds.explicitResidence : bounds.hoverResidence) {
                    refusals.append((item.refuse, .overstayed(waited: waited)))
                    continue
                }
                state.running = Running(id: item.id, kind: item.kind, started: .now, budget: item.budget,
                                        refuse: item.refuse, task: item.start())
                watch(item.id, after: item.budget + bounds.overrun)
                return refusals
            }
        }
        for refusal in refusals { refusal.refuse(refusal.why) }
    }

    /// Past its budget and the overrun, a read still running is blocked in the framework: its caller is told so.
    private func watch(_ id: UInt64, after limit: Duration) {
        Task { [self] in
            try? await Task.sleep(for: limit)
            let refuse = state.withLock { state -> (@Sendable (LaneRefusal) -> Void, Duration)? in
                guard let running = state.running, running.id == id else { return nil }
                return (running.refuse, ContinuousClock.now - running.started)
            }
            if case let (refuse, elapsed)? = refuse { refuse(.stuck(blockedFor: elapsed)) }
        }
    }

    private func finished(_ id: UInt64) {
        state.withLock { state in
            if state.running?.id == id { state.running = nil }
        }
        pump()
    }

    private func cancel(_ id: UInt64) {
        let refuse = state.withLock { state -> (@Sendable (LaneRefusal) -> Void)? in
            if let index = state.explicit.firstIndex(where: { $0.id == id }) { return state.explicit.remove(at: index).refuse }
            if let hover = state.hover, hover.id == id {
                state.hover = nil
                return hover.refuse
            }
            if let running = state.running, running.id == id {
                // Stays as the barrier until its request in flight returns; only the caller is let go.
                running.task.cancel()
                return running.refuse
            }
            if state.allocated.contains(id) { state.cancelledEarly.insert(id) }
            return nil
        }
        refuse?(.cancelled)
    }

    private func expire(_ id: UInt64) {
        let refusal = state.withLock { state -> (@Sendable (LaneRefusal) -> Void, LaneRefusal)? in
            let item: Item
            if let index = state.explicit.firstIndex(where: { $0.id == id }) {
                item = state.explicit.remove(at: index)
            } else if let hover = state.hover, hover.id == id {
                state.hover = nil
                item = hover
            } else {
                return nil
            }
            if let running = state.running {
                let elapsed = ContinuousClock.now - running.started
                if elapsed > running.budget + bounds.overrun { return (item.refuse, .stuck(blockedFor: elapsed)) }
            }
            return (item.refuse, .overstayed(waited: ContinuousClock.now - item.enqueued))
        }
        if case let (refuse, why)? = refusal { refuse(why) }
    }
}

/// One caller's answer, given once: the first of the work's value and a refusal wins, whichever thread gives it and
/// whether or not the caller has started waiting yet.
private final class Reply<T: Sendable>: Sendable {
    private struct Slot {
        var continuation: CheckedContinuation<Result<T, LaneRefusal>, Never>?
        var answer: Result<T, LaneRefusal>?
        var delivered = false
    }

    private let slot = Mutex(Slot())

    func install(_ continuation: CheckedContinuation<Result<T, LaneRefusal>, Never>) {
        let ready = slot.withLock { slot -> Result<T, LaneRefusal>? in
            guard let answer = slot.answer else {
                slot.continuation = continuation
                return nil
            }
            slot.delivered = true
            return answer
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func give(_ answer: Result<T, LaneRefusal>) {
        let waiting = slot.withLock { slot -> CheckedContinuation<Result<T, LaneRefusal>, Never>? in
            guard slot.answer == nil, !slot.delivered else { return nil }
            slot.answer = answer
            guard let continuation = slot.continuation else { return nil }
            slot.continuation = nil
            slot.delivered = true
            return continuation
        }
        waiting?.resume(returning: answer)
    }
}
