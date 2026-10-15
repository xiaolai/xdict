import Foundation
import Synchronization
import XDictClient
import XDictContract

/// **A transport that holds what a check names** (plan-macos-v1 WI-6): the main window's checks make one dictionary
/// slow (its lookups' replies held) and one import last (its request held), through the real service, by wrapping the
/// connection `ServiceClient` makes. Nothing else waits. A development instrument: the app uses it only under
/// `--lookup-window`.
public final class TransportHold: Sendable {
    /// Which half of a call is held: the request, before the service sees it, or the reply, after it answered.
    public enum Point: Sendable {
        case request
        case reply
    }

    struct Rule {
        let point: Point
        let matches: @Sendable (ServiceOperation) -> Bool
    }

    struct State {
        var rules: [String: Rule] = [:]
        var parked: [String: [@Sendable () -> Void]] = [:]
        var held: [String: Int] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Holds every call `matches` names, at `point`, until `release(name)`.
    public func hold(_ name: String, at point: Point, when matches: @escaping @Sendable (ServiceOperation) -> Bool) {
        state.withLock {
            $0.rules[name] = Rule(point: point, matches: matches)
            $0.held[name] = 0
        }
    }

    /// Lets go of everything `name` holds, in the order it was held, and holds nothing more under that name.
    public func release(_ name: String) {
        let parked = state.withLock { state -> [@Sendable () -> Void] in
            state.rules[name] = nil
            defer { state.parked[name] = nil }
            return state.parked[name] ?? []
        }
        for action in parked { action() }
    }

    /// How many calls `name` has held since it was set.
    public func heldCount(_ name: String) -> Int {
        state.withLock { $0.held[name] ?? 0 }
    }

    /// `inner`'s connections, holding what this names.
    public func connect(_ inner: @escaping Connect) -> Connect {
        { [self] events in HoldingConnection(inner(events), hold: self) }
    }

    /// The rule that holds `operation` at `point`, if one does.
    func rule(for operation: ServiceOperation, at point: Point) -> String? {
        state.withLock { state in
            state.rules.first { $0.value.point == point && $0.value.matches(operation) }?.key
        }
    }

    /// Runs `action` now if `name` no longer holds anything, else when it is released.
    func park(_ name: String, _ action: @escaping @Sendable () -> Void) {
        let now = state.withLock { state -> Bool in
            guard state.rules[name] != nil else { return true }
            state.parked[name, default: []].append(action)
            state.held[name, default: 0] += 1
            return false
        }
        if now { action() }
    }
}

/// One connection through a `TransportHold`.
final class HoldingConnection: ServiceConnection {
    private let inner: any ServiceConnection
    private let hold: TransportHold

    init(_ inner: any ServiceConnection, hold: TransportHold) {
        self.inner = inner
        self.hold = hold
    }

    func send(_ envelope: Data, files: [FileHandle]?, completion: @escaping @Sendable (Exchange) -> Void) {
        guard let operation = (try? JSONDecoder().decode(Request.self, from: envelope))?.operation else {
            inner.send(envelope, files: files, completion: completion)
            return
        }
        let reply: @Sendable (Exchange) -> Void
        if let name = hold.rule(for: operation, at: .reply) {
            reply = { [hold] exchange in hold.park(name) { completion(exchange) } }
        } else {
            reply = completion
        }
        let files = files.map(Handles.init)
        let send: @Sendable () -> Void = { [inner] in inner.send(envelope, files: files?.handles, completion: reply) }
        if let name = hold.rule(for: operation, at: .request) {
            hold.park(name, send)
        } else {
            send()
        }
    }

    func invalidate() {
        inner.invalidate()
    }

    var processIdentifier: pid_t {
        inner.processIdentifier
    }

    /// `FileHandle` is not `Sendable`; a held request keeps its handles, unread, until it is sent.
    struct Handles: @unchecked Sendable {
        let handles: [FileHandle]
        init(_ handles: [FileHandle]) { self.handles = handles }
    }
}
