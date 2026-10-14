import Foundation
import Synchronization

/// **The service ends itself when idle** (ADR-0009 decision 4): malloc keeps freed large blocks for reuse, so after one
/// 63 MiB reply the service stayed at 385 MiB (spike 2), and the documented way to give that back is to end the
/// process; launchd starts it again on the next request, and the client reopens its dictionaries (`staleHandle` →
/// `open`).
///
/// **Never with work in flight.** A request is in flight from the moment its message reaches the service (`begin`) until
/// its reply has been handed to XPC (`end`); an import is a request, and its progress events go out while it is in
/// flight. The decision to exit and the exit itself happen **holding the same lock `begin` takes**, so a request racing
/// the timer either began first — then nothing is quiet and the timer only re-arms — or finds the process gone, and its
/// client hears the connection interrupted (`WireError.interrupted`, typed), never a reply cut off half-way. A reply handed
/// to XPC is sent from XPC's own queue at once; the quiet period, measured from the last `end`, is its margin.
///
/// **The quiet period is 30 s.** Shorter costs a relaunch between lookups a reader makes while reading one page; longer
/// keeps a few hundred MiB of freed blocks after a large reply for longer. A relaunch costs a process start and the
/// client's reopens (three packages reopened in 1.6 ms, spike 1), measured end to end by the E2E `service` stage
/// (`relaunchMilliseconds`); WI-10's cold lookups say whether it shows. Not conditioned on the footprint, as spike 2
/// suggested: an exit the reader cannot see is cheaper than a rule nobody can test.
final class IdleExit: Sendable {
    static let quietPeriod: Duration = .seconds(30)

    private struct State {
        var inFlight = 0
        var quietSince: ContinuousClock.Instant
        var exited = false
    }

    let quiet: Duration
    private let state: Mutex<State>
    private let now: @Sendable () -> ContinuousClock.Instant
    private let arm: @Sendable (Duration) -> Void
    private let exit: @Sendable (_ quietFor: Duration) -> Void

    /// `arm(d)` sets the one timer to call `timerFired()` after `d`, replacing any earlier setting. `exit` ends the
    /// process; it is called holding the lock, and in production never returns.
    init(quiet: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant,
         arm: @escaping @Sendable (Duration) -> Void, exit: @escaping @Sendable (_ quietFor: Duration) -> Void) {
        self.quiet = quiet
        self.now = now
        self.arm = arm
        self.exit = exit
        state = Mutex(State(quietSince: now()))
    }

    /// The process has started: quiet from now.
    func start() {
        arm(quiet)
    }

    /// A request has arrived. False only once the exit has been decided, which in production cannot be observed: the
    /// process ends holding the lock this waits for.
    func begin() -> Bool {
        state.withLock { state in
            guard !state.exited else { return false }
            state.inFlight += 1
            return true
        }
    }

    /// A request's reply has been handed to XPC (or it was dropped): when it was the last, quiet starts now.
    func end() {
        let quietNow = state.withLock { state -> Bool in
            state.inFlight = max(0, state.inFlight - 1)
            guard state.inFlight == 0 else { return false }
            state.quietSince = now()
            return true
        }
        if quietNow { arm(quiet) }
    }

    func timerFired() {
        state.withLock { state in
            guard !state.exited, state.inFlight == 0 else { return }
            let quietFor = now() - state.quietSince
            guard quietFor >= quiet else {
                arm(quiet - quietFor)
                return
            }
            state.exited = true
            exit(quietFor)
        }
    }

    /// For tests and the log.
    var inFlight: Int {
        state.withLock { $0.inFlight }
    }

    /// The service's: a strict dispatch timer (a timer coalesced by seconds would make the quiet period a range), and an
    /// exit that logs why.
    static func production(quiet: Duration = quietPeriod, onExit: @escaping @Sendable (_ quietFor: Duration) -> Void) -> IdleExit {
        let timer = OneTimer(queue: DispatchQueue(label: "ai.xdict.app.DictionaryService.idle"))
        let idle = IdleExit(quiet: quiet, now: { ContinuousClock.now }, arm: { timer.arm(after: $0) }, exit: { quietFor in
            onExit(quietFor)
            Foundation.exit(0)
        })
        timer.start { idle.timerFired() }
        return idle
    }
}

/// One dispatch timer, re-armed in place. `@unchecked Sendable`: `DispatchSourceTimer` is thread-safe by its
/// documentation but not declared `Sendable`.
private final class OneTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    }

    func start(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func arm(after duration: Duration) {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = max(0, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        source.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .never, leeway: .milliseconds(1))
    }
}
