import Synchronization

/// **The one screen capture that may be in flight** (ported from XiaolaiDict's `HoverReader.CaptureGuard`, plan-capture
/// WI-4; XDict ADR-0014 decision 8). Two simultaneous `SCScreenshotManager` captures deadlock each other, so a second is
/// refused rather than started — and the guard is released **only by the capture's own end**, never by a deadline: a
/// capture blocked in the framework cannot be cancelled, and letting go of it would rebuild the deadlock this prevents.
///
/// It records when it was claimed, so a capture held past its deadline can say so — once per wedge, and its recovery once.
public final class CaptureGuard: Sendable {
    private struct State {
        var claimedAt: ContinuousClock.Instant?
        /// This wedge has been reported. Cleared on release, so each wedge is reported once.
        var reported = false
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// True if this caller now holds it; false means a capture is in flight.
    public func claim() -> Bool {
        let at = now()
        return state.withLock { state in
            guard state.claimedAt == nil else { return false }
            state.claimedAt = at
            return true
        }
    }

    /// Releases it, answering how long it was held and whether its wedge had been reported.
    @discardableResult
    public func release() -> (held: Duration, wasReported: Bool) {
        let at = now()
        return state.withLock { state in
            let held = state.claimedAt.map { at - $0 } ?? .zero
            let reported = state.reported
            state = State()
            return (held, reported)
        }
    }

    public var isHeld: Bool { state.withLock { $0.claimedAt != nil } }

    /// How long the capture in flight has been held, or nil where none is.
    public func heldFor() -> Duration? {
        let at = now()
        return state.withLock { $0.claimedAt.map { at - $0 } }
    }

    /// How long the capture in flight has been held, where that is past `deadline`.
    public func overdue(after deadline: Duration) -> Duration? {
        let at = now()
        return state.withLock { state in
            guard let claimed = state.claimedAt, at - claimed > deadline else { return nil }
            return at - claimed
        }
    }

    /// True the first time a wedge is reported, false after.
    public func markReported() -> Bool {
        state.withLock { state in
            guard state.claimedAt != nil, !state.reported else { return false }
            state.reported = true
            return true
        }
    }
}
