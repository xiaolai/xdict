import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract
import XDictInstruments

/// **The checks' held transport** (`TransportHold`, plan-macos-v1 WI-6): what a check names waits, its request or its
/// reply, until the check lets it go; nothing else waits at all.
struct TransportHoldTests {
    /// A connection that answers at once, keeping what it was sent.
    final class Echo: ServiceConnection {
        let sent = Mutex<[UInt64]>([])

        func send(_ envelope: Data, files: [FileHandle]?, completion: @escaping @Sendable (Exchange) -> Void) {
            if let request = try? JSONDecoder().decode(Request.self, from: envelope) {
                sent.withLock { $0.append(request.id) }
            }
            completion(.reply(envelope: envelope, payload: nil))
        }

        func invalidate() {}
        var processIdentifier: pid_t { 0 }
    }

    /// The ids whose completions have run, in order.
    final class Completed: Sendable {
        let ids = Mutex<[UInt64]>([])
        func add(_ id: UInt64) { ids.withLock { $0.append(id) } }
        var all: [UInt64] { ids.withLock { $0 } }
    }

    static let slow = DictId(rawValue: "slow"), quick = DictId(rawValue: "quick")

    static func lookup(_ id: UInt64, in dict: DictId) throws -> Data {
        try Request(id: id, tokens: [], operation: .lookup(
            query: "apple", dicts: [dict], options: LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)))
            .encoded()
    }

    static func connection(_ hold: TransportHold, _ echo: Echo) -> any ServiceConnection {
        hold.connect { _ in echo }(ConnectionEvents(interrupted: {}, invalidated: {}, event: { _ in }))
    }

    static func asks(_ dict: DictId) -> @Sendable (ServiceOperation) -> Bool {
        { operation in
            if case .lookup(_, let dicts, _) = operation { dicts.contains(dict) } else { false }
        }
    }

    @Test func aReplyIsHeldUntilReleasedAndNothingElseWaits() throws {
        let hold = TransportHold(), echo = Echo(), done = Completed()
        hold.hold("slow", at: .reply, when: Self.asks(Self.slow))
        let connection = Self.connection(hold, echo)
        connection.send(try Self.lookup(1, in: Self.slow), files: nil) { _ in done.add(1) }
        connection.send(try Self.lookup(2, in: Self.quick), files: nil) { _ in done.add(2) }
        #expect(echo.sent.withLock { $0 } == [1, 2], "a held reply's request is still sent")
        #expect(done.all == [2], "only the other dictionary's answer arrived")
        #expect(hold.heldCount("slow") == 1)
        hold.release("slow")
        #expect(done.all == [2, 1])
    }

    @Test func aRequestIsHeldUntilReleased() throws {
        let hold = TransportHold(), echo = Echo(), done = Completed()
        hold.hold("import", at: .request, when: Self.asks(Self.slow))
        let connection = Self.connection(hold, echo)
        connection.send(try Self.lookup(3, in: Self.slow), files: nil) { _ in done.add(3) }
        #expect(echo.sent.withLock { $0 }.isEmpty, "the held request has not reached the service")
        #expect(done.all.isEmpty)
        hold.release("import")
        #expect(echo.sent.withLock { $0 } == [3])
        #expect(done.all == [3])
    }

    @Test func afterReleaseNothingMoreIsHeld() throws {
        let hold = TransportHold(), echo = Echo(), done = Completed()
        hold.hold("slow", at: .reply, when: Self.asks(Self.slow))
        hold.release("slow")
        let connection = Self.connection(hold, echo)
        connection.send(try Self.lookup(4, in: Self.slow), files: nil) { _ in done.add(4) }
        #expect(done.all == [4])
        #expect(hold.heldCount("slow") == 0)
    }
}
