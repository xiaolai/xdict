import Foundation
import Observation
import XDictAI

/// **The reader's AI choices, as Settings ▸ AI keeps them** (plan-ai-meaning WI-6; ADR-0021 d.3, d.13): the source and its
/// address, the disclosure switch, the answer's language and the edited prompt, in the app's own preferences; the cloud
/// key only in the Keychain. The session reads this store at each ask, so a change applies to the next ask and never to
/// one in flight.
@MainActor
@Observable
public final class MeaningPreferences {
    public static let shared = MeaningPreferences()

    public private(set) var settings: MeaningSettings
    /// Which of the two endpoint rows the reader chose (ADR-0021 d.3 lists them apart): a local server, or a cloud one
    /// with a key. The kind is `.http` for both; the address tells them apart at ask time.
    public private(set) var httpCloud: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any MeaningKeyStore

    private enum Key {
        static let source = "meaning.source"
        static let endpoint = "meaning.endpoint"
        static let model = "meaning.model"
        static let sendEntryText = "meaning.sendEntryText"
        static let language = "meaning.language"
        static let httpCloud = "meaning.http.cloud"

        static func template(_ language: String, _ mode: AIMode) -> String {
            "meaning.template.\(language).\(mode.rawValue)"
        }
    }

    public init(defaults: UserDefaults = .standard, keys: any MeaningKeyStore = KeychainKeyStore()) {
        self.defaults = defaults
        self.keys = keys
        let language = defaults.string(forKey: Key.language) ?? "en"
        settings = MeaningSettings(
            source: defaults.string(forKey: Key.source).flatMap(AIProviderKind.init(rawValue:)),
            endpoint: defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:)),
            model: defaults.string(forKey: Key.model) ?? "",
            key: keys.key(),
            sendEntryText: defaults.bool(forKey: Key.sendEntryText),
            language: language,
            templates: Self.storedTemplates(defaults, language: language))
        httpCloud = defaults.bool(forKey: Key.httpCloud)
        settings.usesKey = settings.source == .http && httpCloud
    }

    /// **The source the reader chose**; nil turns the feature off. `cloud` picks which endpoint row is selected.
    public func choose(_ kind: AIProviderKind?, cloud: Bool = false) {
        settings.source = kind
        httpCloud = cloud
        settings.usesKey = kind == .http && cloud
        persist()
    }

    /// Any other change from the pane; persisted at once.
    public func update(_ change: (inout MeaningSettings) -> Void) {
        change(&settings)
        persist()
    }

    /// **The cloud key**: saved to the Keychain, or removed with nil. Never written to defaults.
    public func setKey(_ key: String?) throws {
        if let key {
            try keys.save(key)
        } else {
            try keys.remove()
        }
        settings.key = key
    }

    public var hasKey: Bool { settings.key != nil }

    // MARK: - The prompt (ADR-0021 d.13)

    /// The reader's edit for this language and kind, or nil for the shipped default.
    public func storedTemplate(language: String, mode: AIMode) -> String? {
        defaults.string(forKey: Key.template(language, mode))
    }

    /// The template an ask actually uses: the reader's edit, the shipped default of this language, then English's.
    public func effectiveTemplate(language: String, mode: AIMode) -> String {
        storedTemplate(language: language, mode: mode)
            ?? AITemplates.defaultTemplate(language: language, mode: mode)
            ?? AITemplates.defaultTemplate(language: "en", mode: mode) ?? ""
    }

    /// Saves an edit, or restores the default with nil. Empty text is the default too: an empty prompt could not compose.
    public func setTemplate(_ text: String?, language: String, mode: AIMode) {
        if let text, !text.isEmpty {
            defaults.set(text, forKey: Key.template(language, mode))
        } else {
            defaults.removeObject(forKey: Key.template(language, mode))
        }
        refreshTemplates()
    }

    public func resetTemplates(language: String, mode: AIMode) {
        setTemplate(nil, language: language, mode: mode)
    }

    /// Whether this language and kind carries the reader's own wording, which the pane labels *your wording, not measured*.
    public func isEdited(language: String, mode: AIMode) -> Bool {
        storedTemplate(language: language, mode: mode) != nil
    }

    // MARK: - Persistence

    private func persist() {
        set(settings.source?.rawValue, forKey: Key.source)
        set(settings.endpoint?.absoluteString, forKey: Key.endpoint)
        set(settings.model.isEmpty ? nil : settings.model, forKey: Key.model)
        defaults.set(settings.sendEntryText, forKey: Key.sendEntryText)
        defaults.set(settings.language, forKey: Key.language)
        defaults.set(httpCloud, forKey: Key.httpCloud)
        // The session's templates are this language's edits; the other language's stay stored for when it is chosen.
        refreshTemplates()
    }

    private func refreshTemplates() {
        settings.templates = Self.storedTemplates(defaults, language: settings.language)
    }

    private func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func storedTemplates(_ defaults: UserDefaults, language: String) -> [AIMode: String] {
        var templates: [AIMode: String] = [:]
        for mode in AIMode.allCases {
            if let text = defaults.string(forKey: Key.template(language, mode)) {
                templates[mode] = text
            }
        }
        return templates
    }
}
