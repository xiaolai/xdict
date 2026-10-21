import Foundation
import Testing
import XDictUI

/// **The real Keychain, once, only when asked** (plan-ai-meaning WI-7): `KeychainKeyStore` writes one generic password
/// under a random service, reads it back, replaces it and removes it. The gate never runs this — a test process that is
/// re-signed between runs can be asked for access by the login keychain, and a prompt would hang a headless run. Run it
/// by hand on a Mac with a Keychain: `XDICT_KEYCHAIN_TESTS=1 swift test --filter MeaningKeychainTests`.
struct MeaningKeychainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XDICT_KEYCHAIN_TESTS"] == "1"))
    func theKeychainRoundTripsAKey() throws {
        let store = KeychainKeyStore(service: "ai.xdict.tests." + UUID().uuidString, account: "cloud-endpoint")
        defer { try? store.remove() }
        #expect(store.key() == nil, "a fresh service has no key")
        try store.save("sk-live-test-one")
        #expect(store.key() == "sk-live-test-one")
        // A second save replaces, never duplicates.
        try store.save("sk-live-test-two")
        #expect(store.key() == "sk-live-test-two")
        try store.remove()
        #expect(store.key() == nil)
    }
}
