import Synchronization

/// **The one screen capture that may be in flight, and at most one given up on** (ported from XiaolaiDict's
/// `HoverReader.CaptureGuard`, plan-capture WI-4; XDict ADR-0014 decision 8).
///
/// A capture is released **only by its own end**, never by a deadline: work blocked in a framework cannot be cancelled.
/// But a capture held past `abandonAfter` **is given up on once** — set aside, still running, so the next hover may start
/// its own (owner, 2026-10-19: a first capture stalled in Vision's model load, measured 24 s after a few minutes idle,
/// refused every capture after it). **Never more than one is set aside**: while one still runs, a second stall refuses as
/// before, so stalled work can never pile up. Two ScreenCaptureKit screenshots at once deadlock each other (XiaolaiDict
/// ADR-0016, 6 trials of 6); that rule is kept where the screenshot is taken (`ScreenshotGate`), so a capture set aside
/// while blocked in ScreenCaptureKit makes the next one's screenshot refuse rather than start a second.
///
/// It records when each was claimed, so a capture held past its deadline can say so — once per wedge, and its recovery
/// once.
public final class CaptureGuard: Sendable {
    /// Which claim a release, a report or a check is about.
    public struct Ticket: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private struct Held {
        let id: UInt64
        let claimedAt: ContinuousClock.Instant
        /// This wedge has been reported. Each wedge is reported once.
        var reported = false
    }

    private struct State {
        var current: Held?
        /// The one capture given up on, still running.
        var abandoned: Held?
        var next: UInt64 = 0
    }

    /// How long a capture may hold the guard before the next hover may set it aside: past every warm read measured
    /// (XiaolaiDict 250–570 ms warm, 0.8–1.8 s cold; XDict 60–170 ms warm, 2026-10-19), short of the 5 s deadline.
    public static let abandonAfter: Duration = .seconds(2)

    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant
    private let abandonAfter: Duration

    public init(
        abandonAfter: Duration = CaptureGuard.abandonAfter,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.abandonAfter = abandonAfter
        self.now = now
    }

    /// A ticket if this caller now holds it; nil means a capture is in flight that may not be set aside — it has not held
    /// the guard for `abandonAfter`, or one is already set aside.
    public func claim() -> Ticket? {
        let at = now()
        return state.withLock { state in
            if let current = state.current {
                guard state.abandoned == nil, at - current.claimedAt >= abandonAfter else { return nil }
                state.abandoned = current
            }
            state.next += 1
            state.current = Held(id: state.next, claimedAt: at)
            return Ticket(id: state.next)
        }
    }

    /// Releases `ticket` — the current capture, or the one set aside — answering how long it was held and whether its
    /// wedge had been reported. A ticket that holds nothing answers zero.
    @discardableResult
    public func release(_ ticket: Ticket) -> (held: Duration, wasReported: Bool) {
        let at = now()
        return state.withLock { state in
            if let current = state.current, current.id == ticket.id {
                state.current = nil
                return (at - current.claimedAt, current.reported)
            }
            if let abandoned = state.abandoned, abandoned.id == ticket.id {
                state.abandoned = nil
                return (at - abandoned.claimedAt, abandoned.reported)
            }
            return (.zero, false)
        }
    }

    /// A capture is in flight that has not been set aside.
    public var isHeld: Bool { state.withLock { $0.current != nil } }

    /// A capture set aside is still running.
    public var holdsAbandoned: Bool { state.withLock { $0.abandoned != nil } }

    /// Whether `ticket` is the capture in flight (not set aside, not released).
    public func isCurrent(_ ticket: Ticket) -> Bool { state.withLock { $0.current?.id == ticket.id } }

    /// How long the capture in flight has been held, or nil where none is.
    public func heldFor() -> Duration? {
        let at = now()
        return state.withLock { $0.current.map { at - $0.claimedAt } }
    }

    /// How long the capture in flight has been held, where that is past `deadline`.
    public func overdue(after deadline: Duration) -> Duration? {
        let at = now()
        return state.withLock { state in
            guard let claimed = state.current?.claimedAt, at - claimed > deadline else { return nil }
            return at - claimed
        }
    }

    /// True the first time the capture in flight's wedge is reported, false after.
    public func markReported() -> Bool {
        state.withLock { state in
            guard state.current != nil, state.current?.reported == false else { return false }
            state.current?.reported = true
            return true
        }
    }
}

/// **One ScreenCaptureKit screenshot at a time, refused rather than queued** (XiaolaiDict ADR-0016: two at once deadlock
/// each other, 6 trials of 6). Released only when the screenshot returns: a screenshot blocked in the framework is never
/// let go of, so a capture `CaptureGuard` set aside while blocked there makes the next screenshot refuse.
public final class ScreenshotGate: Sendable {
    private let busy = Mutex(false)

    public init() {}

    /// True if this caller may take the screenshot now; it must call `done()` when the screenshot returns.
    public func enter() -> Bool {
        busy.withLock { busy in
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    public func done() { busy.withLock { $0 = false } }
}
