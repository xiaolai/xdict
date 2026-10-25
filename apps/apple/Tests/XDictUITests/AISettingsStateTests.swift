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

    // MARK: - One identity, one shell word (audit round 1, 2026-10-25)

    /// **The check's identity is exactly what the check reads**: a key the local row never sends does not restart it,
    /// and the model it names does — the view's task and the stale-result guard share this one value.
    @Test func theCheckIdentityIsTheEffectiveConfiguration() throws {
        let preferences = try preferences(cloud: false)
        preferences.setModel("local-a")
        let first = AISettingsModel.sourceIdentity(preferences.settings)
        try preferences.setKey("unused-local-key")
        #expect(AISettingsModel.sourceIdentity(preferences.settings) == first,
                "a key the local row never sends restarted the check")
        preferences.setModel("local-b")
        #expect(AISettingsModel.sourceIdentity(preferences.settings) != first)
    }

    /// **The sign-in command quotes its folder as one shell word**: `$`, a backtick and `"` stay literal after a paste,
    /// and an apostrophe is closed, escaped and reopened.
    @Test func theSignInCommandQuotesItsFolderAsOneShellWord() {
        #expect(AISettings.shellQuoted("/Users/plain/Library") == "'/Users/plain/Library'")
        #expect(AISettings.shellQuoted("/Users/a b/$HOME/`x`/\"q\"") == "'/Users/a b/$HOME/`x`/\"q\"'")
        #expect(AISettings.shellQuoted("/Users/o'brien") == "'/Users/o'\\''brien'")
    }

    /// **One gate for the provider fakes** (audit round 3, 2026-10-25): short hops until released; a login's wait ends as
    /// its own cancellation.
    static func wait(until flag: Flag) async {
        while !flag.isSet { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func waitCancelling(until flag: Flag) async throws(AIProviderError) {
        while !flag.isSet {
            if Task.isCancelled { throw .cancelled }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The source switch

    /// **A sign-in belongs to Codex** (audit finding, 2026-10-25): choosing another source ends it, and its failure is not
    /// written as the new source's status.
    @Test func switchingTheSourceEndsTheSignInAndItsFailure() async throws {
        let gate = Flag()
        let started = Flag()
        let model = AISettingsModel(preferences: try preferences(), login: { _ in
            started.set()
            try await Self.waitCancelling(until: gate)
            throw AIProviderError.notSignedIn
        }, checkStatus: { _ in .ready("codex") })
        model.select(.codexCLI)
        // A published status first, so "the failure did not land" is distinguishable from "nothing ever ran".
        await model.refreshStatus()
        #expect(model.status == .ready("codex"))
        let login = model.startSignIn()
        #expect(model.signingIn)
        // **The login is running before the source moves** (audit round 2, 2026-10-25): a switch racing the task's start
        // tested nothing.
        #expect(await eventually(2) { started.isSet }, "the sign-in never started")
        model.select(.appleOnDevice)
        #expect(!model.signingIn, "the sign-in outlived the source")
        gate.set()
        // The login's own end, not a sleep: its failure is decided by the time this returns.
        await login?.value
        #expect(model.status == .ready("codex"), "the old sign-in's failure landed on the new source")
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
                await Self.wait(until: gate)
                return .ready("stale")
            }
            return .ready("fresh")
        })
        defer { gate.set() }
        let first = Task { await model.refreshStatus() }
        // **A check that never started fails here, not on the gate** (audit round 2, 2026-10-25): `#expect` continues, and
        // the second call would then block on the first one's gate forever.
        try #require(await eventually(2) { started.isSet }, "the first check never ran")
        await model.refreshStatus()
        gate.set()
        await first.value
        #expect(model.status == .ready("fresh"))
    }

    /// **A check the pane cancelled cannot publish either**: the result it was holding belongs to no pane.
    @Test func aCancelledStatusCheckDoesNotPublish() async throws {
        let entered = Flag()
        let release = Flag()
        // **The provider is released even when the start check throws** (audit round 3, 2026-10-25): otherwise a failed
        // prerequisite leaves an unstructured task polling behind the suite.
        defer { release.set() }
        let model = AISettingsModel(preferences: try preferences(), checkStatus: { _ in
            // **Cancellation lands mid-check by construction** (audit round 2, 2026-10-25): the provider proves it began
            // and then waits, so no sleep races a delay.
            entered.set()
            await Self.wait(until: release)
            return .ready("from a cancelled check")
        })
        let task = Task { await model.refreshStatus() }
        try #require(await eventually(2) { entered.isSet }, "the check never began")
        task.cancel()
        release.set()
        await task.value
        #expect(model.status != .ready("from a cancelled check"), "a cancelled check published its result")
        #expect(model.status == .checking, "the pane is left where the cancelled check began")
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

    /// **The lines keep the login's order** (audit finding, 2026-10-25): delivered from the tool's own thread, they reach
    /// the main actor through one FIFO queue, in the order the tool printed them. This is a delivery check, not a
    /// red-green control: the old per-line `Task` would usually pass it too, and the mechanism — `DispatchQueue.main`
    /// is first-in, first-out — is what the fix rests on.
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

    /// **A change the check does not read leaves its answer standing** (verification finding, 2026-10-25): the prompt's
    /// switch is not what a live check reads, so moving it must not discard the check's result and strand the pane at
    /// "Checking…" — the guard and the task's own trigger read one projection.
    @Test func aChangeTheCheckDoesNotReadKeepsItsResult() async throws {
        let started = Flag()
        let gate = Flag()
        let model = AISettingsModel(preferences: try preferences(), checkStatus: { _ in
            started.set()
            await Self.wait(until: gate)
            return .ready("found")
        })
        defer { gate.set() }
        let task = Task { await model.refreshStatus() }
        #expect(await eventually(2) { started.isSet }, "the check never ran")
        model.preferences.setSendEntryText(true)
        gate.set()
        await task.value
        #expect(model.status == .ready("found"), "a setting the check does not read stranded the pane")
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
