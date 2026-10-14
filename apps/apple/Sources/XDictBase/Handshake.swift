import Foundation
import Synchronization

/// **The skeleton's whole wire: one call, `versions()`, over NSXPC** (plan-macos-v1 WI-2). WI-3 replaces it with the
/// contract WI-1 freezes; until then it proves the parts are in place — the app finds its embedded service, launchd
/// starts it sandboxed, and the core linked into it answers.
@objc public protocol HandshakeProtocol {
    /// Replies with the core's versions encoded as `CoreVersions` JSON, or with nothing and the reason there is none.
    func versions(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// Every way a handshake can fail, each its own case: a reader told "it failed" cannot tell a slow service from a
/// missing one, and neither can a log.
public enum HandshakeFailure: Error, Equatable, Sendable {
    /// No answer by the deadline.
    case timedOut(after: Duration)
    /// The connection broke or was refused before an answer: no such service, or one that would not accept us.
    case unreachable(String)
    /// The service answered with a reason instead of versions.
    case refused(String)
    /// The service answered with something that is not `CoreVersions`.
    case unreadable(String)
}

/// The app's side of the handshake. Every call ends in exactly one outcome, by the deadline at the latest.
public enum HandshakeClient {
    /// Generous: the first request of a session starts the service, and the first start of a sandboxed service creates
    /// its container.
    public static let deadline: Duration = .seconds(10)

    /// Asks the dictionary service embedded in this app's bundle.
    public static func ask(deadline: Duration = deadline) async -> Result<CoreVersions, HandshakeFailure> {
        await ask(NSXPCConnection(serviceName: XDictIdentity.dictionaryService), deadline: deadline)
    }

    /// Asks the listener behind `endpoint`: an anonymous one, in tests.
    public static func ask(endpoint: NSXPCListenerEndpoint, deadline: Duration = deadline)
        async -> Result<CoreVersions, HandshakeFailure> {
        await ask(NSXPCConnection(listenerEndpoint: endpoint), deadline: deadline)
    }

    /// **Nonisolated, and its closures `@Sendable`, on purpose** (WI-1 spike, `measurements/2026-10-14-macos-xpc`): the
    /// SDK does not mark `remoteObjectProxyWithErrorHandler`'s closure `@Sendable`, so one written in a `@MainActor`
    /// method inherits that isolation, and the first transport error, delivered on XPC's queue, traps in
    /// `dispatch_assert_queue`. `aRefusedConnectionAskedFromTheMainActorIsUnreachable` asks from the main actor.
    nonisolated static func ask(_ connection: NSXPCConnection, deadline: Duration)
        async -> Result<CoreVersions, HandshakeFailure> {
        connection.remoteObjectInterface = NSXPCInterface(with: HandshakeProtocol.self)
        connection.resume()
        let outcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(deadline))) {
                once.resume(.failure(.timedOut(after: deadline)))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(.failure(.unreachable(error.localizedDescription)))
            }
            guard let service = proxy as? any HandshakeProtocol else {
                once.resume(.failure(.unreachable("the connection's proxy does not speak the handshake")))
                return
            }
            service.versions { @Sendable data, reason in once.resume(Self.decode(data, reason)) }
        }
        connection.invalidate()
        return outcome
    }

    static func decode(_ data: Data?, _ reason: String?) -> Result<CoreVersions, HandshakeFailure> {
        guard let data else { return .failure(.refused(reason ?? "the service gave no versions and no reason")) }
        do {
            return .success(try JSONDecoder().decode(CoreVersions.self, from: data))
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
    }

    static func nanoseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    }
}

/// A continuation resumed by whichever of the reply, the error handler and the deadline comes first; the others find
/// it taken.
private final class Once: Sendable {
    typealias Outcome = Result<CoreVersions, HandshakeFailure>
    private let continuation: Mutex<CheckedContinuation<Outcome, Never>?>

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ outcome: Outcome) {
        let taken = continuation.withLock { held -> CheckedContinuation<Outcome, Never>? in
            defer { held = nil }
            return held
        }
        taken?.resume(returning: outcome)
    }
}
