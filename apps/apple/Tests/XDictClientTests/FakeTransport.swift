import Foundation
import Synchronization
import XDictContract
@testable import XDictClient

/// **A service of the test's own, behind the client's transport seam** (`ServiceConnection`): every request decoded and
/// kept, answered as the test's script says — at once, later, never, or with a transport failure — and a connection the
/// test can interrupt as a dying service would, which no in-process NSXPC listener can.
final class FakeTransport: Sendable {
    enum Script: Sendable {
        case respond(Response, payload: Data?)
        case later(Duration, Response, payload: Data?)
        case silent
        case fail(WireError)

        static func reply(_ answer: Answer, payload: Data? = nil, to request: Request) -> Script {
            .respond(Response(id: request.id, outcome: .answer(answer)), payload: payload)
        }

        static func reply(_ versions: Versions, to request: Request) -> Script {
            reply(.versions(versions), to: request)
        }

        static func failure(_ error: WireError, to request: Request) -> Script {
            .respond(Response(id: request.id, outcome: .failure(error)), payload: nil)
        }
    }

    typealias Behaviour = @Sendable (Request, _ files: [FileHandle]?) -> Script

    struct Sent: Sendable {
        let connection: Int
        let request: Request
        let files: Int?
    }

    private let behaviour: Behaviour
    private let state = Mutex<(connections: [FakeConnection], sent: [Sent])>(([], []))

    init(_ behaviour: @escaping Behaviour) {
        self.behaviour = behaviour
    }

    var connect: Connect {
        { [self] events in
            state.withLock { state in
                let connection = FakeConnection(number: state.connections.count + 1, events: events, transport: self)
                state.connections.append(connection)
                return connection
            }
        }
    }

    var sent: [Sent] { state.withLock { $0.sent } }
    var connections: [FakeConnection] { state.withLock { $0.connections } }

    fileprivate func received(_ envelope: Data, files: [FileHandle]?, on connection: Int) -> Script {
        guard let request = try? JSONDecoder().decode(Request.self, from: envelope) else {
            return .fail(.undecodable(detail: "the fake could not read the request"))
        }
        state.withLock { $0.sent.append(Sent(connection: connection, request: request, files: files?.count)) }
        return behaviour(request, files)
    }

    /// The service dies: every connection's waiting calls fail `interrupted`, then each hears it.
    func interruptAll() {
        for connection in connections { connection.interrupt() }
    }
}

final class FakeConnection: ServiceConnection, @unchecked Sendable {
    // `@unchecked`: `waiting` is behind a lock; the rest is immutable.
    let number: Int
    private let events: ConnectionEvents
    private unowned let transport: FakeTransport
    private let waiting = Mutex<[@Sendable (Exchange) -> Void]>([])
    private let ended = Mutex(false)

    init(number: Int, events: ConnectionEvents, transport: FakeTransport) {
        self.number = number
        self.events = events
        self.transport = transport
    }

    func send(_ envelope: Data, files: [FileHandle]?, completion: @escaping @Sendable (Exchange) -> Void) {
        let once = OnceExchange(completion)
        guard !ended.withLock({ $0 }) else { return once.complete(.failed(.invalidated)) }
        switch transport.received(envelope, files: files, on: number) {
        case .respond(let response, let payload):
            let data = (try? response.encoded()) ?? Data()
            DispatchQueue.global().async { once.complete(.reply(envelope: data, payload: payload)) }
        case .later(let delay, let response, let payload):
            let data = (try? response.encoded()) ?? Data()
            waiting.withLock { $0.append { once.complete($0) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay.components.attoseconds / 1_000_000_000)
                                                                              + Int(delay.components.seconds) * 1_000_000_000)) {
                once.complete(.reply(envelope: data, payload: payload))
            }
        case .silent:
            waiting.withLock { $0.append { once.complete($0) } }
        case .fail(let error):
            DispatchQueue.global().async { once.complete(.failed(error)) }
        }
    }

    func interrupt() {
        for complete in waiting.withLock({ waiting in defer { waiting = [] }; return waiting }) { complete(.failed(.interrupted)) }
        events.interrupted()
    }

    func invalidate() {
        ended.withLock { $0 = true }
        for complete in waiting.withLock({ waiting in defer { waiting = [] }; return waiting }) { complete(.failed(.invalidated)) }
        events.invalidated()
    }

    var isInvalidated: Bool { ended.withLock { $0 } }

    var processIdentifier: pid_t { pid_t(1_000 + number) }
}

/// Client events, kept in order.
final class EventLog: Sendable {
    private let events = Mutex<[ClientEvent]>([])

    func record(_ event: ClientEvent) {
        events.withLock { $0.append(event) }
    }

    var all: [ClientEvent] { events.withLock { $0 } }

    /// Waits up to `timeout` for an event matching `wanted`.
    func wait(for timeout: Duration = .seconds(5), _ wanted: (ClientEvent) -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if all.contains(where: wanted) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return all.contains(where: wanted)
    }
}
