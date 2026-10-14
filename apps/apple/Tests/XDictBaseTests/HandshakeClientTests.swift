import Foundation
import Testing
import XDictBase

/// What `XDictBase` still holds since the contract replaced the WI-2 handshake (WI-3): the identities and the launch
/// window's versions. Asking for them is `XDictClientTests`' (`LaunchHandshakeTests`, `ServiceClientTests`).
struct HandshakeClientTests {
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
