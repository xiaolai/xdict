import Foundation
import Testing
import XDictAI
import XDictTestSupport
@testable import XDictUI

/// **What Settings ▸ AI remembers, and where** (plan-ai-meaning WI-6; ADR-0021 d.3, d.13): the source and its address
/// in the app's own preferences, the prompt edits per language and kind, and the cloud key only in the key store —
/// never in a defaults database, because a defaults file is readable by anything that can read the reader's account.
@MainActor
struct MeaningPreferencesTests {
    @Test func aFreshInstallHasNoSourceAndTheSwitchOff() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        #expect(preferences.settings.source == nil)
        #expect(preferences.settings.sendEntryText == false)
        #expect(preferences.settings.language == "en")
        #expect(preferences.settings.templates.isEmpty)
        #expect(preferences.hasKey == false)
    }

    @Test func theSourceAndItsAddressSurviveANewInstance() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let first = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        first.choose(.http, cloud: true)
        first.setEndpoint("https://api.example.com/v1")
        first.setModel("a-model")
        first.setSendEntryText(true)
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        #expect(second.settings.source == .http)
        #expect(second.httpCloud)
        #expect(second.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        #expect(second.settings.model == "a-model")
        #expect(second.settings.sendEntryText)
    }

    @Test func anEditedTemplateSurvivesAndResetRestoresTheDefault() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let first = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        let shipped = try meaningDefaultTemplate(language: "en", mode: .grounded)
        #expect(first.effectiveTemplate(language: "en", mode: .grounded) == shipped)
        #expect(first.storedTemplate(language: "en", mode: .grounded) == nil)
        first.setTemplate("Say what {term} means: {sentence} {entry}", language: "en", mode: .grounded)
        #expect(first.storedTemplate(language: "en", mode: .grounded) == "Say what {term} means: {sentence} {entry}")
        // **The edit is what an ask composes from, in the settings the session reads too** (audit finding, 2026-10-25):
        // a stored value no session ever picked up would look saved and do nothing.
        #expect(first.effectiveTemplate(language: "en", mode: .grounded)
            == "Say what {term} means: {sentence} {entry}")
        #expect(first.settings.templates[.grounded] == "Say what {term} means: {sentence} {entry}")
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        #expect(second.storedTemplate(language: "en", mode: .grounded) == "Say what {term} means: {sentence} {entry}")
        #expect(second.effectiveTemplate(language: "en", mode: .grounded)
            == "Say what {term} means: {sentence} {entry}")
        // The other kind is untouched: one template never answers another mode's ask.
        #expect(second.storedTemplate(language: "en", mode: .sentenceOnly) == nil)
        second.resetTemplates(language: "en", mode: .grounded)
        #expect(second.storedTemplate(language: "en", mode: .grounded) == nil)
        #expect(second.effectiveTemplate(language: "en", mode: .grounded) == shipped)
        #expect(second.settings.templates[.grounded] == nil)
    }

    /// **The chosen-sense kind keeps its own prompt** (plan-explain-sense WI-5; ADR-0029 d.6): three kinds, three
    /// templates, and an edit of one never changes another's question.
    @Test func theChosenSenseTemplateIsItsOwnKind() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let first = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        let shipped = try meaningDefaultTemplate(language: "en", mode: .explainSense)
        #expect(!shipped.isEmpty)
        #expect(first.effectiveTemplate(language: "en", mode: .explainSense) == shipped)
        // **Each kind starts from an edit of its own** (audit finding, 2026-10-25): with the others empty, a lookup that
        // ignored the kind could still look right.
        first.setTemplate("Grounded wording {term} {sentence} {entry}", language: "en", mode: .grounded)
        first.setTemplate("Sentence-only wording {term} {sentence}", language: "en", mode: .sentenceOnly)
        first.setTemplate("Which sense? {term} {sentence} {entry} {sense}", language: "en", mode: .explainSense)
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        #expect(second.storedTemplate(language: "en", mode: .explainSense)
            == "Which sense? {term} {sentence} {entry} {sense}")
        #expect(second.effectiveTemplate(language: "en", mode: .explainSense)
            == "Which sense? {term} {sentence} {entry} {sense}")
        #expect(second.storedTemplate(language: "en", mode: .grounded)
            == "Grounded wording {term} {sentence} {entry}")
        #expect(second.storedTemplate(language: "en", mode: .sentenceOnly)
            == "Sentence-only wording {term} {sentence}")
    }

    @Test func aTemplateEditIsKeptPerLanguage() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.setTemplate("English wording", language: "en", mode: .grounded)
        preferences.setTemplate("中文写法", language: "zh-Hans", mode: .grounded)
        #expect(preferences.storedTemplate(language: "en", mode: .grounded) == "English wording")
        #expect(preferences.storedTemplate(language: "zh-Hans", mode: .grounded) == "中文写法")
    }

    @Test func theKeyGoesToTheKeyStoreAndNeverToDefaults() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let keys = MemoryKeyStore()
        let preferences = MeaningPreferences(defaults: database, keys: keys)
        try preferences.setKey("sk-not-in-defaults")
        #expect(preferences.hasKey)
        #expect(keys.key() == "sk-not-in-defaults")
        #expect(preferences.settings.key == "sk-not-in-defaults")
        // **The write happens before the check** (audit finding, 2026-10-25): the key was never in defaults only because
        // a fresh database held nothing; persisting an ordinary change proves the key is not among what persist writes.
        preferences.setModel("a-model")
        #expect(database.string(forKey: "meaning.model") == "a-model", "the persist path did not run")
        #expect(!plistText(database.dictionaryRepresentation()).contains("sk-not-in-defaults"),
                "the key reached a defaults database")
        // A new instance reads it back from the store.
        let second = MeaningPreferences(defaults: database, keys: keys)
        #expect(second.settings.key == "sk-not-in-defaults")
        try second.setKey(nil)
        #expect(second.hasKey == false)
        #expect(second.settings.key == nil)
        #expect(keys.key() == nil)
    }

    /// **A refused save leaves the stored key and the settings as they were**: the Keychain's failure is the caller's to
    /// show, and a half-applied key would travel to the server without the reader knowing.
    @Test func aRefusedKeySaveChangesNothing() throws {
        let keys = MemoryKeyStore()
        try keys.save("sk-old")
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: keys)
        keys.failure = MeaningKeyError(status: -25308)
        #expect(throws: MeaningKeyError.self) { try preferences.setKey("sk-new") }
        #expect(keys.key() == "sk-old")
        #expect(preferences.settings.key == "sk-old")
        keys.failure = MeaningKeyError(status: -25308)
        #expect(throws: MeaningKeyError.self) { try preferences.setKey(nil) }
        #expect(keys.key() == "sk-old")
    }

    /// **A cloud key is never sent to a server chosen as local** (audit finding, 2026-10-20).
    @Test func theKeyBelongsToTheCloudRowOnly() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
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
    @Test func theChosenServiceSurvivesAndFillsItsAddress() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let first = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        first.choose(.http, cloud: true)
        first.chooseProfile("deepseek")
        #expect(first.settings.profile == "deepseek")
        #expect(first.settings.endpoint?.absoluteString == "https://api.deepseek.com")
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        #expect(second.settings.profile == "deepseek")
        #expect(second.settings.endpoint?.absoluteString == "https://api.deepseek.com")
        second.setEndpoint("https://reader.example.com/v1")
        second.chooseProfile("custom")
        #expect(second.settings.profile == "custom")
        #expect(second.settings.endpoint?.absoluteString == "https://reader.example.com/v1",
                "choosing Custom must not erase the address in the field")
    }

    /// **A service from the other row is hidden, never forgotten** (2026-10-25): the local row uses Custom while a cloud
    /// service is stored, and switching back restores it.
    @Test func aServiceFromTheOtherRowIsHiddenNotForgotten() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("deepseek")
        preferences.choose(.http, cloud: false)
        #expect(MeaningProviders.profile(preferences.settings).id == "custom")
        preferences.choose(.http, cloud: true)
        #expect(MeaningProviders.profile(preferences.settings).id == "deepseek")
    }

    /// **An install that predates the choice is inferred from its address**, and the address itself is untouched.
    @Test func anAddressFromBeforeTheChoiceNamesItsService() throws {
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://openrouter.ai/api/v1/")) == "openrouter")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://api.deepseek.com/")) == "deepseek")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://api.example.com/v1")) == "custom")
        #expect(MeaningProfiles.matching(endpoint: nil) == "custom")
        let fixture = try TestDefaults()
        let defaults = fixture.database
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
        settings.key = "sk-shared"
        var config = MeaningProviders.httpConfiguration(settings, endpoint: openai)
        #expect(config.auth == .bearer)
        #expect(config.tokenField == .completionFirst)
        // **The one key reaches a cloud configuration and never a local one** (audit finding, 2026-10-25): the test
        // asserts the built configuration, not only the helper that decides.
        #expect(config.apiKey == "sk-shared")
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
        #expect(local.apiKey == nil, "the shared key must not travel to a server chosen as local")
        #expect(MeaningProviders.profile(settings).id == "ollama")
        settings.usesKey = true
        #expect(MeaningProviders.profile(settings).id == "custom", "a local profile never answers for the cloud row")
    }

    /// **Each row keeps its own service, address and model** (audit finding, 2026-10-25): an edited address survives
    /// Off and a switch back, the other row never inherits it, and both survive a relaunch — so the one key is never
    /// pointed at the server chosen for the other row.
    @Test func eachRowKeepsItsOwnServiceAndAddress() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let preferences = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("openai")
        preferences.setEndpoint("https://proxy.example.com/v1")   // the reader's own base for this service
        preferences.choose(nil)                                    // Off
        #expect(preferences.settings.endpoint?.absoluteString == "https://proxy.example.com/v1",
                "Off must not lose the selected row's address")
        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.endpoint?.absoluteString == "https://proxy.example.com/v1",
                "the cloud row comes back as it was left, not as its service's default")
        #expect(preferences.settings.profile == "openai")

        preferences.choose(.http, cloud: false)                    // a local row never configured
        #expect(preferences.settings.endpoint == nil)
        #expect(preferences.settings.profile == MeaningProfiles.custom)
        preferences.chooseProfile("ollama")

        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.endpoint?.absoluteString == "https://proxy.example.com/v1")

        // Both rows survive a relaunch, each with its own values.
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        second.choose(.http, cloud: false)
        #expect(second.settings.profile == "ollama")
        #expect(second.settings.endpoint?.absoluteString == "http://127.0.0.1:11434/v1")
        second.choose(.http, cloud: true)
        #expect(second.settings.endpoint?.absoluteString == "https://proxy.example.com/v1")
    }

    /// **An Off cloud install from before the rows keeps its server on the cloud row** (verification finding,
    /// 2026-10-25): the row comes from the address, not from the Off state's false row flag.
    @Test func aLegacyCloudAddressIsMigratedToTheCloudRow() throws {
        let fixture = try TestDefaults()
        let defaults = fixture.database
        defaults.set("https://api.deepseek.com", forKey: "meaning.endpoint")
        defaults.set(false, forKey: "meaning.http.cloud")   // the reader quit while Off
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: false)
        #expect(preferences.settings.endpoint == nil, "the local row must not inherit a cloud address")
        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.deepseek.com")
        #expect(preferences.settings.profile == "deepseek")
    }

    /// **A legacy Custom loopback endpoint is a local server** (verification finding, 2026-10-25): the row decides where
    /// the one key may travel, and a loopback server must never be filed as the cloud row's.
    @Test func aLegacyCustomLoopbackAddressIsMigratedToTheLocalRow() throws {
        let fixture = try TestDefaults()
        let defaults = fixture.database
        defaults.set("http://127.0.0.1:11434/v1", forKey: "meaning.endpoint")
        defaults.set("custom", forKey: "meaning.http.profile")
        defaults.set(true, forKey: "meaning.http.cloud")   // the reader was on the cloud row when they quit
        let preferences = MeaningPreferences(defaults: defaults, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.endpoint == nil, "a loopback server is not the cloud row's")
        preferences.choose(.http, cloud: false)
        #expect(preferences.settings.endpoint?.absoluteString == "http://127.0.0.1:11434/v1")
        #expect(preferences.settings.profile == MeaningProfiles.custom)
    }

    /// **Returning to a row restores its own service's address** (audit finding, 2026-10-25): the cloud key must not be
    /// left pointed at the server the reader typed for the local row.
    @Test func returningToTheCloudRowRestoresItsServicesAddress() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.choose(.http, cloud: true)
        preferences.chooseProfile("openai")
        preferences.choose(.http, cloud: false)
        preferences.setEndpoint("http://127.0.0.1:11434/v1")
        preferences.choose(.http, cloud: true)
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.openai.com/v1")
        #expect(preferences.settings.usesKey)
    }

    /// **A pasted address keeps its server** (2026-10-25): whitespace around it is not part of it, text that is not a
    /// URL yet cannot erase the stored address, and an emptied field is the reader asking for none.
    @Test func anAddressIsTrimmedAndAStrayWhitespaceCannotEraseIt() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let preferences = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        preferences.setEndpoint("  https://api.example.com/v1\n")
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        #expect(MeaningPreferences(defaults: database, keys: MemoryKeyStore())
            .settings.endpoint?.absoluteString == "https://api.example.com/v1", "the address was not persisted")
        // A field mid-edit, or text that is not a URL, leaves the last good address alone.
        preferences.setEndpoint("https://%zz")
        #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1")
        // Emptying the field is the reader asking for no address.
        preferences.setEndpoint("  ")
        #expect(preferences.settings.endpoint == nil)
    }

    /// **Only an absolute http or https address with a host is stored** (audit finding, 2026-10-25): `URL(string:)`
    /// alone took a relative name and a `file:` URL, either of which would replace a working server with one no
    /// provider can reach.
    @Test func anAddressMustBeAbsoluteHttpOrHttpsWithAHost() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.setEndpoint("https://api.example.com/v1")
        for text in ["api.example.com", "file:///tmp/x", "http://", "ftp://example.com", "  localhost:11434  "] {
            preferences.setEndpoint(text)
            #expect(preferences.settings.endpoint?.absoluteString == "https://api.example.com/v1",
                    "\(text) replaced a working address")
        }
        preferences.setEndpoint("http://127.0.0.1:11434/v1")
        #expect(preferences.settings.endpoint?.absoluteString == "http://127.0.0.1:11434/v1",
                "a local server answers over plain http")
        preferences.setEndpoint("https://secure.example.com")
        #expect(preferences.settings.endpoint?.absoluteString == "https://secure.example.com")
    }

    /// **The session's lookup and the preferences agree about the language** (audit finding, 2026-10-25): the session
    /// composes from `settings.template(for:)`, so a language change must be visible there, not only in the pane's
    /// editor.
    @Test func theLanguageTheSessionSendsComesFromThePreferences() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        preferences.setLanguage("zh-Hans")
        #expect(preferences.settings.language == "zh-Hans")
        let shipped = try meaningDefaultTemplate(language: "zh-Hans", mode: .grounded)
        #expect(preferences.effectiveTemplate(language: "zh-Hans", mode: .grounded) == shipped)
        #expect(preferences.settings.template(for: .grounded) == shipped, "the session would compose in another language")
        // The answer language follows the setting into a new instance.
        let second = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        second.setLanguage("zh-Hans")
        #expect(second.settings.template(for: .grounded) == shipped)
    }
}

