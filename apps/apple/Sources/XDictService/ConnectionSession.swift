import Foundation
import Synchronization
import XDictBase
import XDictContract
import XDictCore
import os

/// What every connection shares: the core and its bookkeeping, the idle exit, the service-wide gates, and the queue the
/// core's work runs on. NSXPC delivers one connection's messages one at a time on a queue of its own; the work goes to
/// this concurrent queue, so a slow entry never holds up a lookup (spike 1: without the hop nothing overlapped).
final class ServiceContext: Sendable {
    let dictionaries: Dictionaries
    let idle: IdleExit
    let bulk = WorkGate(ceiling: WorkGate.ceiling(for: .bulk))
    let lookups = WorkGate(ceiling: WorkGate.ceiling(for: .lookup))
    /// **One Apple dictionary conversion at a time, across the service** (ADR-0011 decision 5): each holds up to the
    /// snapshot's 512 MiB and what it inflates, so a second waits its turn, in order, rather than doubling that. It
    /// runs on `background`, apart from the reader's gates, so a lookup is never behind it.
    let conversions = WorkGate(ceiling: 1)
    /// The app-group container's `AppleImports/`, or nil when the service has none (unsigned, or no entitlement):
    /// every conversion is then refused as `noContainer`.
    let appleImports: AppleImportStore?
    /// How often a conversion waiting its turn reports that it is still there: well inside the client's 60 s of
    /// silence (`Deadlines.importSilence`), which would otherwise end it while a long one runs ahead of it.
    let conversionHeartbeat: Duration
    let queue = DispatchQueue(label: "ai.xdict.app.DictionaryService.core", qos: .userInitiated, attributes: .concurrent)
    /// Where health checks and reading-style reports run (WI-12, ADR-0010): below the reader's calls, which they must
    /// never hold up.
    let background = DispatchQueue(label: "ai.xdict.app.DictionaryService.health", qos: .utility, attributes: .concurrent)
    let log = Logger(subsystem: XDictIdentity.dictionaryService, category: "service")
    private let connections = Atomic<UInt64>(0)

    init(dictionaries: Dictionaries, idle: IdleExit, appleImports: AppleImportStore? = nil,
         conversionHeartbeat: Duration = .seconds(15)) {
        self.dictionaries = dictionaries
        self.idle = idle
        self.appleImports = appleImports
        self.conversionHeartbeat = conversionHeartbeat
    }

    func gate(for creditClass: CreditClass) -> WorkGate {
        switch creditClass {
        case .bulk: bulk
        case .lookup: lookups
        }
    }

    func nextConnection() -> UInt64 {
        connections.add(1, ordering: .relaxed).newValue
    }

    /// The sandbox container's folders (ADR-0009 decision 2), or nil outside the service's own sandbox: a service that
    /// is not sandboxed would write into the user's Library, so it does not start.
    static func containerStorage(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Dictionaries.Storage? {
        guard environment["APP_SANDBOX_CONTAINER_ID"] == XDictIdentity.dictionaryService else { return nil }
        return Dictionaries.Storage(indexes: URL.cachesDirectory.appending(path: "indexes", directoryHint: .isDirectory),
                                    registry: URL.applicationSupportDirectory.appending(path: "registry", directoryHint: .isDirectory))
    }
}

/// **One connection's half of the contract**: what NSXPC exports to the client. Every message is read as
/// `Request.receive` says — its size, its header, the whole, then handles, package, limits and tokens — and then against
/// the connection's `Credits`; only then does anything reach the core. Whatever is wrong is answered, never thrown.
final class ConnectionSession: NSObject, DictionaryServiceXPC, @unchecked Sendable {
    // `@unchecked`: `connection` is NSXPCConnection, thread-safe by its documentation and not declared `Sendable`; it is
    // set once, here, and read only to send events. Everything that changes is behind a `Mutex` or an `Atomic`.
    let number: UInt64
    private let context: ServiceContext
    private weak var connection: NSXPCConnection?
    private let credits = Mutex(Credits())
    /// The long calls in flight: imports, health checks and conversions, by request id, so `cancel` finds them, and
    /// whether each is a conversion, so `cancelConversion` does.
    private let imports = Mutex<[UInt64: (progress: ImportProgress, isConversion: Bool)]>([:])

    init(number: UInt64, context: ServiceContext, connection: NSXPCConnection) {
        self.number = number
        self.context = context
        self.connection = connection
    }

    func call(_ request: Data, reply: @escaping @Sendable (Data, Data?) -> Void) {
        receive(request, files: [], reply: reply)
    }

    func callWithFiles(_ request: Data, files: [FileHandle], reply: @escaping @Sendable (Data, Data?) -> Void) {
        receive(request, files: files, reply: reply)
    }

