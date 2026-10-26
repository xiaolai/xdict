import Foundation
import Synchronization
import XDictContract

/// **How much credited work the core runs at once, across every connection** — the decision `Credits` leaves to WI-3.
///
/// Credits bound one connection: two bulk calls, four lookup-class calls. A client whose credited call passes its
/// deadline abandons that connection for a new one with every credit (`Deadlines.abandonsConnectionOnExpiry`), but the
/// core cannot stop a read, so the abandoned calls keep running here. Without a ceiling the service would run two bulk
/// calls more for every abandonment, and spike 2 measured what that costs: four 63 MiB replies at once peaked it at
/// 1.75 GB.
///
/// **The ceiling is twice a connection's credits** (`ceiling(for:)`): the live connection's own, and one abandoned
/// connection's still draining. So the client that abandoned a stalled connection is answered at once on its new one —
/// the point of abandoning — while a second abandonment, before the first has drained, waits instead of adding more:
/// work beyond the ceiling **waits here, in order, and is never refused**. Refusing it would need a refusal the client
/// cannot have caused, and the contract's `tooManyInFlight` means a client's defect (`Refusal`), so the frozen contract has
/// no word for it; waiting costs only a deadline, which the client already handles by abandoning again. Waiting work whose
/// connection has ended never runs (`connectionEnded`): its client is gone. The wait is bounded by the core's own budgets,
/// since a running call reads at most one block (64 MiB) for a bulk call or `LOOKUP_BYTES` (256 MiB) for a lookup; a
/// read that never returns (a hung network volume) would hold its slot until the service ends, which no ceiling cures.
/// The memory bound is spike 2's measured worst: four 63 MiB bulk calls, 1.75 GB.
final class WorkGate: Sendable {
    private struct Waiting {
        let ticket: UInt64
        let connection: UInt64
        let run: @Sendable () -> Void
        let dropped: @Sendable () -> Void
    }

    private struct State {
        var running = 0
        var waiting: [Waiting] = []
        var nextTicket: UInt64 = 0
    }

    let ceiling: Int
    private let state = Mutex(State())

    init(ceiling: Int) {
        self.ceiling = ceiling
    }

    /// The ceiling for a credit class: two connections' worth.
    static func ceiling(for creditClass: CreditClass) -> Int {
        switch creditClass {
        case .bulk: 2 * Limits.bulkCallsInFlight
        case .lookup: 2 * Limits.lookupCallsInFlight
        }
    }

    /// Runs `run` now if the ceiling allows, else when a running call leaves, in arrival order. `run` must call
    /// `leave()` once when its core call has returned. `dropped` is called instead of `run` if `connection` ends first,
    /// or if the caller withdraws the ticket while it waits.
    @discardableResult
    func enter(connection: UInt64, run: @escaping @Sendable () -> Void, dropped: @escaping @Sendable () -> Void) -> UInt64 {
        let (now, ticket) = state.withLock { state -> (Bool, UInt64) in
            state.nextTicket += 1
            let ticket = state.nextTicket
            guard state.running < ceiling else {
                state.waiting.append(Waiting(ticket: ticket, connection: connection, run: run, dropped: dropped))
                return (false, ticket)
            }
            state.running += 1
            return (true, ticket)
        }
        if now { run() }
        return ticket
    }

    /// **Withdraws one waiting call** (audit rounds 1–4, 2026-10-26): work cancelled before its turn never runs, and its
    /// `dropped` answers the request now. False when it is not waiting — already running, or gone.
    @discardableResult
    func withdraw(_ ticket: UInt64) -> Bool {
        let gone = state.withLock { state -> Waiting? in
            guard let index = state.waiting.firstIndex(where: { $0.ticket == ticket }) else { return nil }
            return state.waiting.remove(at: index)
        }
        gone?.dropped()
        return gone != nil
    }

    /// A running call has finished: the next waiting one, if any, takes its place.
    func leave() {
        let next = state.withLock { state -> Waiting? in
            guard !state.waiting.isEmpty else {
                state.running = max(0, state.running - 1)
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.run()
    }

    /// `connection` has ended: its waiting work will never be asked for, so it never runs.
    func connectionEnded(_ connection: UInt64) {
        let dropped = state.withLock { state -> [Waiting] in
            let gone = state.waiting.filter { $0.connection == connection }
            state.waiting.removeAll { $0.connection == connection }
            return gone
        }
        for waiting in dropped { waiting.dropped() }
    }

    /// For tests and the log: running and waiting now.
    var load: (running: Int, waiting: Int) {
        state.withLock { ($0.running, $0.waiting.count) }
    }
}
