import Foundation
import Synchronization
import Testing
import XDictContract

/// The NSXPC side of the contract: the interfaces both processes build from the contract's factories, and a real
/// connection (an anonymous listener in this process) carrying a file handle one way and an event the other.
struct TransportTests {
    /// **The files argument admits `FileHandle` in an array**: without the class list NSXPC refuses the message and
    /// interrupts the connection (spike 1's control, `NSCocoaErrorDomain 4097`).
    @Test func theServiceInterfaceAdmitsFileHandlesForTheFilesArgument() {
        let interface = XPCInterfaces.dictionaryService()
        let classes = interface.classes(for: XPCInterfaces.callWithFiles, argumentIndex: XPCInterfaces.filesArgument,
                                        ofReply: false)
        #expect(Self.holds(classes, FileHandle.self), "the files argument does not admit FileHandle: \(classes)")
        #expect(Self.holds(classes, NSArray.self), "the files argument does not admit an array: \(classes)")
    }

    /// A handle crosses a real connection built from the factories, and the receiver reads the same file through it.
    @Test func aFileHandleCrossesTheConnection() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "xdict-handle-\(UUID().uuidString)")
        try Data("hold".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent = stat()
        try #require(fstat(handle.fileDescriptor, &sent) == 0)

        let service = FakeService()
        let reply = await service.callWithFiles(Data("request".utf8), files: [handle], deadline: .seconds(10))
        let (envelope, payload) = try reply.get()
        #expect(envelope == Data("request".utf8))
        let received = try JSONDecoder().decode(FileIdentity.self, from: try #require(payload))
        #expect(received == FileIdentity(stat: sent), "the receiver's handle names another file")
    }

    /// The service's events reach the object the app exports on the same connection, through the events interface.
    @Test func anEventReachesTheAppsSink() async throws {
        let service = FakeService()
        let event = try ServiceEvent(request: 3, kind: .progress(done: 1, total: 2)).encoded()
        let delivered = await service.call(event, deadline: .seconds(10))
        let (envelope, _) = try delivered.get()
        #expect(envelope == event, "the service's reply says what it sent")
        let seen = await service.sink.next(deadline: .seconds(10))
        #expect(seen == event)
    }

    static func holds(_ classes: Set<AnyHashable>, _ wanted: AnyClass) -> Bool {
        classes.contains { ($0.base as AnyObject) === wanted }
    }
}

/// A service of the test's own behind an anonymous listener, built from the contract's interfaces: `callWithFiles`
/// answers with the request and the `FileIdentity` of the first handle it received; `call` sends its request back to
/// the app as an event, then replies with it.
private final class FakeService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let sink = Sink()
    private let listener = NSXPCListener.anonymous()
    /// The app's connections, kept until the service goes: invalidating one as its reply arrives could drop an event
    /// the service sent before that reply.
    private let clients = Mutex<[Box]>([])

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        for client in clients.withLock({ $0 }) { client.value.invalidate() }
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = XPCInterfaces.dictionaryService()
        connection.remoteObjectInterface = XPCInterfaces.serviceEvents()
        connection.exportedObject = Exported(connection: Box(connection))
        connection.resume()
        return true
    }

    typealias Outcome = Result<(Data, Data?), WireError>

    func call(_ request: Data, deadline: Duration) async -> Outcome {
        await ask(deadline) { $0.call(request, reply: $1) }
    }

    func callWithFiles(_ request: Data, files: [FileHandle], deadline: Duration) async -> Outcome {
        await ask(deadline) { $0.callWithFiles(request, files: files, reply: $1) }
    }

    /// One call on a fresh connection that exports `sink` for events; whichever of the reply, the error handler and
    /// the deadline comes first decides. Nonisolated, closures `@Sendable` (spike 1's Swift 6 finding).
    nonisolated private func ask(
        _ deadline: Duration,
        _ send: @escaping @Sendable (any DictionaryServiceXPC, @escaping @Sendable (Data, Data?) -> Void) -> Void
    ) async -> Outcome {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.dictionaryService()
        connection.exportedInterface = XPCInterfaces.serviceEvents()
        connection.exportedObject = sink
        connection.resume()
        clients.withLock { $0.append(Box(connection)) }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(deadline.components.seconds))) {
                once.resume(.failure(.timedOut(deadline: deadline)))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(.failure(.interrupted)) }
            guard let service = proxy as? any DictionaryServiceXPC else {
                once.resume(.failure(.invalidated))
                return
            }
            send(service) { @Sendable envelope, payload in once.resume(.success((envelope, payload))) }
        }
    }

    private final class Exported: NSObject, DictionaryServiceXPC {
        let connection: Box
        init(connection: Box) { self.connection = connection }

        func call(_ request: Data, reply: @escaping @Sendable (Data, Data?) -> Void) {
            (connection.value.remoteObjectProxy as? any ServiceEventsXPC)?.event(request)
            reply(request, nil)
        }

        func callWithFiles(_ request: Data, files: [FileHandle], reply: @escaping @Sendable (Data, Data?) -> Void) {
            var info = stat()
            guard let first = files.first, fstat(first.fileDescriptor, &info) == 0,
                  let identity = try? JSONEncoder().encode(FileIdentity(stat: info)) else {
                reply(request, nil)
                return
            }
            reply(request, identity)
        }
    }

    final class Box: @unchecked Sendable {
        let value: NSXPCConnection
        init(_ value: NSXPCConnection) { self.value = value }
    }

    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<Outcome, Never>?>
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = Mutex(continuation) }
        func resume(_ outcome: Outcome) {
            let taken = continuation.withLock { held -> CheckedContinuation<Outcome, Never>? in
                defer { held = nil }
                return held
            }
            taken?.resume(returning: outcome)
        }
    }
}

/// The app's events sink: what arrived, in order, and a wait for the next.
final class Sink: NSObject, ServiceEventsXPC, Sendable {
    private let arrived = Mutex<[Data]>([])

    func event(_ data: Data) {
        arrived.withLock { $0.append(data) }
    }

    func next(deadline: Duration) async -> Data? {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        while clock.now < end {
            if let first = arrived.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return first }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}
