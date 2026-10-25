import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **What Settings ▸ AI remembers, and where** (plan-ai-meaning WI-6; ADR-0021 d.3, d.13): the source and its address
/// in the app's own preferences, the prompt edits per language and kind, and the cloud key only in the key store —
/// never in a defaults database, because a defaults file is readable by anything that can read the reader's account.
@MainActor
struct MeaningPreferencesTests {
    static func defaults() -> UserDefaults {
        let suite = "ai.xdict.tests.meaning." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFreshInstallHasNoSourceAndTheSwitchOff() {
        let preferences = MeaningPreferences(defaults: Self.defaults(), keys: MemoryKeyStore())
        #expect(preferences.settings.source == nil)
        #expect(preferences.settings.sendEntryText == false)
        #expect(preferences.settings.language == "en")
        #expect(preferences.settings.templates.isEmpty)
        #expect(preferences.hasKey == false)
    }

    @Test func theSourceAndItsAddressSurviveANewInstance() throws {
        let defaults = Self.defaults()
        let first = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        first.choose(.http, cloud: true)
        first.update {
            $0.endpoint = URL(string: "https://api.example.com/v1")
            $0.model = "a-model"
            $0.sendEntryText = true
        }
        let second = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        #expect(second.settings.source == .http)
        #expect(second.httpCloud)
        #expect(second.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        #expect(second.settings.model == "a-model")
        #expect(second.settings.sendEntryText)
    }

    @Test func anEditedTemplateSurvivesAndResetRestoresTheDefault() {
        let defaults = Self.defaults()
        let first = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        let shipped = meaningDefaultTemplate(language: "en", mode: .grounded)
        #expect(first.effectiveTemplate(language: "en", mode: .grounded) == shipped)
        #expect(first.storedTemplate(language: "en", mode: .grounded) == nil)
        first.setTemplate("Say what {term} means: {sentence} {entry}", language: "en", mode: .grounded)
        #expect(first.storedTemplate(language: "en", mode: .grounded) == "Say what {term} means: {sentence} {entry}")
        let second = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        #expect(second.storedTemplate(language: "en", mode: .grounded) == "Say what {term} means: {sentence} {entry}")
        // The other kind is untouched: one template never answers another mode's ask.
        #expect(second.storedTemplate(language: "en", mode: .sentenceOnly) == nil)
        second.resetTemplates(language: "en", mode: .grounded)
        #expect(second.storedTemplate(language: "en", mode: .grounded) == nil)
        #expect(second.effectiveTemplate(language: "en", mode: .grounded) == shipped)
    }

    /// **The chosen-sense kind keeps its own prompt** (plan-explain-sense WI-5; ADR-0029 d.6): three kinds, three
    /// templates, and an edit of one never changes another's question.
    @Test func theChosenSenseTemplateIsItsOwnKind() {
        let defaults = Self.defaults()
        let first = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        let shipped = meaningDefaultTemplate(language: "en", mode: .explainSense)
        #expect(!shipped.isEmpty)
        #expect(first.effectiveTemplate(language: "en", mode: .explainSense) == shipped)
        first.setTemplate("Which sense? {term} {sentence} {entry} {sense}", language: "en", mode: .explainSense)
        let second = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        #expect(second.storedTemplate(language: "en", mode: .explainSense)
            == "Which sense? {term} {sentence} {entry} {sense}")
        #expect(second.storedTemplate(language: "en", mode: .grounded) == nil, "one kind answers another's ask")
        #expect(second.storedTemplate(language: "en", mode: .sentenceOnly) == nil)
    }

    @Test func aTemplateEditIsKeptPerLanguage() {
        let preferences = MeaningPreferences(defaults: Self.defaults(), keys: MemoryKeyStore())
        preferences.setTemplate("English wording", language: "en", mode: .grounded)
        preferences.setTemplate("中文写法", language: "zh-Hans", mode: .grounded)
        #expect(preferences.storedTemplate(language: "en", mode: .grounded) == "English wording")
        #expect(preferences.storedTemplate(language: "zh-Hans", mode: .grounded) == "中文写法")
    }

    @Test func theKeyGoesToTheKeyStoreAndNeverToDefaults() throws {
        let defaults = Self.defaults()
        let keys = MemoryKeyStore()
        let preferences = MeaningPreferences(defaults: defaults, keys: keys)
        try preferences.setKey("sk-not-in-defaults")
        #expect(preferences.hasKey)
        #expect(keys.key() == "sk-not-in-defaults")
        #expect(preferences.settings.key == "sk-not-in-defaults")
        let everything = defaults.dictionaryRepresentation().values.map { String(describing: $0) }.joined(separator: "\n")
        #expect(!everything.contains("sk-not-in-defaults"), "the key reached a defaults database")
        // A new instance reads it back from the store.
        let second = MeaningPreferences(defaults: defaults, keys: keys)
        #expect(second.settings.key == "sk-not-in-defaults")
        try second.setKey(nil)
        #expect(second.hasKey == false)
        #expect(second.settings.key == nil)
        #expect(keys.key() == nil)
    }

