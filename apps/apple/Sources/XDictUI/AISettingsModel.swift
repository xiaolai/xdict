import Foundation
import Observation
import XDictAI

/// **Settings ▸ AI's state, apart from its rows** (plan-ai-meaning WI-6): the live source check, the cloud key's four
/// states, the prompt draft and its edit, and the Codex sign-in's own lines. The view draws it; nothing here sends the
/// reader's text except a key test, which asks the endpoint one short question.
@MainActor
@Observable
public final class AISettingsModel {
    /// The cloud key's four states (ADR-0021 d.3): no key, one stored, a test running, and the last test's typed failure.
    public enum KeyState: Equatable, Sendable {
        case absent
        case stored
        case testing
        case failed(AIProviderError)
    }

    public let preferences: MeaningPreferences
    public private(set) var status: MeaningSourceStatus = .checking
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var keyGeneration = 0
    public var keyState: KeyState = .absent
    public var draftKey = ""
    public private(set) var keyFailure: LocalizedStringResource?
    public var promptKind: AIMode = .grounded
    public var draft = ""
    /// The Codex login's own output, verbatim: the web address and code the reader needs. Data, never translated.
    public private(set) var loginLines: [String] = []
    public private(set) var signingIn = false

    public init(preferences: MeaningPreferences) {
        self.preferences = preferences
        keyState = preferences.hasKey ? .stored : .absent
        draft = preferences.effectiveTemplate(language: preferences.settings.language, mode: promptKind)
    }

    public var language: String { preferences.settings.language }

    /// **The build's Apple source against this Mac, when the Mac is older** (ADR-0026, owner's rule of 2026-10-21): the
    /// Apple row stays visible on every supported system and says which macOS the source needs and which this Mac runs,
    /// in the reader's language. Nil when the system is new enough.
    public var appleSystemNotice: LocalizedStringResource? {
        if case .system(let required, let running) = AppleOnDeviceProvider.availability() {
            return MeaningSentences.availability(.system(required: required, running: running))
        }
        return nil
    }

    // MARK: - The source

    public func select(_ kind: AIProviderKind?, cloud: Bool = false) {
        preferences.choose(kind, cloud: cloud)
        keyFailure = nil
        if kind == .http, cloud, preferences.hasKey { keyState = .stored }
    }

    public func refreshStatus() async {
        // **A superseded check cannot overwrite the current source's status** (audit finding, 2026-10-20).
        statusGeneration += 1
        let mine = statusGeneration
        status = .checking
        let found = await MeaningProviders.status(preferences.settings)
        guard mine == statusGeneration else { return }
        status = found
    }

    // MARK: - The key

    public func saveKey() {
        do {
            try preferences.setKey(draftKey)
            // A test still running was about the key this replaces: its result must not speak for the new one.
            keyGeneration += 1
            draftKey = ""
            keyFailure = nil
            keyState = .stored
        } catch {
            let status = (error as? MeaningKeyError)?.status ?? -1
            keyFailure = LocalizedStringResource("The Keychain refused to save the key (status \(status)).")
        }
    }

    /// **Replace**: the field comes back for a new key; a test still running no longer speaks for it.
    public func replaceKey() {
        keyGeneration += 1
        keyState = .absent
        draftKey = ""
    }

    public func removeKey() {
        do {
            try preferences.setKey(nil)
            // The key a running test is proving is gone; its verdict must not bring `.stored` back.
            keyGeneration += 1
            keyState = .absent
            keyFailure = nil
        } catch {
            // A refused delete used to be swallowed: Remove cleared the field and the key returned after relaunch.
            let status = (error as? MeaningKeyError)?.status ?? -1
            keyFailure = LocalizedStringResource("The Keychain refused to remove the key (status \(status)).")
        }
    }

    /// **Test** asks the endpoint one short question (`HTTPProvider.probe`), which is the only way to know the key works.
    public func testKey() async {
        keyGeneration += 1
        let mine = keyGeneration
        keyState = .testing
        let settings = preferences.settings
        guard let endpoint = settings.endpoint else {
            keyState = .failed(.unreachable)
            return
        }
        do {
            let provider = try HTTPProvider(configuration: .init(endpoint: endpoint, model: settings.model,
                                                                 apiKey: MeaningProviders.apiKey(settings)))
            _ = try await provider.probe()
            guard mine == keyGeneration else { return }
            // **A result for a configuration the reader has since changed proves nothing** (audit finding, 2026-10-20).
            guard Self.stillCurrent(settings, preferences.settings) else {
                restoreKeyState()
                return
            }
            keyState = .stored
        } catch {
            guard mine == keyGeneration else { return }
            // The failure belongs to the address, model and effective key it was sent with — source selection included,
            // which is what turns `usesKey` on or off (verification finding, 2026-10-20).
            guard Self.stillCurrent(settings, preferences.settings) else {
                restoreKeyState()
                return
            }
            keyState = .failed(error)
        }
    }

    /// What a probe was sent with, as one question: the address, the model, and the key the source actually uses (nil for
    /// a local endpoint, whatever the Keychain holds). A change in any of them makes the probe's verdict stale.
    private static func stillCurrent(_ captured: MeaningSettings, _ now: MeaningSettings) -> Bool {
        now.endpoint == captured.endpoint && now.model == captured.model
            && MeaningProviders.apiKey(now) == MeaningProviders.apiKey(captured)
    }

    /// The stored key outlives a stale probe; its four-state row shows what is still true.
    private func restoreKeyState() {
        keyState = preferences.hasKey ? .stored : .absent
    }

    // MARK: - The command-line sources

    public func signIn() async {
        signingIn = true
        loginLines = []
        defer { signingIn = false }
        do {
            guard let codex = try MeaningProviders.make(preferences.settings) as? CodexCLIProvider else { return }
            _ = try await codex.login { line in
                Task { @MainActor in self.loginLines.append(line) }
            }
            await refreshStatus()
        } catch {
            status = .failed(error)
        }
    }

    // MARK: - The prompt

    public func loadDraft() {
        draft = preferences.effectiveTemplate(language: preferences.settings.language, mode: promptKind)
    }

    /// **An edit is saved as it is typed**, except when it is the shipped default: editing back to the default is a reset,
    /// not a second copy of the same text labelled *your wording*.
    public func draftChanged() {
        let language = preferences.settings.language
        if draft == preferences.storedTemplate(language: language, mode: promptKind) { return }
        let shipped = AITemplates.defaultTemplate(language: language, mode: promptKind)
            ?? AITemplates.defaultTemplate(language: "en", mode: promptKind)
        if draft.isEmpty || draft == shipped {
            preferences.setTemplate(nil, language: language, mode: promptKind)
            // An empty editor was restoring the default behind the reader's back while showing nothing: show it.
            if draft.isEmpty { loadDraft() }
        } else {
            preferences.setTemplate(draft, language: language, mode: promptKind)
        }
    }

    public func resetDraft() {
        preferences.resetTemplates(language: preferences.settings.language, mode: promptKind)
        loadDraft()
    }
}
