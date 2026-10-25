import Foundation
import XDictClient
import XDictContract

/// One call queued with the service, whose outcome is awaited apart from the queueing: so a search can queue every
/// dictionary's lookup in the reader's order first, and then wait for each on its own (Q12).
public struct PendingCall: Sendable {
    public let outcome: @Sendable () async -> ClientOutcome

    public init(outcome: @escaping @Sendable () async -> ClientOutcome) {
        self.outcome = outcome
    }
}

/// **What the main window asks of the dictionary service**: `ServiceClient` in the app, a fake in the tests.
///
/// - `queue` sends operations as one caller's, in the order given; with `superseding`, every earlier call of that caller
///   is superseded first (ADR-0009 decision 5: a queued one is dropped before it is sent, a sent one's late reply is
///   never delivered). A search's lookups, its pages and its suggestions are queued this way.
/// - `request` is a call no other supersedes: an entry, a resource or a link, which the entry view orders itself.
public protocol SearchBackend: Sendable {
    func queue(_ operations: [ServiceOperation], as caller: Caller, superseding: Bool) async -> [PendingCall]
    /// Supersedes every call `caller` made so far, queueing none: a lookup with no dictionary to ask.
    func supersede(_ caller: Caller) async
    func request(_ operation: ServiceOperation) async -> ClientOutcome
}

extension ServiceClient: SearchBackend {
    public func queue(_ operations: [ServiceOperation], as caller: Caller, superseding: Bool) -> [PendingCall] {
        // **An empty queue still supersedes when it says so** (audit round 1, 2026-10-26): the protocol promises that
        // `superseding` answers every earlier call of the caller, and a lookup with no dictionary to ask relies on it.
        // `submit` is what supersedes a non-empty batch.
        if superseding, operations.isEmpty {
            supersede(caller)
            return []
        }
        return operations.enumerated().map { index, operation in
            let ticket = submit(operation, as: caller, supersedingEarlier: superseding && index == 0)
            return PendingCall { await ticket.outcome() }
        }
    }

    public func request(_ operation: ServiceOperation) async -> ClientOutcome {
        await call(operation, as: nil, supersedingEarlier: false)
    }
}

/// The answers the window reads, out of the contract's envelopes.
extension ClientOutcome {
    var page: Result<Page, ClientFailure> {
        flatMap { delivered in
            guard case .page(let page) = delivered.answer else { return .failure(.wire(.undecodable(detail: "not a page"))) }
            return .success(page)
        }
    }

    var suggestions: Result<[String], ClientFailure> {
        flatMap { delivered in
            guard case .suggestions(let keys) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not suggestions")))
            }
            return .success(keys)
        }
    }

    var phraseAnswer: Result<PhraseAnswer, ClientFailure> {
        flatMap { delivered in
            guard case .phrases(let answer) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not phrases")))
            }
            return .success(answer)
        }
    }

    var examples: Result<Examples, ClientFailure> {
        flatMap { delivered in
            guard case .examples(let examples) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not examples")))
            }
            return .success(examples)
        }
    }

    var entryText: Result<EntryText, ClientFailure> {
        flatMap { delivered in
            guard case .entryText(let projected) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not an entry's text")))
            }
            return .success(projected)
        }
    }
}

extension SearchBackend {
    /// **An entry as plain text** (contract 8; ADR-0021 d.5): the whole entry projected for a consumer that reads it —
    /// the AI pane's question. `maxTextBytes` is the caller's budget; a cut comes back as `complete: false` with its
    /// report, never as an error. A request no other call supersedes, like an entry (the entry view's own ordering).
    public func entryText(_ dict: DictId, entry: EntryRef, maxTextBytes: UInt64,
                          maxBodyBytes: UInt64 = RenderContext.reader.maxBodyBytes) async -> Result<EntryText, ClientFailure> {
        let text = TextRenderContext(maxBodyBytes: maxBodyBytes, maxTextBytes: maxTextBytes)
        return await request(.entryText(dict: dict, entry: entry, text: text)).entryText
    }
}
