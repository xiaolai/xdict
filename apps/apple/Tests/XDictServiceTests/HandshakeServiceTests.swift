import Foundation
import Testing
import XDictBase
import XDictCore
@testable import XDictService

/// The service's side of the handshake: its own listener delegate, behind a real NSXPC connection in this process,
/// answers with the versions of the core it links — the same answer `Generated/core-versions.json` records and the
/// bundle's service must give on the E2E Mac.
struct HandshakeServiceTests {
    @Test func theServiceAnswersWithTheCoresVersions() async throws {
        let delegate = ServiceDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let core = XDictCore.versions()
        let outcome = await HandshakeClient.ask(endpoint: listener.endpoint, deadline: .seconds(10))
        #expect(outcome == .success(CoreVersions(
            protocolVersion: core.protocol, core: core.core, indexFormat: core.indexFormat,
            normalization: core.normalization)))
    }

    /// Every field of the core's `Versions` reaches the wire, by name; a field added to the core and not carried is
    /// caught by the core's own record changing shape (the memberwise initialiser below stops compiling).
    @Test func theWireValueCarriesEveryField() {
        let core = Versions(protocol: 7, core: "9.8.7", indexFormat: 6, normalization: 5)
        #expect(HandshakeHandler.wire(core)
                == CoreVersions(protocolVersion: 7, core: "9.8.7", indexFormat: 6, normalization: 5))
    }

    /// The control: what `Generated/core-versions.json` holds is what the binding answers in this process, so the E2E
    /// stage that compares the shipped service with it compares like with like.
    @Test func theRecordedVersionsAreTheBindingsOwn() throws {
        let recorded = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Generated/core-versions.json")
        let decoded = try JSONDecoder().decode(CoreVersions.self, from: Data(contentsOf: recorded))
        #expect(decoded == HandshakeHandler.wire(XDictCore.versions()))
    }
}
