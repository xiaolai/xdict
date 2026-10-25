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

    /// **The service's model list in the pane** (2026-10-25): not asked for yet, being fetched, the list, or why not.
    public enum ModelsState: Equatable, Sendable {
        case idle
        case loading
        case loaded([AIModel])
        case failed(ModelCatalogError)
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
    /// The service's model list, fetched only when the reader asks (`loadModels`).
    public private(set) var models: ModelsState = .idle
    @ObservationIgnored private var modelsGeneration = 0
    /// The address, service and key the list belongs to; another configuration shows no list rather than a stale one.
    @ObservationIgnored private var modelsIdentity: ListIdentity?
    /// The pane's two long buttons own their work here, so leaving the pane ends it (audit finding, 2026-10-25).
    @ObservationIgnored private var modelsTask: Task<Void, Never>?
    @ObservationIgnored private var keyTestTask: Task<Void, Never>?

    /// The Codex login's own output, verbatim: the web address and code the reader needs. Data, never translated.
    public private(set) var loginLines: [String] = []
    public private(set) var signingIn = false
    /// What the login's lines say, structured (UI33): the address to open and the code to enter.
    public var login: CodexLogin { CodexLogin.parse(loginLines) }

    /// **How a sign-in runs**: the Codex login by default; a test hands in its own. Lines arrive on the main actor.
    public typealias Login = @MainActor (_ onLine: @escaping @MainActor (String) -> Void) async throws -> Void
    /// **How a model list is fetched**: sayso's catalogue by default; a test hands in its own.
    public typealias FetchModels = @Sendable (ModelCatalog.Request) async -> Result<[AIModel], ModelCatalogError>
    @ObservationIgnored private let runLogin: Login?
    @ObservationIgnored private let fetchModels: FetchModels
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var signInGeneration = 0

    public init(preferences: MeaningPreferences, login: Login? = nil, fetchModels: FetchModels? = nil) {
        self.preferences = preferences
        runLogin = login
        // The live fetch is internal: a public initializer's default value cannot name it, so nil resolves here.
        self.fetchModels = fetchModels ?? liveModelFetch
        keyState = preferences.hasKey ? .stored : .absent
        draft = preferences.effectiveTemplate(language: preferences.settings.language, mode: promptKind)
    }

    /// **The source, as the pane's one single-choice control selects it** (UI32).
    public var choice: AISourceChoice {
        get { AISourceChoice.of(kind: preferences.settings.source, cloud: preferences.httpCloud) }
        set { select(newValue.kind, cloud: newValue.cloud) }
    }

    /// **Whether any kind's prompt in the answer language is the reader's wording** (UI18; ADR-0021): said on the
    /// advanced disclosure's label, so a closed disclosure never hides an edit.
    public var hasEditedPrompt: Bool {
        AIMode.allCases.contains { preferences.isEdited(language: language, mode: $0) }
    }

    public var language: String { preferences.settings.language }

    /// The service the endpoint is: the stored profile when it belongs to the chosen row, Custom otherwise.
    public var profile: AIProviderProfile { MeaningProviders.profile(preferences.settings) }

    /// **The list this configuration may show**: a list fetched for another address, service or key is not shown, even
    /// while it is still held — the menu never offers another service's models.
    public var modelsShown: ModelsState {
        modelsIdentity == listIdentity ? models : .idle
    }

    /// **What the model menu offers**: the fetched list, or the service's own few names before a fetch. A list the
    /// service says is empty is authoritative: the hints must not speak over it.
    public var modelChoices: [String] {
        if case .loaded(let list) = modelsShown { return list.map(\.id) }
        return profile.hints
    }

    /// **What makes a list a configuration's own**, as one value: the address, the service and the key it was fetched
    /// with. Exact equality, so display and completion cannot disagree about which configuration a list belongs to.
    private struct ListIdentity: Equatable {
        let endpoint: String
        let profile: String
        let key: String?
    }

    private var listIdentity: ListIdentity {
        let settings = preferences.settings
        return ListIdentity(endpoint: settings.endpoint?.absoluteString ?? "",
                            profile: MeaningProviders.profile(settings).id,
                            key: MeaningProviders.apiKey(settings))
    }

    /// **The build's Apple source against this Mac, when the Mac is older** (ADR-0026, owner's rule of 2026-10-21): the
    /// Apple row stays visible on every supported system and says which macOS the source needs and which this Mac runs,
    /// in the reader's language. Nil when the system is new enough.
    public var appleSystemNotice: LocalizedStringResource? {
        if case .system(let required, let running) = AppleProvider.availability() {
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

    // MARK: - The model list (2026-10-25)

    /// **Load the service's own model list**, on the reader's ask and never per keystroke. Every press asks the service:
    /// the list changes when a model is pulled or retired, and a cached answer would make the button look broken.
    public func loadModels() async {
        // **A task cancelled before it ran does nothing**: a cancelled button press must not start a request, and its
        // `modelsGeneration` bump would otherwise let that request speak for the pane after it is gone.
        guard !Task.isCancelled else { return }
        guard preferences.settings.source == .http, let endpoint = preferences.settings.endpoint else {
            // **A pane with no endpoint has no load**: the generation advances so an older request cannot land here.
            modelsGeneration += 1
            models = .idle
            modelsIdentity = nil
            return
        }
        let settings = preferences.settings
        let profile = MeaningProviders.profile(settings)
        let request = ModelCatalog.Request(profile: profile, baseURL: endpoint,
                                           apiKey: MeaningProviders.apiKey(settings))
        modelsGeneration += 1
        let mine = modelsGeneration
        let identity = listIdentity
        modelsIdentity = identity
        models = .loading
        let result = await fetchModels(request)
        // **A list for an address, key or service the reader has since changed proves nothing**: only this load may
        // speak for the current pane.
        guard mine == modelsGeneration, identity == listIdentity else {
            // **A load whose configuration is gone leaves nothing behind**: when no newer load owns the pane, the state
            // returns to idle, so coming back to this configuration does not show a request that no longer exists.
            if mine == modelsGeneration {
                models = .idle
                modelsIdentity = nil
            }
            return
        }
        switch result {
        case .success(let list): models = .loaded(list)
        case .failure(let error): models = .failed(error)
        }
    }

    /// **Load Models' owner**: one load at a time, started by the view and cancellable with it.
    public func startModelLoad() {
        modelsTask?.cancel()
        modelsTask = Task { [weak self] in await self?.loadModels() }
    }

    /// **A load does not outlive the pane that asked for it**: its request is cancelled and its answer dropped.
    public func discardModelLoad() {
        modelsTask?.cancel()
        modelsTask = nil
        modelsGeneration += 1
        models = .idle
        modelsIdentity = nil
    }

    /// **Nothing the pane started outlives it**: the sign-in, a model load and a key test end together.
    public func cancelPaneWork() {
        cancelSignIn()
        discardModelLoad()
        keyTestTask?.cancel()
        keyTestTask = nil
        restoreKeyState()
    }

    /// A model picked from the list is the reader's choice, stored exactly as typing it would.
    public func chooseModel(_ id: String) {
        preferences.update { $0.model = id }
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

    /// **Test**'s owner: one probe at a time, started by the view and cancellable with it.
    public func startKeyTest() {
        keyTestTask?.cancel()
        keyTestTask = Task { [weak self] in await self?.testKey() }
    }

    /// **Test** asks the endpoint one short question (`HTTPProvider.probe`), which is the only way to know the key works.
    public func testKey() async {
        guard !Task.isCancelled else { return }
        keyGeneration += 1
        let mine = keyGeneration
        keyState = .testing
        let settings = preferences.settings
        guard let endpoint = settings.endpoint else {
            keyState = .failed(.unreachable)
            return
        }
        do {
            let provider = try HTTPProvider(configuration: MeaningProviders.httpConfiguration(settings, endpoint: endpoint))
            _ = try await provider.probe()
            guard mine == keyGeneration else { return }
            // **A cancelled probe is the pane's choice, not the key's verdict**, and a result for a configuration the
            // reader has since changed proves nothing (audit findings of 2026-10-20 and 2026-10-25).
            guard !Task.isCancelled else {
                restoreKeyState()
                return
            }
            guard Self.stillCurrent(settings, preferences.settings) else {
                restoreKeyState()
                return
            }
            keyState = .stored
        } catch {
            guard mine == keyGeneration else { return }
            // The probe's failures are typed `AIProviderError` already: a raw `CancellationError` cannot reach here.
            guard !Task.isCancelled, error != .cancelled else {
                restoreKeyState()
                return
            }
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
        now.endpoint == captured.endpoint && now.model == captured.model && now.profile == captured.profile
            && MeaningProviders.apiKey(now) == MeaningProviders.apiKey(captured)
    }

    /// The stored key outlives a stale probe; its four-state row shows what is still true.
    private func restoreKeyState() {
        keyState = preferences.hasKey ? .stored : .absent
    }

    // MARK: - The command-line sources

    /// **Sign In with Codex…** (UI33): one login at a time, owned here so the pane can cancel it. Cancelling ends the
    /// login's process group (`CLIProcess`) and is not the source's failure.
    public func startSignIn() {
        guard signInTask == nil else { return }
        signInGeneration += 1
        let mine = signInGeneration
        signingIn = true
        loginLines = []
        signInTask = Task { [weak self] in
            await self?.signIn(mine)
            // A sign-in cancelled and started again meanwhile is the new one's to finish.
            guard let self, mine == self.signInGeneration else { return }
            self.signInTask = nil
            self.signingIn = false
        }
    }

    /// **Cancel** — the button, and leaving the pane (`onDisappear`): a pending sign-in does not outlive the place that
    /// shows its code.
    public func cancelSignIn() {
        signInGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        signingIn = false
        loginLines = []
    }

    /// The login itself; `startSignIn` owns its task and its end.
    func signIn(_ mine: Int) async {
        // A line from a sign-in already cancelled is not shown under the current one.
        let append: @MainActor @Sendable (String) -> Void = { [weak self] line in
            guard let self, mine == self.signInGeneration else { return }
            self.loginLines.append(line)
        }
        do {
            if let runLogin {
                try await runLogin(append)
            } else {
                guard let codex = try MeaningProviders.make(preferences.settings) as? CodexCLIProvider else { return }
                _ = try await codex.login { line in
                    Task { @MainActor in append(line) }
                }
            }
            guard !Task.isCancelled, mine == signInGeneration else { return }
            loginLines = []
            await refreshStatus()
        } catch {
            // A cancelled login is the reader's choice, not the source's failure; a superseded one says nothing.
            guard mine == signInGeneration, !Task.isCancelled, !(error is CancellationError),
                  (error as? AIProviderError) != .cancelled else { return }
            status = .failed((error as? AIProviderError) ?? .framework("codex"))
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

/// **The live model-list fetch**: sayso's catalogue, asked afresh on each press. A list is a snapshot the service itself
/// changes — a model pulled into a local server a minute ago must appear on the next press — so nothing is cached here
/// and nothing is persisted; the pane holds the last answer in memory.
@Sendable func liveModelFetch(_ request: ModelCatalog.Request) async -> Result<[AIModel], ModelCatalogError> {
    do {
        return .success(try await ModelCatalog().fetch(request))
    } catch {
        return .failure(error)
    }
}
