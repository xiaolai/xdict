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
    /// **Which endpoint row owns `settings` right now**: it changes only when the HTTP source is chosen, so a detour
    /// through Off or a CLI never files one row's values under the other.
    @ObservationIgnored private var selectedRow: Bool

    private enum Key {
        static let source = "meaning.source"
        static let endpoint = "meaning.endpoint"
        static let profile = "meaning.http.profile"
        static let model = "meaning.model"
        static let sendEntryText = "meaning.sendEntryText"
        static let language = "meaning.language"
        static let translationLanguage = "meaning.translationLanguage"
        static let previewBeforeSending = "meaning.previewBeforeSending"
        static let askOnOpen = "meaning.askOnOpen"
        static let httpCloud = "meaning.http.cloud"

        static func template(_ language: String, _ mode: AIMode) -> String {
            "meaning.template.\(language).\(mode.rawValue)"
        }

        static func row(_ cloud: Bool) -> String { cloud ? "cloud" : "local" }
        static func rowEndpoint(_ row: String) -> String { "meaning.row.\(row).endpoint" }
        static func rowProfile(_ row: String) -> String { "meaning.row.\(row).profile" }
        static func rowModel(_ row: String) -> String { "meaning.row.\(row).model" }
    }

    /// **One endpoint row's own state** (audit finding, 2026-10-25): the local and cloud rows each keep their service,
    /// address and model, so switching rows neither loses the reader's edited address nor leaves the one key pointed at
    /// the other row's server. `initialized` is false for a row an install from before rows has never had.
    private struct Row {
        var endpoint: URL?
        var profile: String
        var model: String
        var initialized: Bool
    }

    public init(defaults: UserDefaults = .standard, keys: any MeaningKeyStore = KeychainKeyStore()) {
        self.defaults = defaults
        self.keys = keys
        let language = defaults.string(forKey: Key.language) ?? "en"
        // **An install from before the rows is filed where its server belongs**, before anything reads a row.
        Self.migrateLegacyRowIfNeeded(defaults: defaults)
        let cloud = defaults.bool(forKey: Key.httpCloud)
        httpCloud = cloud
        selectedRow = cloud
        // **The selected row's own state, or the single endpoint an install from before rows stored**: the reader's
        // address is never carried between rows, and its service is inferred only when nothing was ever chosen.
        // **Migration has already filed every legacy value in a row**: the selected row is the only source from here,
        // so a row never configured is genuinely empty and never borrows the other row's address.
        let row = Self.row(cloud: cloud, defaults: defaults)
        let endpoint = row.initialized ? row.endpoint : nil
        let profile = row.initialized ? row.profile : MeaningProfiles.custom
        let model = row.initialized ? row.model : ""
        settings = MeaningSettings(
            source: defaults.string(forKey: Key.source).flatMap(AIProviderKind.init(rawValue:)),
            endpoint: endpoint,
            profile: profile,
            model: model,
            key: keys.key(),
            sendEntryText: defaults.bool(forKey: Key.sendEntryText),
            language: language,
            translationLanguage: defaults.string(forKey: Key.translationLanguage) ?? language,
            previewBeforeSending: defaults.bool(forKey: Key.previewBeforeSending),
            askOnOpen: defaults.object(forKey: Key.askOnOpen) as? Bool ?? true,
            templates: Self.storedTemplates(defaults, language: language))
        settings.usesKey = settings.source == .http && httpCloud
    }

    /// **One endpoint from before the two rows belongs to the row its service (or its address) belongs to** — not to
    /// whichever row the reader was on when they quit: an Off state stores the row flag as false, and filing a cloud
    /// server under the local row would leave the pane offering it there (verification finding, 2026-10-25).
    private static func migrateLegacyRowIfNeeded(defaults: UserDefaults) {
        guard defaults.string(forKey: Key.rowProfile(Key.row(true))) == nil,
              defaults.string(forKey: Key.rowProfile(Key.row(false))) == nil else { return }
        let endpoint = defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:))
        let profile = defaults.string(forKey: Key.profile)
        let model = defaults.string(forKey: Key.model)
        guard endpoint != nil || profile != nil || model != nil else { return }
        let cloud: Bool
        if let known = profile.flatMap(AIProviderProfile.profile(id:)), known.id != MeaningProfiles.custom {
            cloud = !MeaningProfiles.isLocal(known)
        } else if let host = endpoint?.host {
            cloud = !MeaningProfiles.isLocal(host: host)
        } else {
            cloud = defaults.bool(forKey: Key.httpCloud)
        }
        let name = Key.row(cloud)
        if let endpoint { defaults.set(endpoint.absoluteString, forKey: Key.rowEndpoint(name)) }
        if let profile { defaults.set(profile, forKey: Key.rowProfile(name)) } else {
            defaults.set(MeaningProfiles.matching(endpoint: endpoint), forKey: Key.rowProfile(name))
        }
        if let model { defaults.set(model, forKey: Key.rowModel(name)) }
    }

    private static func row(cloud: Bool, defaults: UserDefaults) -> Row {
        let name = Key.row(cloud)
        guard let profile = defaults.string(forKey: Key.rowProfile(name)) else {
            return Row(endpoint: nil, profile: MeaningProfiles.custom, model: "", initialized: false)
        }
        return Row(endpoint: defaults.string(forKey: Key.rowEndpoint(name)).flatMap(URL.init(string:)),
                   profile: profile,
                   model: defaults.string(forKey: Key.rowModel(name)) ?? "",
                   initialized: true)
    }

    /// The selected row's current values, written where a switch back will find them.
    private func storeSelectedRow() {
        let name = Key.row(selectedRow)
        set(settings.endpoint?.absoluteString, forKey: Key.rowEndpoint(name))
        defaults.set(settings.profile, forKey: Key.rowProfile(name))
        set(settings.model.isEmpty ? nil : settings.model, forKey: Key.rowModel(name))
    }

    /// The row being selected, as it was left; a row never configured is Custom with no address.
    private func loadRow(cloud: Bool) {
        let row = Self.row(cloud: cloud, defaults: defaults)
        settings.profile = row.initialized ? row.profile : MeaningProfiles.custom
        settings.endpoint = row.initialized ? row.endpoint : nil
        settings.model = row.initialized ? row.model : ""
    }

    /// **The source the reader chose**; nil turns the feature off. `cloud` picks which endpoint row is selected.
    public func choose(_ kind: AIProviderKind?, cloud: Bool = false) {
        // **The row being left keeps its own service, address and model** (audit finding, 2026-10-25); the row being
        // selected comes back as it was left, so a reader's edited address survives Off, and the cloud key is never
        // pointed at the server typed for the local row.
        storeSelectedRow()
        settings.source = kind
        httpCloud = cloud
        settings.usesKey = kind == .http && cloud
        if kind == .http {
            selectedRow = cloud
            loadRow(cloud: cloud)
        }
        persist()
    }

    /// **The ordinary fields have named doors** (audit finding, 2026-10-25): a public closure let any caller write the
    /// endpoint, the profile or the key past `setEndpoint`'s validation and `chooseProfile`'s address, which is how a
    /// stray edit could point the one key at a server the reader did not choose.
    public func setModel(_ model: String) {
        change { $0.model = model }
    }

    /// The answer's language: the templates the session carries are that language's, so they are refreshed with it.
    public func setLanguage(_ language: String) {
        change { $0.language = language }
    }

    /// The one switch that lets the entry's text leave XDict (ADR-0021 d.9).
    public func setSendEntryText(_ on: Bool) {
        change { $0.sendEntryText = on }
    }

    /// **The language a translation is written into** (contract 6; plan-context-tools WI-8): its own choice, so a
    /// reader may read meanings in one language and want sentences in another.
    public func setTranslationLanguage(_ language: String) {
        change { $0.translationLanguage = language }
    }

    /// **Show the request before the first question of a sentence leaves** (owner, 2026-10-26): a reader's own gate on
    /// the sentence leaving, off by default.
    public func setPreviewBeforeSending(_ on: Bool) {
        change { $0.previewBeforeSending = on }
    }

    /// **Ask when the answer pane opens** (owner, 2026-10-26): on by default; off, a capture brings the pane up and the
    /// reader chooses the question.
    public func setAskOnOpen(_ on: Bool) {
        change { $0.askOnOpen = on }
    }

    /// A change this class makes itself, persisted at once.
    private func change(_ edit: (inout MeaningSettings) -> Void) {
        edit(&settings)
        persist()
    }

    /// **The service the endpoint is** (2026-10-25): a known one fills in its address, Custom keeps the reader's. The
    /// choice is remembered even while the other row is selected, so switching back restores the service.
    public func chooseProfile(_ id: String) {
        let profile = AIProviderProfile.profile(id: id) ?? .custom
        change {
            $0.profile = profile.id
            if let base = profile.baseURL { $0.endpoint = base }
        }
    }

    /// **An address the reader typed or pasted** (2026-10-25): the space or newline around a pasted URL is not part of
    /// it, and text that is not yet an address leaves the last good one stored — a stray space must never erase the
    /// server the reader configured, and a relative string must never replace a working address with something no
    /// provider can reach (audit finding, 2026-10-25: `URL(string:)` alone accepted `api.example.com` and `file:`). An
    /// empty field is the reader asking for no address.
    public func setEndpoint(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            change { $0.endpoint = nil }
            return
        }
        guard let url = Self.address(trimmed) else { return }
        change { $0.endpoint = url }
    }

    /// **What an address must be to be stored**: absolute, http or https, with a host. A local server may be plain
    /// http; the provider refuses a key over anything but https.
    static func address(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
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
    /// The rule lives in `AITemplates.effective`, so the pane, the session and the editor cannot disagree about it.
    public func effectiveTemplate(language: String, mode: AIMode) -> String {
        AITemplates.effective(language: language, mode: mode, stored: storedTemplate(language: language, mode: mode))
            ?? ""
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
        set(settings.profile, forKey: Key.profile)
        set(settings.model.isEmpty ? nil : settings.model, forKey: Key.model)
        // The selected row's own copy, beside the single legacy records older builds read.
        storeSelectedRow()
        defaults.set(settings.sendEntryText, forKey: Key.sendEntryText)
        defaults.set(settings.language, forKey: Key.language)
        defaults.set(settings.translationLanguage, forKey: Key.translationLanguage)
        defaults.set(settings.previewBeforeSending, forKey: Key.previewBeforeSending)
        defaults.set(settings.askOnOpen, forKey: Key.askOnOpen)
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
