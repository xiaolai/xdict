import Foundation
import Testing
import XDictBase

/// The skeleton's handshake from the app's side, against services of the test's own over a real NSXPC connection
/// (an anonymous listener in this process): every way the answer can arrive, or not, ends in one typed outcome.
struct HandshakeClientTests {
    @Test func anAnswerIsTheVersionsItCarries() async throws {
        let sent = CoreVersions(protocolVersion: 1, core: "0.0.1", indexFormat: 2, normalization: 1)
        let service = FakeService { reply in reply(try? JSONEncoder().encode(sent), nil) }
        #expect(await HandshakeClient.ask(endpoint: service.endpoint, deadline: .seconds(5)) == .success(sent))
    }

    @Test func aServiceThatNeverAnswersIsTimedOut() async throws {
        let service = FakeService { _ in }
        let started = ContinuousClock.now
        let outcome = await HandshakeClient.ask(endpoint: service.endpoint, deadline: .milliseconds(300))
        #expect(outcome == .failure(.timedOut(after: .milliseconds(300))))
        // Bounded both ways: not before the deadline, and not long after it.
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(300) && waited < .seconds(5), "waited \(waited)")
    }

    @Test func anAnswerThatIsNotVersionsIsUnreadable() async throws {
        let service = FakeService { reply in reply(Data("not json".utf8), nil) }
        guard case .failure(.unreadable) = await HandshakeClient.ask(endpoint: service.endpoint, deadline: .seconds(5))
        else { Issue.record("an unreadable answer was not refused as one"); return }
    }

    @Test func aServiceThatSaysWhyItCannotAnswerIsRefused() async throws {
        let service = FakeService { reply in reply(nil, "the core could not be asked") }
        #expect(await HandshakeClient.ask(endpoint: service.endpoint, deadline: .seconds(5))
                == .failure(.refused("the core could not be asked")))
    }

    @Test func aConnectionTheServiceRefusesIsUnreachable() async throws {
        let service = FakeService(accepting: false) { reply in reply(nil, nil) }
        guard case .failure(.unreachable) = await HandshakeClient.ask(endpoint: service.endpoint, deadline: .seconds(5))
        else { Issue.record("a refused connection was not reported as unreachable"); return }
    }

    /// **Asked from the main actor, as the app asks it at launch, a transport error is an outcome, not a trap.** The
    /// WI-1 spike's client trapped in `dispatch_assert_queue` here when its error handler inherited main-actor
    /// isolation; this test crashes the process if that returns.
    @MainActor @Test func aRefusedConnectionAskedFromTheMainActorIsUnreachable() async throws {
        let service = FakeService(accepting: false) { reply in reply(nil, nil) }
        guard case .failure(.unreachable) = await HandshakeClient.ask(endpoint: service.endpoint, deadline: .seconds(5))
        else { Issue.record("a refused connection was not reported as unreachable"); return }
    }

    /// The fields travel under the names the rest of the harness reads (`Generated/core-versions.json`, the E2E
    /// `launch` stage): `protocol`, `core`, `indexFormat`, `normalization`, and nothing else.
    @Test func theWireNamesAreTheCoresOwn() throws {
        let versions = CoreVersions(protocolVersion: 3, core: "1.2.3", indexFormat: 4, normalization: 5)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(versions)) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["protocol", "core", "indexFormat", "normalization"])
        #expect(object?["protocol"] as? Int == 3)
        let back = try JSONDecoder().decode(CoreVersions.self, from: Data(
            #"{"core":"1.2.3","indexFormat":4,"normalization":5,"protocol":3}"#.utf8))
        #expect(back == versions)
    }

    /// Fixed by ADR-0001 decision 3: changing either costs readers their settings and their permission grants.
    @Test func theIdentitiesAreTheFixedOnes() {
        #expect(XDictIdentity.app == "ai.xdict.app")
        #expect(XDictIdentity.dictionaryService == "ai.xdict.app.DictionaryService")
    }
}

/// A service of the test's own: an anonymous listener in this process, exporting `HandshakeProtocol` with the answer
/// the test gives it, or refusing every connection.
private final class FakeService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    typealias Answer = @Sendable (@escaping @Sendable (Data?, String?) -> Void) -> Void
    private let listener = NSXPCListener.anonymous()
    private let accepting: Bool
    private let answer: Answer

    init(accepting: Bool = true, answer: @escaping Answer) {
        self.accepting = accepting
        self.answer = answer
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit { listener.invalidate() }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard accepting else { return false }
        connection.exportedInterface = NSXPCInterface(with: HandshakeProtocol.self)
        connection.exportedObject = Exported(answer: answer)
        connection.resume()
        return true
    }

    private final class Exported: NSObject, HandshakeProtocol {
        let answer: Answer
        init(answer: @escaping Answer) { self.answer = answer }
        func versions(withReply reply: @escaping @Sendable (Data?, String?) -> Void) { answer(reply) }
    }
}
