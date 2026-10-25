import Foundation
import Testing
import XDictAI
import XDictTestSupport
@testable import XDictUI

/// **The service's model list in Settings ▸ AI** (2026-10-25): fetched on the reader's ask, offered as a choice, stored
/// exactly as typing it would; a failed or superseded load says so rather than showing a stale list.
@MainActor
struct AISettingsModelsTests {
    /// A cloud DeepSeek configuration over an isolated defaults suite; the suite must exist, or the test would silently
    /// write the reader's own defaults.
    static func preferences() throws -> MeaningPreferences {
        let suite = "ai.xdict.tests.ai-models." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("deepseek")
        return preferences
    }

    @Test func loadingShowsTheListAndChoosingStoresIt() async throws {
        let preferences = try Self.preferences()
        let model = AISettingsModel(preferences: preferences, fetchModels: { request in
            #expect(request.profile.id == "deepseek")
            #expect(request.baseURL.absoluteString == "https://api.deepseek.com")
            // **Names the fallback hints never contain**: choices equal to the hints would pass even if the fetched
            // list were ignored.
            return .success([AIModel(id: "listed-alpha"), AIModel(id: "listed-beta")])
        })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([AIModel(id: "listed-alpha"), AIModel(id: "listed-beta")]))
        #expect(model.modelChoices == ["listed-alpha", "listed-beta"])
        model.chooseModel("listed-beta")
        #expect(preferences.settings.model == "listed-beta")
    }

    /// **A list belongs to the address, the key and the service it came from**: changing any one of them hides it.
    @Test func aListForAnotherAddressOrKeyIsNotShown() async throws {
        let preferences = try Self.preferences()
        let listed = [AIModel(id: "listed-alpha")]
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in .success(listed) })
        await model.loadModels()
        #expect(model.modelsShown == .loaded(listed))

        preferences.setEndpoint("https://api.deepseek.com/v2")
        #expect(model.modelsShown == .idle, "another address")
        preferences.setEndpoint("https://api.deepseek.com")
        #expect(model.modelsShown == .loaded(listed), "the same configuration shows its list again")

        try preferences.setKey("key-b")
        #expect(model.modelsShown == .idle, "another key")
        try preferences.setKey(nil)
        #expect(model.modelsShown == .loaded(listed))
    }

    /// The service alone can differ at a common address: the identity must include it, not only the endpoint.
    @Test func aListForAnotherServiceAtTheSameAddressIsNotShown() async throws {
        let preferences = try Self.preferences()
        preferences.choose(.http, cloud: false)
        preferences.chooseProfile("custom")
        preferences.setEndpoint("http://127.0.0.1:11434/v1")
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in .success([AIModel(id: "listed-alpha")]) })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([AIModel(id: "listed-alpha")]))
        preferences.update { $0.profile = "ollama" }   // same address, another service
        #expect(model.modelsShown == .idle)
    }

    @Test func anEmptyListFromTheServiceOffersNoHints() async throws {
        let model = AISettingsModel(preferences: try Self.preferences(), fetchModels: { _ in .success([]) })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([]))
        #expect(model.modelChoices.isEmpty)
    }

    /// A failure is kept as its typed reason, and the service's few known names stay offered so the reader is not stuck.
    @Test func aFailedLoadSaysWhyAndKeepsTheHints() async throws {
        let model = AISettingsModel(preferences: try Self.preferences(), fetchModels: { _ in .failure(.missingKey) })
        await model.loadModels()
        #expect(model.modelsShown == .failed(.missingKey))
        #expect(model.modelChoices == ["deepseek-flash", "deepseek-v4-pro"])
    }

    /// **A load the reader superseded cannot overwrite the newer one**: the first answers late, the second is current.
    @Test func aSupersededLoadDoesNotOverwrite() async throws {
        let preferences = try Self.preferences()
        let calls = LockedCount()
        let started = Flag()
        let gate = Flag()
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in
            if calls.next() == 1 {
                started.set()
                while !gate.isSet { try? await Task.sleep(for: .milliseconds(10)) }
                return .success([AIModel(id: "stale")])
            }
            return .success([AIModel(id: "fresh")])
        })
        defer { gate.set() }
        let first = Task { await model.loadModels() }
        #expect(await eventually(2) { started.isSet }, "the first fetch never started")
        await model.loadModels()
        gate.set()
        await first.value
        #expect(model.modelsShown == .loaded([AIModel(id: "fresh")]))
    }

    /// **A load the reader moved away from leaves no spinner behind**: returning to that configuration shows idle, and
    /// Load Models works from there — the retry really fetches again.
    @Test func aLoadTheReaderMovedAwayFromLeavesNothingBehind() async throws {
        let preferences = try Self.preferences()
        let calls = LockedCount()
        let started = Flag()
        let gate = Flag()
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in
            if calls.next() == 1 {
                started.set()
                while !gate.isSet { try? await Task.sleep(for: .milliseconds(10)) }
                return .success([AIModel(id: "listed-alpha")])
            }
            return .success([AIModel(id: "listed-beta")])
        })
        defer { gate.set() }
        let first = Task { await model.loadModels() }
        #expect(await eventually(2) { started.isSet }, "the first fetch never started")
        preferences.chooseProfile("openai")   // moved away without loading
        gate.set()
        await first.value
        preferences.chooseProfile("deepseek") // back to the configuration the load belonged to
        #expect(model.modelsShown == .idle)
        await model.loadModels()
        #expect(model.modelsShown == .loaded([AIModel(id: "listed-beta")]))
        #expect(calls.value == 2, "the retry did not ask the service again")
    }

    /// **A press cancelled before its body ran does nothing**: it must not start a request, set a spinner, or let its
    /// generation speak for the pane after it is gone.
    @Test func aCancelledLoadNeverStarts() async throws {
        let model = AISettingsModel(preferences: try Self.preferences(), fetchModels: { _ in .failure(.cancelled) })
        let task = Task { () -> Void in
            try? await Task.sleep(for: .milliseconds(200))
            await model.loadModels()
        }
        task.cancel()
        await task.value
        #expect(model.modelsShown == .idle)
    }

    /// **The pane's disappear drops a load's answer** (a request that outlived its pane cannot land).
    @Test func aDiscardedLoadLeavesTheListIdle() async throws {
        let started = Flag()
        let gate = Flag()
        let model = AISettingsModel(preferences: try Self.preferences(), fetchModels: { _ in
            started.set()
            while !gate.isSet { try? await Task.sleep(for: .milliseconds(10)) }
            return .success([AIModel(id: "late")])
        })
        defer { gate.set() }
        let first = Task { await model.loadModels() }
        #expect(await eventually(2) { started.isSet }, "the fetch never started")
        model.discardModelLoad()
        gate.set()
        await first.value
        #expect(model.modelsShown == .idle)
    }
}

/// A counter the fetch closure (off the main actor) can use.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A one-way flag the fetch closure and the test share.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
