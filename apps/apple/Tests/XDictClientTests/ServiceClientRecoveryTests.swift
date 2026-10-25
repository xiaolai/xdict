import Foundation
import Testing
import XDictTestSupport
import XDictContract
import XDictSearch
@testable import XDictClient

/// **How the client recovers**, against a fake service: a stalled connection abandoned, a service that died, handles
/// that went stale, an import gone silent — and what it refuses before anything is sent or seen.
struct ServiceClientRecoveryTests {
    /// **A credited call past its deadline abandons its connection**: the stalled calls answer `timedOut`, the waiting
    /// call goes on a new connection with every credit, and the old connection ends after its grace. Red with the
    /// abandonment removed (the waiting call never goes).
    @Test func aStalledBulkCallFreesTheClientByANewConnection() async {
        let service = FakeTransport { request, _ in
            switch request.operation {
            case .resource(_, "big", _): .silent
            case .resource(_, let path, _): .reply(.resource(.missing(path: path)), to: request)
            default: .reply(Fixture.versions, to: request)
            }
        }
        let log = EventLog()
        let client = ServiceClient(connect: service.connect, options: Fixture.options(), watch: log.record)
        _ = await client.versions()
        let stalled = [await client.submit(Fixture.resource("big")), await client.submit(Fixture.resource("big"))]
        let waiting = await client.submit(Fixture.resource("small"))
        for ticket in stalled {
            #expect(await ticket.outcome(within: .seconds(2)) == .failure(.wire(.timedOut(deadline: .milliseconds(60)))))
        }
        #expect(await waiting.outcome(within: .seconds(2))
            == .success(Delivered(answer: .resource(.missing(path: "small")), payload: nil)))
        #expect(service.sent.last.map { ($0.connection, $0.request.operation) } ?? (0, .versions) == (2, Fixture.resource("small")))
        #expect(log.all.contains(.abandoned(link: 1)))
        #expect(await log.wait { $0 == .invalidated(link: 1) }, "the abandoned connection was never ended")
    }

    /// **A service that dies fails the calls in flight `interrupted`**, and the next call starts it again on the same
    /// connection.
    @Test func aServiceThatDiesFailsTheCallsInFlightAndTheNextOneWorks() async {
        let service = FakeTransport { request, _ in
            Fixture.query(request) == "stuck" ? .silent : .reply(Fixture.versions, to: request)
        }
        let client = ServiceClient(connect: service.connect)
        let stuck = await client.submit(Fixture.lookup("stuck"))
        service.interruptAll()
        #expect(await stuck.outcome(within: .seconds(2)) == .failure(.wire(.interrupted)))
        #expect(await client.versions() == .success(Fixture.versions))
        #expect(service.connections.count == 1)
    }

    /// **Handles survive a restart**: the service answers `staleHandle`, the client opens the package again, sends the
    /// call once more under the new handle, and answers under the caller's. Red with the reopening removed.
    @Test func aStaleHandleIsOpenedAgainUnderTheCallersId() async throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DictId(rawValue: "first"), second = DictId(rawValue: "second")
        let opens = Slot<Int>()
        let service = FakeTransport { request, files in
            switch request.operation {
            case .openPackage:
                let count = (opens.current ?? 0) + 1
                opens.set(count)
                guard files?.count == package.files.count else { return .failure(.refused(.missingHandle), to: request) }
                return .reply(.opened(.ready(dict: count == 1 ? first : second, edition: Fixture.edition, info: Fixture.info)),
                              to: request)
            case .lookup(_, let dicts, _) where dicts == [first]:
                return .failure(.core(.staleHandle(detail: "restarted")), to: request)
            case .lookup(_, let dicts, _):
                return .reply(Fixture.page(dicts.map(Fixture.hit(in:))), to: request)
            default:
                return .silent
            }
        }
        let log = EventLog()
        let client = ServiceClient(connect: service.connect, watch: log.record)
        guard case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the package did not open")
            return
        }
        #expect(dict == first)
        let outcome = await client.call(Fixture.lookup("k", in: [first]))
        #expect(outcome == .success(Delivered(answer: Fixture.page([Fixture.hit(in: first)]), payload: nil)))
        #expect(opens.current == 2)
        #expect(log.all.contains(.reopened(dict: first, as: second)))
        #expect(service.sent.compactMap { sent -> [DictId]? in
            if case .lookup(_, let dicts, _) = sent.request.operation { return dicts }
            return nil
        } == [[first], [second]])
    }

    /// **A phrase answer's handles are the caller's** (contract 15): after a reopen the service names its new handle,
    /// and the client renames every dictionary in `matches` and in `coverage` back, so the pane never sees one.
    @Test func aPhraseAnswerAfterAReopenNamesTheCallersHandle() async throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DictId(rawValue: "first"), second = DictId(rawValue: "second")
        let opens = Slot<Int>()
        let service = FakeTransport { request, files in
            switch request.operation {
            case .openPackage:
                let count = (opens.current ?? 0) + 1
                opens.set(count)
                guard files?.count == package.files.count else { return .failure(.refused(.missingHandle), to: request) }
                return .reply(.opened(.ready(dict: count == 1 ? first : second, edition: Fixture.edition, info: Fixture.info)),
                              to: request)
            case .phrases(_, _, let dicts) where dicts == [first]:
                return .failure(.core(.staleHandle(detail: "restarted")), to: request)
            case .phrases:
                let answer = PhraseAnswer(
                    state: .found,
                    matches: [PhraseMatch(dict: second, phrase: "purple passage", location: 23, length: 14,
                                          separation: .none, gap: 0)],
                    coverage: [PhraseCoverage(dict: second, state: .ready)], total: 1, capped: false)
                return .reply(.phrases(answer), to: request)
            default:
                return .silent
            }
        }
        let client = ServiceClient(connect: service.connect)
        _ = await client.open(package)
        let outcome = await client.phrases("the review was full of purple passage",
                                           term: PhraseTerm(location: 30, length: 7), dicts: [first])
        guard case .success(let answer) = outcome else {
            Issue.record("no phrase answer: \(outcome)")
            return
        }
        #expect(answer.matches.map(\.dict) == [first], "the service's new handle leaked into the answer")
        #expect(answer.coverage.map(\.dict) == [first])
    }

    /// **A queue of no operations still supersedes when asked** (audit round 1, 2026-10-26): the protocol promises it,
    /// and a model that gives up its scope asks with nothing to send.
    @Test func anEmptyQueueStillSupersedesItsCaller() async {
        let service = FakeTransport { request, _ in
            Fixture.query(request) == "stuck" ? .silent : .reply(Fixture.versions, to: request)
        }
        let client = ServiceClient(connect: service.connect)
        let caller = Caller("empty-queue")
        let stuck = await client.submit(Fixture.lookup("stuck"), as: caller, supersedingEarlier: false)
        // Through the protocol: the concrete type's `queue` is its private list of calls.
        let backend: any SearchBackend = client
        #expect(await backend.queue([], as: caller, superseding: true).isEmpty)
        #expect(await stuck.outcome(within: .seconds(2)) == .failure(.superseded))
    }

    /// **Tokens** for every file a call reads, from `stat`, numbered in increasing order; a file gone is `missing`.
    @Test func tokensComeFromStatAndOnlyIncrease() async throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dict = DictId(rawValue: "d")
        let service = FakeTransport { request, _ in
            if case .openPackage = request.operation {
                return .reply(.opened(.ready(dict: dict, edition: Fixture.edition, info: Fixture.info)), to: request)
            }
            return .reply(Fixture.page(), to: request)
        }
        let client = ServiceClient(connect: service.connect)
        _ = await client.open(package)
        _ = await client.call(Fixture.lookup("a", in: [dict]))
        try FileManager.default.removeItem(at: package.files[1].locate())
        _ = await client.call(Fixture.lookup("b", in: [dict]))
        let sent = service.sent.map(\.request.tokens)
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.map(\.file) == package.files.map(\.spec.id) }, "not one token per file, in order")
        var info = stat()
        #expect(stat(package.files[0].locate().path, &info) == 0)
        #expect(sent[1][0].state == .present(FileIdentity(stat: info)))
        #expect(sent[2][1].state == .missing)
        for file in 0..<2 {
            let observed = sent.map { $0[file].observed }
            #expect(observed == observed.sorted() && Set(observed).count == 3, "observations not increasing: \(observed)")
        }
    }

    /// What the client refuses before sending: a package operation without its files, and a file it cannot open.
    @Test func aCallItCannotSendFailsHere() async throws {
        let service = FakeTransport { request, _ in .reply(Fixture.versions, to: request) }
        let client = ServiceClient(connect: service.connect)
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await client.call(.openPackage(spec: package.spec)) == .failure(.needsFiles))
        try FileManager.default.removeItem(at: package.files[0].locate())
        #expect(await client.open(package) == .failure(.fileUnavailable(file: package.files[0].spec.id, errno: ENOENT)))
        #expect(service.sent.isEmpty)
    }

    /// An import has no deadline, but one silent past `importSilence` answers `timedOut` and is cancelled in the service.
    @Test func aSilentImportIsCancelled() async throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeTransport { request, _ in
            if case .cancel = request.operation { return .reply(.cancellation(.stopping), to: request) }
            return .silent
        }
        let client = ServiceClient(connect: service.connect, options: Fixture.options())
        #expect(await client.importPackage(package) == .failure(.wire(.timedOut(deadline: .milliseconds(60)))))
        let cancelled = await eventuallyOffMain { service.sent.contains { $0.request.operation == .cancel(request: 1) } }
        #expect(cancelled, "the silent import was not cancelled")
    }

    /// A health check (WI-12) is bounded as an import is: silent past `importSilence`, it answers `timedOut` and is
    /// cancelled in the service; a deadline would end OED's, which reads 706,524 records.
    @Test func aSilentHealthCheckIsCancelled() async throws {
        let service = FakeTransport { request, _ in
            if case .cancel = request.operation { return .reply(.cancellation(.stopping), to: request) }
            return .silent
        }
        let client = ServiceClient(connect: service.connect, options: Fixture.options())
        let dict = DictId(rawValue: "0000000100000001")
        let ticket = await client.submitHealth(dict, progress: nil)
        #expect(await ticket.outcome() == .failure(.wire(.timedOut(deadline: .milliseconds(60)))))
        let cancelled = await eventuallyOffMain { service.sent.contains { $0.request.operation == .cancel(request: 1) } }
        #expect(cancelled, "the silent health check was not cancelled")
    }

    /// A payload over its ceiling is refused before anything sees it (`Response.read`, Codex objection 9).
    @Test func aPayloadOverItsCeilingIsRefused() async {
        let service = FakeTransport { request, _ in
            .reply(.resource(.found(path: "a.css", mime: "text/css")), payload: Data("12345".utf8), to: request)
        }
        let client = ServiceClient(connect: service.connect)
        let outcome = await client.call(Fixture.resource("a.css", render: RenderContext(maxBodyBytes: 4)))
        #expect(outcome == .failure(.wire(.refused(.payloadTooLarge(bytes: 5, limit: 4)))))
    }

    /// A service the process cannot reach by name ends the connection; the client answers `invalidated`, never traps.
    @Test func anUnreachableServiceIsInvalidated() async {
        let client = ServiceClient(connect: { events in
            XPCServiceConnection(NSXPCConnection(serviceName: "ai.xdict.app.NoSuchService"), events: events)
        })
        #expect(await client.versions() == .failure(.wire(.invalidated)))
    }

}