/// Every string, data and nested value in a defaults database, flattened: a key stored as `Data` or inside a nested
/// dictionary must be found too (audit finding, 2026-10-25: `String(describing:)` saw neither).
private func plistText(_ value: Any) -> String {
    switch value {
    case let string as String: return string
    case let data as Data: return String(decoding: data, as: UTF8.self)
    case let dictionary as [String: Any]:
        return dictionary.map { $0.key + "\n" + plistText($0.value) }.joined(separator: "\n")
    case let array as [Any]:
        return array.map(plistText).joined(separator: "\n")
    default:
        return String(describing: value)
    }
}

/// The key store a test uses: memory, no Keychain, nothing to prompt for.
final class MemoryKeyStore: MeaningKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    /// The failure the next save or remove throws, if any (audit finding, 2026-10-25: the store never failed, so the
    /// refused-save path was never exercised).
    private var _failure: MeaningKeyError?

    var failure: MeaningKeyError? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); defer { lock.unlock() }; _failure = newValue }
    }

    init(_ key: String? = nil) { stored = key }

    func key() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let _failure { throw _failure }
        stored = key
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        if let _failure { throw _failure }
        stored = nil
    }
}

/// The shipped default, behind the module boundary: `AITemplates` is public and this keeps the test readable. `#require`
/// so a missing shipped template fails here, named, instead of comparing against an empty string that hides it.
func meaningDefaultTemplate(language: String, mode: AIMode) throws -> String {
    try #require(AITemplates.effective(language: language, mode: mode, stored: nil),
                 "no shipped template for \(language)/\(mode.rawValue)")
}

