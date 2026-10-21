import Foundation
import Synchronization
import XDictContract

/// Who asked: the unit of supersession (plan-macos-v1 choice 5, ADR-0009 decision 5). A caller's newer call makes its
/// older ones **superseded**: a queued one is dropped before it is sent, a sent one's reply is discarded when it comes.
/// Generations are the client's alone and never cross the wire.
public struct Caller: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// Why a call has no answer, as the client tells its caller: the contract's own kinds, and the client's.
public enum ClientFailure: Error, Hashable, Sendable {
    /// The service's answer, or the transport's failure (`WireError`).
    case wire(WireError)
    /// A newer call of the same caller replaced this one before its answer was delivered.
    case superseded
    /// A file of the package could not be opened here, so nothing was sent.
    case fileUnavailable(file: UUID, errno: Int32)
    /// The service restarted and the dictionary, opened again, needs an import: its file changed meanwhile.
    case reopenNeedsImport(dict: DictId, reason: ImportReason)
    /// A package operation given to `call` or `submit`, which carry no files: `open` and `importPackage` do.
    case needsFiles
}

public typealias ClientOutcome = Result<Delivered, ClientFailure>

/// One call's outcome, to be awaited: returned by `ServiceClient.submit` once the call is queued or sent, so a caller
/// can order its calls and still wait for each.
public struct CallTicket: Sendable {
    /// The call's number in this client, as `ClientEvent`s name it.
    public let number: UInt64
    let promise: Promise

    public func outcome() async -> ClientOutcome {
        await promise.value()
    }
}

/// What the client did, for the instruments and the log (observable by design): every call's fate is one of these
/// paths, and a check that a superseded call was never sent reads them.
public enum ClientEvent: Hashable, Sendable {
    public enum Discard: Hashable, Sendable {
        /// The reply came after the call's deadline had answered it.
        case late
        /// The reply came after a newer call of the same caller.
        case superseded
    }

    case connected(link: Int)
    case sent(call: UInt64, request: UInt64, link: Int)
    case answered(call: UInt64, request: UInt64, link: Int)
    case discarded(call: UInt64, request: UInt64, link: Int, why: Discard)
    /// A queued call superseded before it was sent: it never left the client.
    case dropped(call: UInt64)
    case timedOut(call: UInt64, request: UInt64, link: Int)
    /// A credited call passed its deadline: this connection takes no more calls and ends when its calls have.
    case abandoned(link: Int)
    case interrupted(link: Int)
    case invalidated(link: Int)
    /// A dictionary opened again after the service restarted: the caller's id now names the service's new one.
    case reopened(dict: DictId, as: DictId)
}

/// A value set once and awaited by any number of tasks.
final class Promise: Sendable {
    private struct State {
        var outcome: ClientOutcome?
        var waiting: [CheckedContinuation<ClientOutcome, Never>] = []
    }

    private let state = Mutex(State())

    /// Sets the outcome; false if it was already set, which changes nothing.
    @discardableResult
    func fulfil(_ outcome: ClientOutcome) -> Bool {
        let waiting = state.withLock { state -> [CheckedContinuation<ClientOutcome, Never>]? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiting = [] }
            return state.waiting
        }
        guard let waiting else { return false }
        for continuation in waiting { continuation.resume(returning: outcome) }
        return true
    }

    var isFulfilled: Bool {
        state.withLock { $0.outcome != nil }
    }

    func value() async -> ClientOutcome {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> ClientOutcome? in
                if let outcome = state.outcome { return outcome }
                state.waiting.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

extension ServiceOperation {
    /// The dictionaries an operation names, by handle.
    var namedDicts: [DictId] {
        switch self {
        case .close(let dict), .entry(let dict, _, _), .link(let dict, _, _, _), .resource(let dict, _, _),
             .health(let dict), .readingStyle(let dict), .displayOptions(let dict), .entryText(let dict, _, _),
             .studyNote(let dict, _, _, _, _, _), .definitionHash(let dict, _): [dict]
        case .lookup(_, let dicts, _), .suggest(_, let dicts, _): dicts
        case .versions, .importPackage, .cancel, .openPackage, .joinLineage, .splitLineage, .lineageOf, .convertApple,
             .cancelConversion, .ledgerRecord, .ledgerHistory, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo,
             .reviewSummary, .studyReanchor, .studyNoteAt, .exportData, .eraseData, .studyConflicts, .reviewResolve,
             .ledgerSync: []
        }
    }

    /// The same operation naming `rename(dict)` for each dictionary.
    func renamingDicts(_ rename: (DictId) -> DictId) -> ServiceOperation {
        switch self {
        case .close(let dict): .close(dict: rename(dict))
        case .entry(let dict, let entry, let render): .entry(dict: rename(dict), entry: entry, render: render)
        case .link(let dict, let url, let origin, let render): .link(dict: rename(dict), url: url, origin: origin, render: render)
        case .resource(let dict, let path, let render): .resource(dict: rename(dict), path: path, render: render)
        case .health(let dict): .health(dict: rename(dict))
        case .readingStyle(let dict): .readingStyle(dict: rename(dict))
        case .displayOptions(let dict): .displayOptions(dict: rename(dict))
        case .entryText(let dict, let entry, let text): .entryText(dict: rename(dict), entry: entry, text: text)
        case .studyNote(let dict, let entry, let text, let name, let stamp, let operation):
            .studyNote(dict: rename(dict), entry: entry, text: text, name: name, stamp: stamp, operation: operation)
        case .definitionHash(let dict, let entry): .definitionHash(dict: rename(dict), entry: entry)
        case .lookup(let query, let dicts, let options): .lookup(query: query, dicts: dicts.map(rename), options: options)
        case .suggest(let prefix, let dicts, let limit): .suggest(prefix: prefix, dicts: dicts.map(rename), limit: limit)
        case .versions, .importPackage, .cancel, .openPackage, .joinLineage, .splitLineage, .lineageOf, .convertApple,
             .cancelConversion, .ledgerRecord, .ledgerHistory, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo,
             .reviewSummary, .studyReanchor, .studyNoteAt, .exportData, .eraseData, .studyConflicts, .reviewResolve,
             .ledgerSync: self
        }
    }
}

extension Answer {
    /// The same answer naming `rename(dict)` for each dictionary in it.
    func renamingDicts(_ rename: (DictId) -> DictId) -> Answer {
        guard case .page(let page) = self else { return self }
        return .page(Page(hits: page.hits.map { Hit(dict: rename($0.dict), entry: $0.entry, headword: $0.headword, how: $0.how,
                                                    problems: $0.problems) },
                          total: page.total, generation: page.generation, problems: page.problems))
    }
}