    /// **A cloud key is never sent to a server chosen as local** (audit finding, 2026-10-20).
    @Test func theKeyBelongsToTheCloudRowOnly() throws {
        let preferences = MeaningPreferences(defaults: Self.defaults(), keys: MemoryKeyStore())
        try preferences.setKey("sk-cloud-only")
        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.usesKey)
        #expect(MeaningProviders.apiKey(preferences.settings) == "sk-cloud-only")
        preferences.choose(.http, cloud: false)
        #expect(!preferences.settings.usesKey)
        #expect(MeaningProviders.apiKey(preferences.settings) == nil)
        preferences.choose(.claudeCLI)
        #expect(MeaningProviders.apiKey(preferences.settings) == nil, "a CLI source gets no HTTP key")
    }

    /// **The chosen service fills in its address and survives a relaunch** (2026-10-25); Custom keeps the address the
    /// reader typed rather than clearing it.
    @Test func theChosenServiceSurvivesAndFillsItsAddress() {
        let defaults = Self.defaults()
        let first = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        first.choose(.http, cloud: true)
        first.chooseProfile("deepseek")
        #expect(first.settings.profile == "deepseek")
        #expect(first.settings.endpoint?.absoluteString == "https://api.deepseek.com")
        let second = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        #expect(second.settings.profile == "deepseek")
        #expect(second.settings.endpoint?.absoluteString == "https://api.deepseek.com")
        second.chooseProfile("custom")
        #expect(second.settings.profile == "custom")
        #expect(second.settings.endpoint?.absoluteString == "https://api.deepseek.com",
                "choosing Custom must not erase the address in the field")
    }

    /// **A service from the other row is hidden, never forgotten** (2026-10-25): the local row uses Custom while a cloud
    /// service is stored, and switching back restores it.
    @Test func aServiceFromTheOtherRowIsHiddenNotForgotten() {
        let preferences = MeaningPreferences(defaults: Self.defaults(), keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("deepseek")
        preferences.choose(.http, cloud: false)
        #expect(MeaningProviders.profile(preferences.settings).id == "custom")
        preferences.choose(.http, cloud: true)
        #expect(MeaningProviders.profile(preferences.settings).id == "deepseek")
    }

    /// **An install that predates the choice is inferred from its address**, and the address itself is untouched.
    @Test func anAddressFromBeforeTheChoiceNamesItsService() {
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://openrouter.ai/api/v1/")) == "openrouter")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://api.deepseek.com/")) == "deepseek")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://api.example.com/v1")) == "custom")
        #expect(MeaningProfiles.matching(endpoint: nil) == "custom")
        let defaults = Self.defaults()
        defaults.set("https://openrouter.ai/api/v1", forKey: "meaning.endpoint")
        defaults.set(true, forKey: "meaning.http.cloud")
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        #expect(preferences.settings.profile == "openrouter")
        #expect(preferences.settings.endpoint?.absoluteString == "https://openrouter.ai/api/v1")
    }

    /// **The provider is built with the service's own auth and token-field preference** (sayso's profile table), and a
    /// profile from the other row never answers for the chosen one.
    @Test func theProviderGetsTheServicesAuthAndTokenField() throws {
        let openai = try #require(URL(string: "https://api.openai.com/v1"))
        var settings = MeaningSettings(source: .http, endpoint: openai, profile: "openai", usesKey: true)
        var config = MeaningProviders.httpConfiguration(settings, endpoint: openai)
        #expect(config.auth == .bearer)
        #expect(config.tokenField == .completionFirst)
        let deepseek = try #require(URL(string: "https://api.deepseek.com"))
        settings.profile = "deepseek"
        settings.endpoint = deepseek
        config = MeaningProviders.httpConfiguration(settings, endpoint: deepseek)
        #expect(config.tokenField == .maxTokensFirst)
        let ollama = try #require(URL(string: "http://127.0.0.1:11434/v1"))
        settings.profile = "ollama"
        settings.usesKey = false
        settings.endpoint = ollama
        let local = MeaningProviders.httpConfiguration(settings, endpoint: ollama)
        #expect(local.auth == .none)
        #expect(MeaningProviders.profile(settings).id == "ollama")
        settings.usesKey = true
        #expect(MeaningProviders.profile(settings).id == "custom", "a local profile never answers for the cloud row")
    }

    /// **A pasted address keeps its server** (2026-10-25): whitespace around it is not part of it, text that is not a
    /// URL yet cannot erase the stored address, and an emptied field is the reader asking for none.
    @Test func anAddressIsTrimmedAndAStrayWhitespaceCannotEraseIt() {
        let defaults = Self.defaults()
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        preferences.setEndpoint("  https://api.example.com/v1\n")
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        #expect(MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
            .settings.endpoint?.absoluteString == "https://api.example.com/v1", "the address was not persisted")
        // A field mid-edit, or text that is not a URL, leaves the last good address alone.
        preferences.setEndpoint("https://%zz")
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        // Emptying the field is the reader asking for no address.
        preferences.setEndpoint("  ")
        #expect(preferences.settings.endpoint == nil)
    }

    @Test func theLanguageTheSessionSendsComesFromThePreferences() {
        let preferences = MeaningPreferences(defaults: Self.defaults(), keys: MemoryKeyStore())
        preferences.update { $0.language = "zh-Hans" }
        #expect(preferences.settings.language == "zh-Hans")
        #expect(preferences.effectiveTemplate(language: "zh-Hans", mode: .grounded)
            == meaningDefaultTemplate(language: "zh-Hans", mode: .grounded))
    }
}

/// The key store a test uses: memory, no Keychain, nothing to prompt for.
final class MemoryKeyStore: MeaningKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ key: String? = nil) { stored = key }

    func key() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = key
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

/// The shipped default, behind the module boundary: `AITemplates` is public and this keeps the test readable.
func meaningDefaultTemplate(language: String, mode: AIMode) -> String {
    AITemplates.defaultTemplate(language: language, mode: mode) ?? ""
}