/// **The translation's target language** (contract 6; plan-context-tools WI-8): its own choice, defaulting to the
/// explanation's language, and remembered across instances like every other Settings ▸ AI value.
@MainActor
struct TranslationLanguageTests {
    @Test func aFreshInstallTranslatesIntoTheExplanationLanguage() throws {
        let fixture = try TestDefaults()
        let preferences = MeaningPreferences(defaults: fixture.database, keys: MemoryKeyStore())
        #expect(preferences.settings.translationLanguage == preferences.settings.language)
    }

    @Test func theChosenQuestionIsRememberedAndDefaultsToMeaning() throws {
        let fixture = try TestDefaults()
        #expect(MeaningAskMode.stored(in: fixture.database) == .meaning)
        MeaningAskMode.grammar.store(in: fixture.database)
        #expect(MeaningAskMode.stored(in: fixture.database) == .grammar)
        MeaningAskMode.translation.store(in: fixture.database)
        #expect(MeaningAskMode.stored(in: fixture.database) == .translation)
    }

    @Test func theTargetLanguageSurvivesANewInstanceAndKeepsTheExplanationsLanguage() throws {
        let fixture = try TestDefaults()
        let database = fixture.database
        let first = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        first.setTranslationLanguage("zh-Hans")
        let second = MeaningPreferences(defaults: database, keys: MemoryKeyStore())
        #expect(second.settings.translationLanguage == "zh-Hans")
        // The explanation's own language is a separate choice and did not move with it.
        #expect(second.settings.language == "en")
    }
}
