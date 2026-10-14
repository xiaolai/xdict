import Foundation
import Synchronization
import XDictClient
import XDictContract

/// **The service's checks that need a real service** (plan-macos-v1 WI-3, done-when): refusals of what is not a
/// dictionary file, supersession, a stalled bulk call, a kill mid-lookup, the idle exit raced. Each makes its own client
/// (`makeClient`), so the stall's shortened deadlines and each check's event log are its alone. The app runs them against
/// its embedded, signed service (`--service-report`); the service's tests run those that do not end the service against
/// its listener in their own process.
public struct ServiceChecks: Sendable {
    public typealias MakeClient = @Sendable (ServiceClient.Options, (@Sendable (ClientEvent) -> Void)?) -> ServiceClient

    let fixtures: URL
    let scratch: URL
    let makeClient: MakeClient

    public init(fixtures: URL, scratch: URL, makeClient: @escaping MakeClient) {
        self.fixtures = fixtures
        self.scratch = scratch
        self.makeClient = makeClient
    }

    /// A new package of `tiny/` each time: its files get new ids, so bind it once per check.
    var tiny: DictionaryPackage {
        let dir = fixtures.appending(path: "tiny")
        return .of(mdx: dir.appending(path: "tiny.mdx"), volumes: [dir.appending(path: "tiny.mdd")],
                   sidecars: [dir.appending(path: "tiny.css")])
    }

    /// `big` is a 60 MiB record a lookup reads whole; `big.bin` a 63 MiB resource.
    var slow: DictionaryPackage {
        let dir = fixtures.appending(path: "slow")
        return .of(mdx: dir.appending(path: "slow.mdx"), volumes: [dir.appending(path: "slow.mdd")])
    }

    static let firstPage = LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)

    /// Opened, importing first if the service asks for it.
    func ready(_ package: DictionaryPackage, on client: ServiceClient) async -> Result<DictId, ClientFailure> {
        switch await client.open(package) {
        case .success(.ready(let dict, _, _)): return .success(dict)
        case .success(.needsImport):
            if case .failure(let why) = await client.importPackage(package) { return .failure(why) }
            switch await client.open(package) {
            case .success(.ready(let dict, _, _)): return .success(dict)
            case .success(let other): return .failure(.wire(.undecodable(detail: "opened after import: \(other)")))
            case .failure(let why): return .failure(why)
            }
        case .failure(let why): return .failure(why)
        }
    }

    /// Waits up to `timeout` for `condition`; whether it came true.
    static func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// The time `operation` takes, the least of `runs` (warm: the first is not counted), and its last outcome.
    func timed(_ operation: ServiceOperation, on client: ServiceClient, runs: Int = 3) async -> (Duration, ClientOutcome) {
        var best = Duration.seconds(3_600)
        var last = await client.call(operation)
        for _ in 0..<runs {
            let started = ContinuousClock.now
            last = await client.call(operation)
            best = min(best, ContinuousClock.now - started)
        }
        return (best, last)
    }
}

/// A client's events in order, each with when it happened.
public final class ClientEventLog: Sendable {
    private let events = Mutex<[(at: ContinuousClock.Instant, event: ClientEvent)]>([])

    public init() {}

    public var record: @Sendable (ClientEvent) -> Void {
        { [self] event in events.withLock { $0.append((ContinuousClock.now, event)) } }
    }

    public var all: [ClientEvent] { events.withLock { $0.map(\.event) } }

    /// When the first event matching `wanted` happened.
    public func first(_ wanted: (ClientEvent) -> Bool) -> ContinuousClock.Instant? {
        events.withLock { $0.first { wanted($0.event) }?.at }
    }

    /// Where in the order the first event matching `wanted` is.
    public func index(_ wanted: (ClientEvent) -> Bool) -> Int? {
        events.withLock { $0.firstIndex { wanted($0.event) } }
    }

    /// Waits up to `timeout` for an event matching `wanted`; whether one came.
    public func wait(_ timeout: Duration, for wanted: @Sendable (ClientEvent) -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if first(wanted) != nil { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return first(wanted) != nil
    }
}

extension ClientEvent {
    var callNumber: UInt64? {
        switch self {
        case .sent(let call, _, _), .answered(let call, _, _), .discarded(let call, _, _, _), .dropped(let call),
             .timedOut(let call, _, _): call
        case .connected, .abandoned, .interrupted, .invalidated, .reopened: nil
        }
    }

    var link: Int? {
        switch self {
        case .sent(_, _, let link), .answered(_, _, let link), .discarded(_, _, let link, _), .timedOut(_, _, let link),
             .connected(let link), .abandoned(let link), .interrupted(let link), .invalidated(let link): link
        case .dropped, .reopened: nil
        }
    }
}
