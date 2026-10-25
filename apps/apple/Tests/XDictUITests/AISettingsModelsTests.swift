import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **The service's model list in Settings ▸ AI** (2026-10-25): fetched on the reader's ask, offered as a choice, stored
/// exactly as typing it would; a failed or superseded load says so rather than showing a stale list.
@MainActor
struct AISettingsModelsTests {
    static func preferences() -> MeaningPreferences {
        let suite = "ai.xdict.tests.ai-models." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("deepseek")
        return preferences
    }

    @Test func loadingShowsTheListAndChoosingStoresIt() async {
        let preferences = Self.preferences()
        let model = AISettingsModel(preferences: preferences, fetchModels: { request in
            #expect(request.profile.id == "deepseek")
            #expect(request.baseURL.absoluteString == "https://api.deepseek.com")
            return .success([AIModel(id: "deepseek-flash"), AIModel(id: "deepseek-v4-pro")])
        })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([AIModel(id: "deepseek-flash"), AIModel(id: "deepseek-v4-pro")]))
        #expect(model.modelChoices == ["deepseek-flash", "deepseek-v4-pro"])
        model.chooseModel("deepseek-v4-pro")
        #expect(preferences.settings.model == "deepseek-v4-pro")
    }

    /// **A list belongs to the configuration it came from**: changing the address hides it and offers the new service's
    /// hints instead — the menu never shows another service's models.
    @Test func aListForAnotherConfigurationIsNotShown() async {
        let preferences = Self.preferences()
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in
            .success([AIModel(id: "deepseek-flash")])
        })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([AIModel(id: "deepseek-flash")]))
        preferences.chooseProfile("openai")
        #expect(model.modelsShown == .idle)
        #expect(model.modelChoices.contains("gpt-5.4"), "the current service's own names are offered instead")
    }

    /// **A load the reader moved away from leaves no spinner behind**: returning to that configuration shows idle, not a
    /// request that no longer exists, and Load Models works again.
    @Test func aLoadTheReaderMovedAwayFromLeavesNothingBehind() async {
        let preferences = Self.preferences()
        let calls = LockedCount()
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let model = AISettingsModel(preferences: preferences, fetchModels: { _ in
            if calls.next() == 1 {
                started.continuation.yield()
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .success([AIModel(id: "deepseek-flash")])
            }
            return .success([AIModel(id: "openai-listed")])
        })
        let first = Task { await model.loadModels() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        preferences.chooseProfile("openai")   // moved away without loading
        gate.continuation.yield()
        await first.value
        preferences.chooseProfile("deepseek") // back to the configuration the load belonged to
        #expect(model.modelsShown != .loading)
    }

    /// **An empty list from the service is authoritative**: the unfetched hints must not be offered over it.
    @Test func anEmptyListFromTheServiceOffersNoHints() async {
        let model = AISettingsModel(preferences: Self.preferences(), fetchModels: { _ in .success([]) })
        await model.loadModels()
        #expect(model.modelsShown == .loaded([]))
        #expect(model.modelChoices.isEmpty)
    }

    /// A failure is kept as its typed reason, and the service's few known names stay offered so the reader is not stuck.
    @Test func aFailedLoadSaysWhyAndKeepsTheHints() async {
        let model = AISettingsModel(preferences: Self.preferences(), fetchModels: { _ in .failure(.missingKey) })
        await model.loadModels()
        #expect(model.modelsShown == .failed(.missingKey))
        #expect(model.modelChoices == ["deepseek-flash", "deepseek-v4-pro"])
    }

    /// **A load the reader superseded cannot overwrite the newer one**: the first answers late, the second is current.
    @Test func aSupersededLoadDoesNotOverwrite() async {
        let calls = LockedCount()
        let firstStarted = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let model = AISettingsModel(preferences: Self.preferences(), fetchModels: { _ in
            let n = calls.next()
            if n == 1 {
                firstStarted.continuation.yield()
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .success([AIModel(id: "stale")])
            }
            return .success([AIModel(id: "fresh")])
        })
        let first = Task { await model.loadModels() }
        var started = firstStarted.stream.makeAsyncIterator()
        _ = await started.next()
        await model.loadModels()
        gate.continuation.yield()
        await first.value
        #expect(model.modelsShown == .loaded([AIModel(id: "fresh")]))
    }
}

/// A counter the fetch closure (off the main actor) can use.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
