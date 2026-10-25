import Foundation
import XDictBase
import XDictContract
import os

/// **The app's side of the contract** (ADR-0009 decisions 4 and 5), from XiaolaiDict's `DictionaryClient`: one
/// connection at a time to the dictionary service, made again whenever the last one ended or was abandoned.
///
/// - **Request ids** are numbered by this client and never repeat, so a reply always finds its call (or finds it gone).
/// - **A deadline per call** (`Options.deadline`, the contract's `Deadlines`), raised to the cold start on a connection
///   that has not answered yet. An import has none; it ends after `Deadlines.importSilence` without a progress event.
/// - **Credits** (`Credits`): a call of a class whose credits are taken waits here, in order, and is sent when one comes
///   back. A credit is the client's from the send until the reply or the connection's end — not until the deadline — so
///   both sides count alike and the service never has to refuse.
/// - **Generations per caller** (`Caller`): a newer call makes the older ones superseded. **A queued one is dropped
///   before it is sent; a sent one is answered `.superseded` and its reply, when it comes, is discarded.**
/// - **A credited call past its deadline abandons its connection**: the next calls go on a new connection with every
///   credit, and the old one ends once its calls have answered (or after `Options.retiredGrace`).
/// - **A service that exits or crashes** fails every call in flight with `interrupted`; the next call starts it again.
/// - **Handles survive a restart**: a dictionary opened through `open` keeps the `DictId` it was first given. When the
///   service answers `staleHandle` for it, the client opens its package again, sends the call again once under the new
///   handle, and maps the service's new handle back to the caller's in what it answers.
/// - **Payloads are held to their ceilings** before anything sees them (`Response.read`).
/// - **Tokens** for every file a call may read, from `stat`, numbered by `FileObserver`.
public actor ServiceClient {
    public struct Options: Sendable {
        /// A call's deadline from its send, nil for none; the second argument is whether the call goes on a connection
        /// that has not answered yet. The instruments shorten it to stall a call on purpose.
        public var deadline: @Sendable (ServiceOperation, _ onFreshConnection: Bool) -> Duration?
        public var importSilence: Duration
        /// How long an abandoned connection is kept for late replies once every call on it has an outcome.
        public var retiredGrace: Duration

        public init(deadline: @escaping @Sendable (ServiceOperation, Bool) -> Duration?, importSilence: Duration,
                    retiredGrace: Duration) {
            self.deadline = deadline
            self.importSilence = importSilence
            self.retiredGrace = retiredGrace
        }

        public static let contract = Options(deadline: { Deadlines.deadline(for: $0, onFreshConnection: $1) },
                                             importSilence: Deadlines.importSilence, retiredGrace: .seconds(30))
    }

    // MARK: - State

    /// One call, from `submit` to its outcome. Confined to the actor.
    private final class Call {
        let number: UInt64
        let operation: ServiceOperation
        let caller: Caller?
        let generation: UInt64
        let package: DictionaryPackage?
        let progress: (@Sendable (UInt64, UInt64) -> Void)?
        let promise = Promise()
        /// Sent exactly as given, for the instruments: no tokens made, no handles renamed, no retry.
        var unchecked: (files: [FileHandle]?, tokens: [FileToken])?
        /// The dictionary this call opens again after a restart, for the calls waiting on it.
        var reopens: DictId?
        /// Sent once already and answered `staleHandle`.
        var retried = false
        /// Dictionaries this call waits on being opened again.
        var awaiting: Set<DictId> = []

        init(number: UInt64, operation: ServiceOperation, caller: Caller?, generation: UInt64, package: DictionaryPackage?,
             progress: (@Sendable (UInt64, UInt64) -> Void)?) {
            self.number = number
            self.operation = operation
            self.caller = caller
            self.generation = generation
            self.package = package
            self.progress = progress
        }

        var isResolved: Bool { promise.isFulfilled }
    }

    private final class InFlight {
        let call: Call
        let request: Request
        let credit: Credit
        /// Kept until the reply: NSXPC has sent them, and they close when this goes.
        let files: [FileHandle]?
        var deadline: Duration?
        var timer: Task<Void, Never>?

        init(call: Call, request: Request, credit: Credit, files: [FileHandle]?) {
            self.call = call
            self.request = request
            self.credit = credit
            self.files = files
        }
    }

    private final class Link {
        let number: Int
        let connection: any ServiceConnection
        var credits = Credits()
        /// A reply has come since the connection was made or last interrupted: calls are warm.
        var answered = false
        var retired = false
        var inFlight: [UInt64: InFlight] = [:]

        init(number: Int, connection: any ServiceConnection) {
            self.number = number
            self.connection = connection
        }
    }

    /// A dictionary opened through `open`, under the id it was first given.
    private struct Registered {
        let package: DictionaryPackage
        var current: DictId
    }

    private let connect: Connect
    private let options: Options
    private let observer: FileObserver
    private let watch: (@Sendable (ClientEvent) -> Void)?
    private let log = Logger(subsystem: XDictIdentity.app, category: "service-client")

    private var nextCall: UInt64 = 0
    private var nextRequest: UInt64 = 0
    private var nextLink = 0
    private var current: Link?
    private var links: [Int: Link] = [:]
    private var queue: [Call] = []
    private var generations: [Caller: UInt64] = [:]
    private var registry: [DictId: Registered] = [:]
    /// The service's current handle → the caller's.
    private var callersID: [DictId: DictId] = [:]
    /// Calls waiting on each dictionary being opened again.
    private var reopening: [DictId: [Call]] = [:]

    public init(connect: @escaping Connect = XPCServiceConnection.embedded, options: Options = .contract,
                observer: FileObserver = FileObserver(), watch: (@Sendable (ClientEvent) -> Void)? = nil) {
        self.connect = connect
        self.options = options
        self.observer = observer
        self.watch = watch
    }

    // MARK: - Calls

    /// Queues `operation` (sending it now if a credit allows) and returns at once. With `supersedingEarlier`, every
    /// earlier call of `caller` is superseded first.
    public func submit(_ operation: ServiceOperation, as caller: Caller? = nil, supersedingEarlier: Bool = false) -> CallTicket {
        if supersedingEarlier, let caller { supersede(caller) }
        let call = makeCall(operation, caller: caller, package: nil, progress: nil)
        if operation.packageSpec != nil {
            call.promise.fulfil(.failure(.needsFiles))
        } else {
            enqueue(call)
        }
        return CallTicket(number: call.number, promise: call.promise)
    }

    public func call(_ operation: ServiceOperation, as caller: Caller? = nil, supersedingEarlier: Bool = false) async
        -> ClientOutcome {
        await submit(operation, as: caller, supersedingEarlier: supersedingEarlier).outcome()
    }

    /// Supersedes every call of `caller` made so far: queued ones are dropped, sent ones answered `.superseded`.
    public func supersede(_ caller: Caller) {
        generations[caller, default: 0] += 1
        for link in links.values {
            for entry in link.inFlight.values where !entry.call.isResolved && superseded(entry.call) {
                entry.call.promise.fulfil(.failure(.superseded))
            }
        }
        pump()
    }

    /// Opens a package, sending its files' handles. A `ready` answer's `DictId` stays the caller's for this client's life
    /// (until `close`), whatever the service does.
    public func submitOpen(_ package: DictionaryPackage, as caller: Caller? = nil) -> CallTicket {
        let call = makeCall(.openPackage(spec: package.spec), caller: caller, package: package, progress: nil)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    public func open(_ package: DictionaryPackage) async -> Result<Opened, ClientFailure> {
        await submitOpen(package).outcome().flatMap { delivered in
            guard case .opened(let opened) = delivered.answer else { return .failure(.wire(.undecodable(detail: "not opened"))) }
            return .success(opened)
        }
    }

    /// Imports a package; `progress` hears the service's reports. Cancel it with `cancelImport`.
    public func submitImport(_ package: DictionaryPackage, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil)
        -> CallTicket {
        let call = makeCall(.importPackage(spec: package.spec), caller: nil, package: package, progress: progress)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    public func importPackage(_ package: DictionaryPackage, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) async
        -> Result<Imported, ClientFailure> {
        await submitImport(package, progress: progress).outcome().flatMap { delivered in
            guard case .imported(let imported) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not imported")))
            }
            return .success(imported)
        }
    }

    /// Checks an open dictionary's edition (WI-12); `progress` hears records checked of all. Like an import it has no
    /// deadline, ends after `importSilence` without a report, and stops by `cancelImport`.
    public func submitHealth(_ dict: DictId, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) -> CallTicket {
        let call = makeCall(.health(dict: dict), caller: nil, package: nil, progress: progress)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    /// **Builds one dictionary's example store in the background** (ADR-0031 d.3, d.6); `progress` hears records done.
    /// Like a health check it has no deadline, ends after `importSilence` without a report, and stops by `cancelImport`.
    public func submitExamplesBuild(_ dict: DictId, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) -> CallTicket {
        let call = makeCall(.examplesBuild(dict: dict), caller: nil, package: nil, progress: progress)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    /// **The reverse-example query** (ADR-0031 d.4, d.9): the pairs whose Chinese carries `query`, from `dicts`, at
    /// most `limit`. A dictionary without a store comes back in `notReady`, never as a failure.
    public func examples(_ query: String, dicts: [DictId], limit: UInt32) async -> Result<Examples, ClientFailure> {
        await call(.examples(query: query, dicts: dicts, limit: limit)).flatMap { delivered in
            guard case .examples(let examples) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not examples")))
            }
            return .success(examples)
        }
    }

    /// **Builds one dictionary's phrase inventory in the background** (plan-phrase-recognition WI-4, WI-7); `progress`
    /// hears records done. Like a health check it has no deadline and stops by `cancelImport`.
    public func submitPhrasesBuild(_ dict: DictId, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) -> CallTicket {
        let call = makeCall(.phrasesBuild(dict: dict), caller: nil, package: nil, progress: progress)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    /// **The phrases covering the captured term** (plan-phrase-recognition WI-5, WI-7): every ready dictionary's phrase
    /// that covers `term`'s word in `sentence`, best first, with the state of each dictionary that could not answer. A
    /// store not built yet answers `building`, never a failure, and the shell may ask for its build.
    public func phrases(_ sentence: String, term: PhraseTerm, dicts: [DictId]) async
        -> Result<PhraseAnswer, ClientFailure> {
        await call(.phrases(sentence: sentence, term: term, dicts: dicts)).flatMap { delivered in
            guard case .phrases(let answer) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not phrases")))
            }
            return .success(answer)
        }
    }

    /// Stops the import or health check `ticket` names: one not yet sent never is; one running stops at its next
    /// progress report and answers `cancelled`.
    public func cancelImport(_ ticket: CallTicket) async -> Result<Cancellation, ClientFailure> {
        if let index = queue.firstIndex(where: { $0.number == ticket.number }) {
            let call = queue.remove(at: index)
            call.promise.fulfil(.failure(.wire(.core(.cancelled(detail: "cancelled before it was sent")))))
            return .success(.stopping)
        }
        for link in links.values {
            guard let id = link.inFlight.first(where: { $0.value.call.number == ticket.number })?.key else { continue }
            let cancel = makeCall(.cancel(request: id), caller: nil, package: nil, progress: nil)
            send(cancel, on: link)
            return await cancel.promise.value().flatMap { delivered in
                guard case .cancellation(let found) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not a cancellation")))
                }
                return .success(found)
            }
        }
        return .success(.notRunning)
    }

    /// Converts the Apple dictionary snapshot staged at `AppleImports/staging/<staging>/` of the shared app-group
    /// container (ADR-0011 decision 4); `progress` hears the service's reports. Like an import it has no deadline and
    /// ends after `importSilence` without a report. Stop it with `cancelConversion`.
    public func submitConvertApple(staging: UUID, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) -> CallTicket {
        let call = makeCall(.convertApple(staging: staging), caller: nil, package: nil, progress: progress)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    /// Stops the conversion `ticket` names: one not yet sent never is; one sent, running or waiting its turn in the
    /// service, stops at its next step and answers `cancelled`.
    public func cancelConversion(_ ticket: CallTicket) async -> Result<Cancellation, ClientFailure> {
        if let index = queue.firstIndex(where: { $0.number == ticket.number }) {
            let call = queue.remove(at: index)
            call.promise.fulfil(.failure(.wire(.core(.cancelled(detail: "cancelled before it was sent")))))
            return .success(.stopping)
        }
        for link in links.values where link.inFlight.contains(where: { $0.value.call.number == ticket.number }) {
            let cancel = makeCall(.cancelConversion, caller: nil, package: nil, progress: nil)
            send(cancel, on: link)
            return await cancel.promise.value().flatMap { delivered in
                guard case .cancellation(let found) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not a cancellation")))
                }
                return .success(found)
            }
        }
        return .success(.notRunning)
    }

    /// Closes a dictionary opened through `open`. After a restart there is nothing left to close in the service.
    public func close(_ dict: DictId) async -> ClientOutcome {
        guard let registered = registry.removeValue(forKey: dict) else { return await call(.close(dict: dict)) }
        callersID[registered.current] = nil
        let call = makeCall(.close(dict: registered.current), caller: nil, package: nil, progress: nil)
        call.unchecked = (nil, [])
        enqueue(call)
        let outcome = await call.promise.value()
        if case .failure(.wire(.core(.staleHandle))) = outcome { return .success(Delivered(answer: .closed, payload: nil)) }
        return outcome
    }

    public func versions() async -> Result<Versions, ClientFailure> {
        await call(.versions).flatMap { delivered in
            guard case .versions(let versions) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not versions")))
            }
            return .success(versions)
        }
    }

    /// The service's process on the current connection, 0 when there is none yet.
    public var servicePID: pid_t {
        current?.connection.processIdentifier ?? 0
    }

    /// **For the instruments**: sends `operation` exactly as given — these files, these tokens, its handles unrenamed —
    /// so a request the client would never make can be shown refused by the service.
    @_spi(Instruments)
    public func submitUnchecked(_ operation: ServiceOperation, files: [FileHandle]?, tokens: [FileToken]) -> CallTicket {
        let call = makeCall(operation, caller: nil, package: nil, progress: nil)
        call.unchecked = (files, tokens)
        enqueue(call)
        return CallTicket(number: call.number, promise: call.promise)
    }

    // MARK: - Sending

    private func makeCall(_ operation: ServiceOperation, caller: Caller?, package: DictionaryPackage?,
                          progress: (@Sendable (UInt64, UInt64) -> Void)?) -> Call {
        nextCall += 1
        return Call(number: nextCall, operation: operation, caller: caller,
                    generation: caller.map { generations[$0, default: 0] } ?? 0, package: package, progress: progress)
    }

    private func enqueue(_ call: Call) {
        queue.append(call)
        pump()
    }

    private func superseded(_ call: Call) -> Bool {
        guard let caller = call.caller else { return false }
        return generations[caller, default: 0] != call.generation
    }

    /// Sends what credits allow, in order within each class. **A superseded call is dropped here, before it is sent.**
    private func pump() {
        var waiting: [Call] = []
        for call in queue where !call.isResolved {
            if superseded(call) {
                call.promise.fulfil(.failure(.superseded))
                watch?(.dropped(call: call.number))
                continue
            }
            let link = currentLink()
            guard Self.hasCredit(for: call.operation, in: link.credits) else {
                waiting.append(call)
                continue
            }
            send(call, on: link)
        }
        queue = waiting
    }

    private static func hasCredit(for operation: ServiceOperation, in credits: Credits) -> Bool {
        switch operation.creditClass {
        case .bulk: credits.inFlight(.bulk) < Limits.bulkCallsInFlight
        case .lookup: credits.inFlight(.lookup) < Limits.lookupCallsInFlight
        case .none: true
        }
    }

    private func send(_ call: Call, on link: Link) {
        let credit: Credit
        switch link.credits.take(for: call.operation) {
        case .success(let taken): credit = taken
        case .failure(let refusal): return finish(call, .failure(.wire(.refused(refusal))))
        }
        let operation: ServiceOperation, tokens: [FileToken], files: [FileHandle]?
        if let unchecked = call.unchecked {
            (operation, tokens, files) = (call.operation, unchecked.tokens, unchecked.files)
        } else if let package = call.package {
            operation = call.operation
            // Each path observed, then opened: a file replaced between the two is refused by the service as not the
            // path's file, and the client tries again from the start. Both without following a link and only to a
            // regular file (`FileAccess`): this open is also the one after a restart, which no resolution precedes.
            tokens = package.files.map(observer.token)
            var opened: [FileHandle] = []
            for file in package.files {
                switch FileAccess.open(file.locate()) {
                case .success(let descriptor):
                    opened.append(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
                case .failure(let refused):
                    link.credits.release(credit)
                    return finish(call, .failure(.fileUnavailable(file: file.spec.id, errno: refused.errno)))
                }
            }
            files = opened
        } else {
            operation = call.operation.renamingDicts { registry[$0]?.current ?? $0 }
            tokens = operation.namedDicts.flatMap { dict in
                callersID[dict].flatMap { registry[$0] }?.package.files.map(observer.token) ?? []
            }
            files = nil
        }
        nextRequest += 1
        let id = nextRequest
        let request = Request(id: id, tokens: tokens, operation: operation)
        let envelope: Data
        do {
            envelope = try request.encoded()
        } catch {
            link.credits.release(credit)
            return finish(call, .failure(.wire(.undecodable(detail: "the request could not be encoded: \(error)"))))
        }
        let entry = InFlight(call: call, request: request, credit: credit, files: files)
        link.inFlight[id] = entry
        watch?(.sent(call: call.number, request: id, link: link.number))
        let number = link.number
        link.connection.send(envelope, files: files) { [weak self] exchange in
            Task { await self?.received(exchange, request: id, link: number) }
        }
        if operation.reportsProgress {
            armSilence(entry, id: id, link: number)
        } else if let deadline = options.deadline(operation, !link.answered) {
            entry.deadline = deadline
            entry.timer = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                await self?.expired(request: id, link: number)
            }
        }
    }

    private func armSilence(_ entry: InFlight, id: UInt64, link: Int) {
        entry.timer?.cancel()
        let silence = options.importSilence
        entry.deadline = silence
        entry.timer = Task { [weak self] in
            try? await Task.sleep(for: silence)
            guard !Task.isCancelled else { return }
            await self?.expired(request: id, link: link)
        }
    }

    // MARK: - Answers

    private func received(_ exchange: Exchange, request id: UInt64, link number: Int) {
        guard let link = links[number], let entry = link.inFlight.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        link.credits.release(entry.credit)
        let call = entry.call
        switch exchange {
        case .failed(let error):
            if error == .interrupted { serviceDied(link) }
            finish(call, .failure(.wire(error)))
        case .reply(let envelope, let payload):
            link.answered = true
            if superseded(call) {
                // A superseded call's reply is never delivered, however it arrives.
                call.promise.fulfil(.failure(.superseded))
                watch?(.discarded(call: call.number, request: id, link: number, why: .superseded))
            } else if call.isResolved {
                watch?(.discarded(call: call.number, request: id, link: number, why: .late))
            } else {
                watch?(.answered(call: call.number, request: id, link: number))
                deliver(call, Response.read(envelope, payload: payload, answering: entry.request).mapError(ClientFailure.wire))
            }
        }
        endIfDrained(link)
        pump()
    }

    private func deliver(_ call: Call, _ outcome: ClientOutcome) {
        if case .failure(.wire(.core(.staleHandle))) = outcome, call.unchecked == nil, call.reopens == nil, !call.retried {
            let named = call.operation.namedDicts.filter { registry[$0] != nil }
            if !named.isEmpty {
                call.retried = true
                return reopen(named, then: call)
            }
        }
        if let target = call.reopens { return reopened(target, outcome) }
        if call.unchecked == nil, let package = call.package, case .success(let delivered) = outcome,
           case .opened(.ready(let dict, _, _)) = delivered.answer {
            registry[dict] = Registered(package: package, current: dict)
            callersID[dict] = dict
        }
        call.promise.fulfil(outcome.map { Delivered(answer: $0.answer.renamingDicts { callersID[$0] ?? $0 }, payload: $0.payload) })
    }

    /// An outcome with no reply to read: a transport failure, a deadline, a refusal made here.
    private func finish(_ call: Call, _ outcome: ClientOutcome) {
        if let target = call.reopens { return reopened(target, outcome) }
        call.promise.fulfil(outcome)
    }

    /// Opens `dicts` again, each once however many calls wait on it, then sends `call` again.
    private func reopen(_ dicts: [DictId], then call: Call) {
        call.awaiting = Set(dicts)
        for dict in dicts {
            if reopening[dict] != nil {
                reopening[dict, default: []].append(call)
                continue
            }
            reopening[dict] = [call]
            guard let package = registry[dict]?.package else { continue }
            let opener = makeCall(.openPackage(spec: package.spec), caller: nil, package: package, progress: nil)
            opener.reopens = dict
            queue.insert(opener, at: 0)
        }
    }

    private func reopened(_ dict: DictId, _ outcome: ClientOutcome) {
        let waiting = reopening.removeValue(forKey: dict) ?? []
        let failure: ClientFailure?
        switch outcome {
        case .success(let delivered):
            switch delivered.answer {
            case .opened(.ready(let now, _, _)) where registry[dict] != nil:
                if let before = registry[dict]?.current { callersID[before] = nil }
                registry[dict]?.current = now
                callersID[now] = dict
                watch?(.reopened(dict: dict, as: now))
                failure = nil
            case .opened(.needsImport(let reason)):
                failure = .reopenNeedsImport(dict: dict, reason: reason)
            default:
                failure = .wire(.core(.staleHandle(detail: "the dictionary was closed while it was being opened again")))
            }
        case .failure(let why):
            failure = why
        }
        for call in waiting {
            if let failure {
                call.promise.fulfil(.failure(failure))
                continue
            }
            call.awaiting.remove(dict)
            if call.awaiting.isEmpty { queue.append(call) }
        }
    }

    private func expired(request id: UInt64, link number: Int) {
        guard let link = links[number], let entry = link.inFlight[id], !entry.call.isResolved else { return }
        let deadline = entry.deadline ?? .zero
        // The call stays in flight on the link: its credit is counted until its reply or the connection's end.
        finish(entry.call, .failure(.wire(.timedOut(deadline: deadline))))
        watch?(.timedOut(call: entry.call.number, request: id, link: number))
        if entry.request.operation.reportsProgress {
            send(makeCall(.cancel(request: id), caller: nil, package: nil, progress: nil), on: link)
        } else if Deadlines.abandonsConnectionOnExpiry(entry.request.operation) {
            abandon(link)
        }
    }

    // MARK: - Connections

    private func currentLink() -> Link {
        if let current { return current }
        nextLink += 1
        let number = nextLink
        let events = ConnectionEvents(
            interrupted: { [weak self] in Task { await self?.interrupted(link: number) } },
            invalidated: { [weak self] in Task { await self?.invalidated(link: number) } },
            event: { [weak self] data in Task { await self?.event(data, link: number) } })
        let link = Link(number: number, connection: connect(events))
        links[number] = link
        current = link
        watch?(.connected(link: number))
        return link
    }

    /// A credited call passed its deadline: this connection takes no more calls, so the next go on a new one with every
    /// credit, while the stalled call's credit goes with the old (`Credits`).
    private func abandon(_ link: Link) {
        guard !link.retired else { return }
        link.retired = true
        if current === link { current = nil }
        watch?(.abandoned(link: link.number))
        log.notice("abandoned connection \(link.number): a credited call passed its deadline")
        let number = link.number, grace = options.retiredGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.graceEnded(link: number)
        }
        endIfDrained(link)
        pump()
    }

    private func endIfDrained(_ link: Link) {
        guard link.retired, link.inFlight.isEmpty else { return }
        end(link)
    }

    private func graceEnded(link number: Int) {
        guard let link = links[number] else { return }
        guard link.inFlight.values.allSatisfy(\.call.isResolved) else {
            let grace = options.retiredGrace
            Task { [weak self] in
                try? await Task.sleep(for: grace)
                await self?.graceEnded(link: number)
            }
            return
        }
        end(link)
    }

    private func end(_ link: Link) {
        links[link.number] = nil
        if current === link { current = nil }
        for entry in link.inFlight.values {
            entry.timer?.cancel()
            finish(entry.call, .failure(.wire(.invalidated)))
        }
        link.inFlight.removeAll()
        link.connection.invalidate()
    }

    /// The service is gone: the next call on this connection starts it again, so it waits for a cold start.
    private func serviceDied(_ link: Link) {
        link.answered = false
    }

    private func interrupted(link number: Int) {
        watch?(.interrupted(link: number))
        guard let link = links[number] else { return }
        log.notice("connection \(number) interrupted: the service exited or crashed")
        serviceDied(link)
        for entry in link.inFlight.values {
            entry.timer?.cancel()
            finish(entry.call, .failure(.wire(.interrupted)))
        }
        link.inFlight.removeAll()
        link.credits = Credits()
        endIfDrained(link)
        pump()
    }

    private func invalidated(link number: Int) {
        watch?(.invalidated(link: number))
        guard let link = links.removeValue(forKey: number) else { return }
        if current === link { current = nil }
        for entry in link.inFlight.values {
            entry.timer?.cancel()
            finish(entry.call, .failure(.wire(.invalidated)))
        }
        link.inFlight.removeAll()
        pump()
    }

    private func event(_ data: Data, link number: Int) {
        guard case .success(let event) = ServiceEvent.read(data),
              let link = links[number], let entry = link.inFlight[event.request] else { return }
        switch event.kind {
        case .progress(let done, let total):
            entry.call.progress?(done, total)
            if !entry.call.isResolved { armSilence(entry, id: event.request, link: number) }
        }
    }
}