    /// The client has gone: work waiting for a gate never runs, and its imports stop at their next progress report.
    func end() {
        context.bulk.connectionEnded(number)
        context.lookups.connectionEnded(number)
        context.conversions.connectionEnded(number)
        for running in imports.withLock({ Array($0.values) }) { running.progress.cancel() }
    }

    private func receive(_ envelope: Data, files: [FileHandle], reply: @escaping @Sendable (Data, Data?) -> Void) {
        // In flight from here (`IdleExit`); false only while the process is ending, whose client hears an interruption.
        guard context.idle.begin() else { return }
        let facts = files.map { HandleInspection.facts(of: $0.fileDescriptor) }
        let request: Request
        switch Request.receive(envelope, handles: facts, filesOf: context.dictionaries.filesOf()) {
        case .answered(let response):
            context.log.info("refused a request before decoding it whole: \(String(describing: response.outcome), privacy: .public)")
            return answer(response, payload: nil, credit: nil, reply: reply)
        case .admitted(let admitted):
            request = admitted
        }
        let operation = request.operation
        if case .cancel(let target) = operation {
            let running = imports.withLock { $0[target] }
            running?.progress.cancel()
            return answer(Response(id: request.id, outcome: .answer(.cancellation(running == nil ? .notRunning : .stopping))),
                          payload: nil, credit: nil, reply: reply)
        }
        if case .cancelConversion = operation {
            let running = imports.withLock { $0.values.filter(\.isConversion) }
            for conversion in running { conversion.progress.cancel() }
            return answer(Response(id: request.id, outcome: .answer(.cancellation(running.isEmpty ? .notRunning : .stopping))),
                          payload: nil, credit: nil, reply: reply)
        }
        if case .convertApple(let staging) = operation {
            return convertApple(staging: staging, request: request, reply: reply)
        }
        let credit: Credit
        switch credits.withLock({ $0.take(for: operation) }) {
        case .failure(let refusal):
            return answer(Response(id: request.id, outcome: .failure(.refused(refusal))), payload: nil, credit: nil, reply: reply)
        case .success(let taken):
            credit = taken
        }
        context.dictionaries.observe(request.tokens)
        let progress = importProgress(for: request)
        let handles = Handles(files)
        let job: @Sendable () -> Void = { [self] in
            let (outcome, payload) = context.dictionaries.run(operation, files: handles.files, progress: progress)
            if let creditClass = operation.creditClass { context.gate(for: creditClass).leave() }
            if progress != nil { imports.withLock { _ = $0.removeValue(forKey: request.id) } }
            answer(Response(id: request.id, outcome: outcome), payload: payload, credit: credit, reply: reply)
        }
        guard let creditClass = operation.creditClass else {
            switch operation {
            case .health, .readingStyle: return context.background.async(execute: job)
            default: return context.queue.async(execute: job)
            }
        }
        context.gate(for: creditClass).enter(connection: number, run: { [context] in context.queue.async(execute: job) }, dropped: {
            [self] in
            // Nobody will read this: the connection has ended. Answered all the same, so every request is answered once.
            answer(Response(id: request.id, outcome: .failure(.core(.cancelled(detail: "its connection ended before it ran")))),
                   payload: nil, credit: credit, reply: reply)
        })
    }

    /// **An Apple dictionary conversion** (ADR-0011 decisions 4 and 5): through the service-wide gate of one, on the
    /// background queue. A conversion whose client goes before its turn never runs, and its staging folder is removed;
    /// one running stops at its next step (`end`).
    private func convertApple(staging: UUID, request: Request, reply: @escaping @Sendable (Data, Data?) -> Void) {
        guard let store = context.appleImports else {
            return answer(Response(id: request.id, outcome: .failure(.appleImport(.noContainer))), payload: nil, credit: nil,
                          reply: reply)
        }
        guard let progress = importProgress(for: request) else {
            // `convertApple` reports progress (`ServiceOperation.reportsProgress`); were that ever changed, say so.
            return answer(Response(id: request.id, outcome: .failure(.core(.internalFault(detail: "a conversion without progress")))),
                          payload: nil, credit: nil, reply: reply)
        }
        let job: @Sendable () -> Void = { [self] in
            let outcome = AppleImports.convert(staging: staging, in: store, progress: progress)
            context.conversions.leave()
            imports.withLock { _ = $0.removeValue(forKey: request.id) }
            let logged = (try? outcome.get()).map { "published \($0.conversion), \($0.entries) entries" } ?? "\(outcome)"
            context.log.notice("conversion of \(staging, privacy: .public): \(logged, privacy: .public)")
            switch outcome {
            case .success(let converted):
                answer(Response(id: request.id, outcome: .answer(.converted(converted))), payload: nil, credit: nil, reply: reply)
            case .failure(let error):
                answer(Response(id: request.id, outcome: .failure(error)), payload: nil, credit: nil, reply: reply)
            }
        }
        // While it waits its turn it still reports, at no progress, so the client's silence deadline does not end it.
        let heartbeat = Heartbeat(every: context.conversionHeartbeat, queue: context.background) {
            _ = progress.progress(done: 0, total: ProgressScale.total)
        }
        context.conversions.enter(connection: number, run: { [context] in
            heartbeat.stop()
            context.background.async(execute: job)
        }, dropped: { [self] in
            heartbeat.stop()
            imports.withLock { _ = $0.removeValue(forKey: request.id) }
            AppleImports.discard(staging: staging, in: store)
            answer(Response(id: request.id, outcome: .failure(.core(.cancelled(detail: "its connection ended before it ran")))),
                   payload: nil, credit: nil, reply: reply)
        })
    }

