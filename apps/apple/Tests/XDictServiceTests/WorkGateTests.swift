import Synchronization
import Testing
import XDictContract
@testable import XDictService

/// **The service-wide ceiling on credited work** (`WorkGate`): two connections' credits run, the rest waits in order and
/// is never refused, and work waiting for a connection that has ended never runs.
struct WorkGateTests {
    final class Log: Sendable {
        let events = Mutex<[String]>([])
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    static func enter(_ gate: WorkGate, _ name: String, connection: UInt64, log: Log) {
        gate.enter(connection: connection, run: { log.add("run \(name)") }, dropped: { log.add("dropped \(name)") })
    }

    @Test func theCeilingIsTwoConnectionsCredits() {
        #expect(WorkGate.ceiling(for: .bulk) == 2 * Limits.bulkCallsInFlight)
        #expect(WorkGate.ceiling(for: .lookup) == 2 * Limits.lookupCallsInFlight)
        #expect(WorkGate.ceiling(for: .bulk) == 4)
        #expect(WorkGate.ceiling(for: .lookup) == 8)
    }

    @Test func workBeyondTheCeilingWaitsInOrder() {
        let gate = WorkGate(ceiling: 2), log = Log()
        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            Self.enter(gate, name, connection: UInt64(index), log: log)
        }
        #expect(log.all == ["run a", "run b"])
        #expect(gate.load == (2, 2))
        gate.leave()
        #expect(log.all == ["run a", "run b", "run c"])
        gate.leave()
        gate.leave()
        gate.leave()
        #expect(log.all == ["run a", "run b", "run c", "run d"])
        #expect(gate.load == (0, 0))
    }

    /// The abandoned connection's waiting work never runs once it has ended; the running work is the core's and finishes.
    @Test func waitingWorkOfAnEndedConnectionNeverRuns() {
        let gate = WorkGate(ceiling: 1), log = Log()
        Self.enter(gate, "running", connection: 1, log: log)
        Self.enter(gate, "abandoned", connection: 1, log: log)
        Self.enter(gate, "live", connection: 2, log: log)
        gate.connectionEnded(1)
        #expect(log.all == ["run running", "dropped abandoned"])
        gate.leave()
        #expect(log.all == ["run running", "dropped abandoned", "run live"])
        gate.leave()
        #expect(gate.load == (0, 0))
    }
}
