import Foundation
import Testing
import XDictBase
import XDictContract
@testable import XDictClient

/// The launch window's question, `versions` through the contract, as the app and `--handshake-report` ask it: the
/// versions under the core's own names, and every failure one of the window's four sentences.
struct LaunchHandshakeTests {
    @Test func theVersionsTravelUnderTheCoresNames() async throws {
        let service = FakeTransport { request, _ in
            .reply(Versions(protocolVersion: 1, core: "0.0.1", indexFormat: 2, normalization: 1), to: request)
        }
        let client = ServiceClient(connect: service.connect)
        #expect(await client.handshake() == .success(CoreVersions(protocolVersion: 1, core: "0.0.1", indexFormat: 2,
                                                                  normalization: 1)))
    }

    @Test func everyFailureIsOneOfTheWindowsSentences() {
        let cases: [(ClientFailure, HandshakeFailure)] = [
            (.wire(.timedOut(deadline: .seconds(10))), .timedOut(after: .seconds(10))),
            (.wire(.interrupted), .unreachable("wire(XDictContract.WireError.interrupted)")),
            (.wire(.invalidated), .unreachable("wire(XDictContract.WireError.invalidated)")),
        ]
        for (failure, sentence) in cases { #expect(ServiceClient.handshakeFailure(failure) == sentence) }
        guard case .unreadable = ServiceClient.handshakeFailure(.wire(.contractMismatch(service: 2, client: 1))) else {
            Issue.record("a contract mismatch is not unreadable")
            return
        }
        guard case .refused = ServiceClient.handshakeFailure(.wire(.core(.internalFault(detail: "x")))) else {
            Issue.record("a core failure is not refused")
            return
        }
    }
}
