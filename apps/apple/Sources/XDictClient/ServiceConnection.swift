import Foundation
import Synchronization
import XDictBase
import XDictContract

/// **One connection to the dictionary service, as `ServiceClient` uses it**: XiaolaiDict's `DictionaryTransport` seam
/// (send, and end), shaped by the contract — an envelope out, with handles or without, and exactly one `Exchange` back.
/// The real one is NSXPC (`XPCServiceConnection`); tests give the client a fake, which is how an interruption is made
/// without killing a process.
public protocol ServiceConnection: AnyObject, Sendable {
    /// Sends one request. `completion` is called exactly once: the reply, or why there is none.
    func send(_ envelope: Data, files: [FileHandle]?, completion: @escaping @Sendable (Exchange) -> Void)
    /// Ends the connection: calls still waiting complete with `.failed`.
    func invalidate()
    /// The service's process, 0 before the connection has reached one.
    var processIdentifier: pid_t { get }
}

/// What came back for one request.
public enum Exchange: Sendable {
    case reply(envelope: Data, payload: Data?)
    case failed(WireError)
}

/// What a connection tells its client unasked.
public struct ConnectionEvents: Sendable {
    /// The service exited or crashed with this connection open. The connection stays usable: the next message starts
    /// the service again.
    public let interrupted: @Sendable () -> Void
    /// The connection is over for good.
    public let invalidated: @Sendable () -> Void
    /// A `ServiceEvent`'s bytes.
    public let event: @Sendable (Data) -> Void

    public init(interrupted: @escaping @Sendable () -> Void, invalidated: @escaping @Sendable () -> Void,
                event: @escaping @Sendable (Data) -> Void) {
        self.interrupted = interrupted
        self.invalidated = invalidated
        self.event = event
    }
}

/// Makes a connection: `ServiceClient` calls it again whenever it needs a new one.
public typealias Connect = @Sendable (ConnectionEvents) -> any ServiceConnection

/// **The NSXPC connection.** Nothing here is actor-isolated, and every closure handed to NSXPC is built in this
/// nonisolated code and marked `@Sendable`: NSXPC calls back on its own queues, and a closure that inherited main-actor
/// isolation trapped in `dispatch_assert_queue` on the first transport error (spike 1).
public final class XPCServiceConnection: ServiceConnection, @unchecked Sendable {
    // `@unchecked`: NSXPCConnection is thread-safe by its documentation and not declared `Sendable`; it is never replaced.
    private let connection: NSXPCConnection

    public init(_ connection: NSXPCConnection, events: ConnectionEvents) {
        self.connection = connection
        connection.remoteObjectInterface = XPCInterfaces.dictionaryService()
        connection.exportedInterface = XPCInterfaces.serviceEvents()
        connection.exportedObject = EventSink(events.event)
        connection.interruptionHandler = events.interrupted
        connection.invalidationHandler = events.invalidated
        connection.resume()
    }

    /// The service embedded in this app's bundle, by its name.
    public static func embedded(_ events: ConnectionEvents) -> any ServiceConnection {
        XPCServiceConnection(NSXPCConnection(serviceName: XDictIdentity.dictionaryService), events: events)
    }

    public func send(_ envelope: Data, files: [FileHandle]?, completion: @escaping @Sendable (Exchange) -> Void) {
        let once = OnceExchange(completion)
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            once.complete(.failed(Self.wireError(error)))
        }
        guard let service = proxy as? any DictionaryServiceXPC else {
            once.complete(.failed(.invalidated))
            return
        }
        let reply: @Sendable (Data, Data?) -> Void = { envelope, payload in
            once.complete(.reply(envelope: envelope, payload: payload))
        }
        if let files {
            service.callWithFiles(envelope, files: files, reply: reply)
        } else {
            service.call(envelope, reply: reply)
        }
    }

    public func invalidate() {
        connection.invalidate()
    }

    public var processIdentifier: pid_t {
        connection.processIdentifier
    }

    /// NSXPC's transport errors as the contract's kinds: the service gone (interrupted), the connection unusable or
    /// refused by the service's code-signing requirement (invalidated), a reply NSXPC could not decode (undecodable).
    static func wireError(_ error: any Error) -> WireError {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return .interrupted }
        switch error.code {
        case NSXPCConnectionInterrupted: return .interrupted
        case NSXPCConnectionInvalid, NSXPCConnectionCodeSigningRequirementFailure: return .invalidated
        case NSXPCConnectionReplyInvalid: return .undecodable(detail: "NSXPC: \(error.localizedDescription)")
        default: return .interrupted
        }
    }
}

/// The app's exported object: hands each event's bytes on.
private final class EventSink: NSObject, ServiceEventsXPC, Sendable {
    private let deliver: @Sendable (Data) -> Void

    init(_ deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
    }

    func event(_ data: Data) {
        deliver(data)
    }
}

/// A completion called by whichever of the reply and the error handler comes first; the other finds it taken.
final class OnceExchange: Sendable {
    private let completion: Mutex<(@Sendable (Exchange) -> Void)?>

    init(_ completion: @escaping @Sendable (Exchange) -> Void) {
        self.completion = Mutex(completion)
    }

    func complete(_ exchange: Exchange) {
        let taken = completion.withLock { held -> (@Sendable (Exchange) -> Void)? in
            defer { held = nil }
            return held
        }
        taken?(exchange)
    }
}
