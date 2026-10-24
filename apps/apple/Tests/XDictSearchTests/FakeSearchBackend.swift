import Foundation
import Synchronization
import XDictClient
import XDictContract
import XDictSearch

/// An outcome set once and awaited by any number of tasks.
final class Slot: Sendable {
    private let state = Mutex<(outcome: ClientOutcome?, waiting: [CheckedContinuation<ClientOutcome, Never>])>((nil, []))

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

    var isFulfilled: Bool { state.withLock { $0.outcome != nil } }

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

/// **The dictionary service as the main window sees it, faked**: lookups answered from the test's `pages`, suggestions
/// from its `suggest`, an entry's calls from `answer`. A dictionary can be held, so its lookups wait until released; a
/// caller's superseding call answers its earlier unanswered calls `superseded`, as `ServiceClient` does — unless
/// `honoursSupersession` is off, which delivers a held answer late anyway, so the model's own guard can be seen.
actor FakeSearchBackend: SearchBackend {
    struct Queued: Sendable {
        let operation: ServiceOperation
        let caller: Caller
        let superseding: Bool
    }

    private(set) var queued: [Queued] = []
    private(set) var requests: [ServiceOperation] = []
    private(set) var superseded: [Caller] = []
    private var held: Set<DictId> = []
    private var waiting: [(caller: Caller, dict: DictId?, slot: Slot, outcome: ClientOutcome)] = []
    var honoursSupersession = true
    var pages: @Sendable (_ query: String, _ dict: DictId, _ options: LookupOptions) -> Result<Page, ClientFailure>
    var suggest: @Sendable (_ prefix: String, _ dicts: [DictId]) -> [String] = { _, _ in [] }
    var answer: @Sendable (ServiceOperation) -> ClientOutcome = { _ in .failure(.wire(.interrupted)) }

    init(pages: @escaping @Sendable (String, DictId, LookupOptions) -> Result<Page, ClientFailure>) {
        self.pages = pages
    }

    func hold(_ dict: DictId) { held.insert(dict) }

    func release(_ dict: DictId) {
        held.remove(dict)
        let ready = waiting.filter { $0.dict == dict }
        waiting.removeAll { $0.dict == dict }
        for item in ready { item.slot.fulfil(item.outcome) }
    }

    func setSuggest(_ suggest: @escaping @Sendable (String, [DictId]) -> [String]) { self.suggest = suggest }
    func setAnswer(_ answer: @escaping @Sendable (ServiceOperation) -> ClientOutcome) { self.answer = answer }
    func setHonoursSupersession(_ honours: Bool) { honoursSupersession = honours }

    var lookups: [(query: String, dicts: [DictId], options: LookupOptions, caller: Caller, superseding: Bool)] {
        queued.compactMap {
            guard case .lookup(let query, let dicts, let options) = $0.operation else { return nil }
            return (query, dicts, options, $0.caller, $0.superseding)
        }
    }

    var suggestions: [(prefix: String, dicts: [DictId], limit: UInt32)] {
        queued.compactMap {
            guard case .suggest(let prefix, let dicts, let limit) = $0.operation else { return nil }
            return (prefix, dicts, limit)
        }
    }

    func queue(_ operations: [ServiceOperation], as caller: Caller, superseding: Bool) -> [PendingCall] {
        if superseding { supersede(caller) }
        return operations.enumerated().map { index, operation in
            queued.append(Queued(operation: operation, caller: caller, superseding: superseding && index == 0))
            let slot = Slot()
            let outcome: ClientOutcome
            var dict: DictId?
            switch operation {
            case .lookup(let query, let dicts, let options):
                dict = dicts.first
                outcome = pages(query, dicts.first ?? DictId(rawValue: ""), options)
                    .map { Delivered(answer: .page($0), payload: nil) }
            case .suggest(let prefix, let dicts, _):
                outcome = .success(Delivered(answer: .suggestions(suggest(prefix, dicts)), payload: nil))
            default:
                outcome = answer(operation)
            }
            if let dict, held.contains(dict) {
                waiting.append((caller, dict, slot, outcome))
            } else {
                slot.fulfil(outcome)
            }
            return PendingCall { await slot.value() }
        }
    }

    func supersede(_ caller: Caller) {
        superseded.append(caller)
        guard honoursSupersession else { return }
        for item in waiting where item.caller == caller { item.slot.fulfil(.failure(.superseded)) }
        waiting.removeAll { $0.caller == caller }
    }

    func request(_ operation: ServiceOperation) -> ClientOutcome {
        requests.append(operation)
        return answer(operation)
    }
}

/// The library as the model reads it: a list the test rewrites.
@MainActor
final class Sources {
    var list: [SearchSource]

    init(_ list: [SearchSource]) {
        self.list = list
    }
}

/// Values the tests share.
enum Fixture {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
    }

    static func handle(_ name: String) -> DictId { DictId(rawValue: "handle-\(name)") }
    static func edition(_ name: String) -> Edition { Edition(rawValue: "mdx-sha256-v1:\(name)") }

    static func source(_ n: Int, _ name: String, enabled: Bool = true, state: SourceState? = nil) -> SearchSource {
        SearchSource(id: id(n), name: name, edition: edition(name), preferencesKey: "lineage-\(name)", enabled: enabled,
                     state: state ?? .ready(handle(name)))
    }

    static func hit(_ dict: String, _ key: String, _ occurrence: UInt32 = 0, how: How = .exact) -> Hit {
        Hit(dict: handle(dict), entry: EntryRef(edition: edition(dict), key: key, occurrence: occurrence), headword: key,
            how: how, problems: [])
    }

    /// A page of `hits`, all of them, generation 1.
    static func page(_ hits: [Hit], generation: UInt32 = 1) -> Page {
        Page(hits: hits, total: UInt64(hits.count), generation: generation, problems: [])
    }

    static func result(_ dict: Int, _ name: String, _ key: String, _ occurrence: UInt32 = 0) -> ResultID {
        ResultID(dictionary: id(dict), entry: EntryRef(edition: edition(name), key: key, occurrence: occurrence))
    }
}