    /// An import's, a health check's or a conversion's progress, reported to the client as events and answering
    /// `false` once `cancel` (or `cancelConversion`, or the client's going) names it. Registered before the work is
    /// queued, so a `cancel` that follows it on this connection always finds it.
    private func importProgress(for request: Request) -> ImportProgress? {
        guard request.operation.reportsProgress else { return nil }
        let id = request.id
        let progress = ImportProgress { [weak self] done, total in
            self?.send(ServiceEvent(request: id, kind: .progress(done: done, total: total)))
        }
        let isConversion = if case .convertApple = request.operation { true } else { false }
        imports.withLock { $0[id] = (progress, isConversion) }
        return progress
    }

    /// The reply, once: the credit back first — the client counts a credited call until it reads the reply, so a service
    /// that released after replying could refuse the client's next call for a credit the client had already seen
    /// returned — then the envelope and payload, then the request is no longer in flight.
    private func answer(_ response: Response, payload: Data?, credit: Credit?, reply: @Sendable (Data, Data?) -> Void) {
        if let credit { credits.withLock { $0.release(credit) } }
        let envelope: Data
        do {
            envelope = try response.boundedEncoded()
        } catch {
            context.log.fault("a response could not be encoded: \(String(describing: error), privacy: .public)")
            envelope = Data()
        }
        reply(envelope, payload)
        context.idle.end()
    }

    private func send(_ event: ServiceEvent) {
        guard let connection, let data = try? event.encoded() else { return }
        // A client that has gone, or exports nothing, misses an event; nothing here waits for one.
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? any ServiceEventsXPC)?.event(data)
    }
}

/// A repeating timer, stopped once. `@unchecked Sendable`: `DispatchSourceTimer` is thread-safe by its documentation but
/// not declared `Sendable`; whether it has stopped is an `Atomic`.
final class Heartbeat: @unchecked Sendable {
    private let timer: any DispatchSourceTimer
    private let stopped = Atomic<Bool>(false)

    init(every interval: Duration, queue: DispatchQueue, beat: @escaping @Sendable () -> Void) {
        let (seconds, attoseconds) = interval.components
        let nanoseconds = max(1, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped.load(ordering: .relaxed) else { return }
            beat()
        }
        timer.resume()
    }

    func stop() {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        timer.cancel()
    }

    deinit {
        stop()
    }
}

/// An import's progress callback for the core. Answers `false` from the report after `cancel`.
final class ImportProgress: XDictCore.Progress {
    private let stopped = Atomic<Bool>(false)
    private let report: @Sendable (UInt64, UInt64) -> Void

    init(report: @escaping @Sendable (UInt64, UInt64) -> Void) {
        self.report = report
    }

    func progress(done: UInt64, total: UInt64) -> Bool {
        report(done, total)
        return !stopped.load(ordering: .relaxed)
    }

    func cancel() {
        stopped.store(true, ordering: .relaxed)
    }
}

/// The request's handles, carried to the core's queue. `@unchecked Sendable`: `FileHandle` is not declared `Sendable`;
/// these are handed over whole, read by one job, and closed by the sources that own them.
private struct Handles: @unchecked Sendable {
    let files: [FileHandle]
    init(_ files: [FileHandle]) { self.files = files }
}

/// **Accepts a connection only under the client check** (`ClientCheck`), then exports this connection's session.
final class ServiceListener: NSObject, NSXPCListenerDelegate, Sendable {
    private let context: ServiceContext
    private let check: ClientCheck

    init(context: ServiceContext, check: ClientCheck) {
        self.context = context
        self.check = check
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        switch check {
        case .requirement(let requirement):
            connection.setCodeSigningRequirement(requirement)
        case .refuseAll(let why):
            context.log.error("refused a connection: \(why, privacy: .public)")
            return false
        #if DEBUG
        case .anyoneForTests:
            break
        #endif
        }
        let session = ConnectionSession(number: context.nextConnection(), context: context, connection: connection)
        connection.exportedInterface = XPCInterfaces.dictionaryService()
        connection.exportedObject = session
        connection.remoteObjectInterface = XPCInterfaces.serviceEvents()
        connection.invalidationHandler = { session.end() }
        connection.interruptionHandler = { session.end() }
        connection.resume()
        return true
    }
}
