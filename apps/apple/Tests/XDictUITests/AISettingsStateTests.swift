import Foundation
import Testing
import XDictAI
import XDictTestSupport
@testable import XDictUI

/// **The pane's state across a change the reader makes while it works** (audit findings, 2026-10-25): a sign-in belongs
/// to the Codex source, a status check and a key verdict belong to the configuration they were made for, a login's
/// lines keep the login's order, and an address mid-edit is the reader's text, never a silent overwrite.
@MainActor
struct AISettingsStateTests {
    /// The suite this test's preferences write to, alive until the test's own instance goes (`TestDefaults`).
    let held = HeldDefaults()

    func preferences(cloud: Bool = true, profile: String? = nil) throws -> MeaningPreferences {
        let fixture = try TestDefaults(prefix: "ai.xdict.tests.ai-state")
        held.fixture = fixture
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: cloud)
        if let profile { preferences.chooseProfile(profile) }
        return preferences
    }

    // MARK: - The source switch

    /// **A sign-in belongs to Codex** (audit finding, 2026-10-25): choosing another source ends it, and its failure is not
    /// written as the new source's status.
    @Test func switchingTheSourceEndsTheSignInAndItsFailure() async throws {
        let gate = Flag()
        let model = AISettingsModel(preferences: try preferences(), login: { _ in
            while !gate.isSet { try? await Task.sleep(for: .milliseconds(10)) }
            throw AIProviderError.notSignedIn
        })
        model.select(.codexCLI)
        model.startSignIn()
        #expect(model.signingIn)
        model.select(.appleOnDevice)
        #expect(!model.signingIn, "the sign-in outlived the source")
        gate.set()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.status != .failed(.notSignedIn), "the old sign-in's failure landed on the new source")
    }

    // MARK: - The live check

    /// **A superseded check cannot publish**: the second check is current, and the first answers late.
    @Test func aSupersededStatusCheckDoesNotPublish() async throws {
        let calls = LockedCount()
        let started = Flag()
        let gate = Flag()
        let model = AISettingsModel(preferences: try preferences(), checkStatus: { _ in
            if calls.next() == 1 {
                started.set()
                while !gate.isSet { try? await Task.sleep(for: .milliseconds(10)) }
                return .ready("stale")
            }
            return .ready("fresh")
        })
        defer { gate.set() }
        let first = Task { await model.refreshStatus() }
        #expect(await eventually(2) { started.isSet }, "the first check never ran")
        await model.refreshStatus()
        gate.set()
        await first.value
        #expect(model.status == .ready("fresh"))
    }

    /// **A check the pane cancelled cannot publish either**: the result it was holding belongs to no pane.
    @Test func aCancelledStatusCheckDoesNotPublish() async throws {
        let model = AISettingsModel(preferences: try preferences(), checkStatus: { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return .ready("from a cancelled check")
        })
        let task = Task { await model.refreshStatus() }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await task.value
        #expect(model.status == .checking, "a cancelled check published its result")
    }

    // MARK: - The key's verdict

    /// **A failed test belongs to the configuration it was made for** (audit finding, 2026-10-25): another address shows
    /// what is still true of the key, not the old failure.
    @Test func aFailedKeyTestDoesNotOutliveItsConfiguration() async throws {
        let preferences = try preferences(profile: "deepseek")
        let model = AISettingsModel(preferences: preferences)
        preferences.setEndpoint("")                        // nothing to probe: the failure is `.unreachable`
        await model.testKey()
        #expect(model.keyState == .failed(.unreachable))
        model.chooseProfile("openai")                      // another configuration, and the view's task refreshes
        await model.refreshStatus()
        #expect(model.keyState == .absent, "the old failure stayed beside the new configuration")
    }

    /// **Replace clears the last verdict** (audit finding, 2026-10-25): the failure described the key being replaced.
    @Test func replacingTheKeyClearsItsFailure() throws {
        let fixture = try TestDefaults(prefix: "ai.xdict.tests.ai-state")
        held.fixture = fixture
        let keys = MemoryKeyStore()
        keys.failure = MeaningKeyError(status: -25308)
        let preferences = MeaningPreferences(defaults: fixture.database, keys: keys)
        preferences.choose(.http, cloud: true)
        let model = AISettingsModel(preferences: preferences)
        model.draftKey = "sk-new"
        model.saveKey()
        #expect(model.keyFailure != nil, "the refused save said nothing")
        model.replaceKey()
        #expect(model.keyFailure == nil)
        #expect(model.keyState == .absent)
    }

    // MARK: - The login's lines

    /// **The lines keep the login's order** (audit finding, 2026-10-25): delivered from the CLI's own thread, they reach
    /// the main actor in the order the tool printed them.
    @Test func loginLinesKeepTheToolsOrder() async {
        let received = LockedStrings()
        await Task.detached {
            for line in ["device page: https://example.com/device", "code: ABCD-EFGH", "waiting"] {
                AISettingsModel.deliver(line) { received.append($0) }
            }
        }.value
        #expect(await eventually(2) { received.values.count == 3 }, "the lines never reached the main actor")
        #expect(received.values == ["device page: https://example.com/device", "code: ABCD-EFGH", "waiting"])
    }

    // MARK: - The address field

    /// **An address mid-edit stays in the field, marked, and the last good address stays stored** (audit finding,
    /// 2026-10-25): neither a stray edit nor a paste's padding rewrites the server behind the reader's cursor.
    @Test func anInvalidAddressStaysInTheFieldAndIsNotStored() throws {
        let preferences = try preferences(profile: "custom")
        preferences.setEndpoint("https://api.example.com/v1")
        let model = AISettingsModel(preferences: preferences)
        #expect(model.draftEndpoint == "https://api.example.com/v1")

        model.draftEndpoint = "api.example.com"
        model.endpointTyped()
        #expect(model.endpointInvalid)
        #expect(model.draftEndpoint == "api.example.com", "the field replaced what the reader typed")
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1",
                "an invalid edit replaced the stored address")

        model.draftEndpoint = "  https://other.example.com/v1\n"
        model.endpointTyped()
        #expect(!model.endpointInvalid)
        #expect(model.draftEndpoint == "https://other.example.com/v1", "the paste's padding stayed in the field")
        #expect(preferences.settings.endpoint?.absoluteString == "https://other.example.com/v1")
    }

    /// **Test and Load Models refuse while the field is not an address**: their verdict would be about the one behind it.
    @Test func testAndLoadRefuseAnInvalidAddress() async throws {
        let preferences = try preferences(profile: "deepseek")
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in
            Issue.record("a load ran for an invalid address")
            return .success([])
        })
        model.draftEndpoint = "not an address"
        model.endpointTyped()
        await model.testKey()
        await model.loadModels()
        #expect(model.keyState == .absent, "Test spoke for the stored address while the field held another")
        #expect(model.modelsShown == .idle)
    }

    /// **Choosing a service fills the field with the service's address** (audit finding, 2026-10-25): the draft follows the
    /// stored value the service wrote, rather than showing the other row's address.
    @Test func choosingAServiceFillsTheAddressField() throws {
        let model = AISettingsModel(preferences: try preferences(profile: "custom"))
        model.chooseProfile("deepseek")
        #expect(model.draftEndpoint == "https://api.deepseek.com")
        #expect(!model.endpointInvalid)
    }
}

/// A list of strings the delivery closure (on the main queue) and the test share.
final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(string)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
