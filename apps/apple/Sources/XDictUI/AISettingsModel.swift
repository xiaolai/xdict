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
    /// The configuration a failed key test spoke for: another one makes its verdict stale (audit finding, 2026-10-25).
    /// **A failed probe's configuration, without the key it carried** (audit round 4, 2026-10-25): the row only needs to
    /// know whether the reader changed what the failure described, and the secret is not part of that answer.
    struct KeyVerdict: Equatable {
        let source: AIProviderKind?
        let endpoint: String
        let profile: String
        let model: String

        init(_ settings: MeaningSettings) {
            source = settings.source
            endpoint = settings.endpoint?.absoluteString ?? ""
            profile = MeaningProviders.profile(settings).id
            model = settings.model
        }
    }

    @ObservationIgnored private var keyVerdict: KeyVerdict?
    public var keyState: KeyState = .absent
    public var draftKey = ""
    /// **The address as typed** (audit finding, 2026-10-25): the field has its own editing state, so text that is not
    /// yet an address stays visible (and marked) while the last good address remains what the source uses. Binding the
    /// field straight to the stored value made a mid-edit string snap back under the reader's cursor.
    public var draftEndpoint = ""
    /// Whether the draft is not an address XDict can store: http or https with a host.
    public private(set) var endpointInvalid = false
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
    /// **Check Again** and the app's own return to the front own their check here, so leaving the pane ends it too.
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// The Codex login's own output, verbatim: the web address and code the reader needs. Data, never translated.
    public private(set) var loginLines: [String] = []
    public private(set) var signingIn = false
    /// What the login's lines say, structured (UI33): the address to open and the code to enter.
    public var login: CodexLogin { CodexLogin.parse(loginLines) }

    /// **How a sign-in runs**: the Codex login by default; a test hands in its own. Lines arrive on the main actor.
    public typealias Login = @MainActor (_ onLine: @escaping @MainActor (String) -> Void) async throws -> Void
    /// **How a model list is fetched**: sayso's catalogue by default; a test hands in its own.
    public typealias FetchModels = @Sendable (ModelCatalog.Request) async -> Result<[AIModel], ModelCatalogError>
    /// **How a source's live check is made**: the providers' own checks by default; a test hands in its own, so a
    /// superseded or cancelled check's result can be held and then released.
    public typealias CheckStatus = @Sendable (MeaningSettings) async -> MeaningSourceStatus
    @ObservationIgnored private let runLogin: Login?
    @ObservationIgnored private let fetchModels: FetchModels
    @ObservationIgnored private let checkStatus: CheckStatus
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    /// Whether the running login's lines are still shown: its own end closes them (audit round 3).
    @ObservationIgnored private var loginAcceptsLines = false
    @ObservationIgnored private var signInGeneration = 0

    public init(preferences: MeaningPreferences, login: Login? = nil, fetchModels: FetchModels? = nil,
                checkStatus: CheckStatus? = nil) {
        self.preferences = preferences
        runLogin = login
        // The live fetch is internal: a public initializer's default value cannot name it, so nil resolves here.
        self.fetchModels = fetchModels ?? liveModelFetch
        self.checkStatus = checkStatus ?? { await MeaningProviders.status($0) }
        keyState = preferences.hasKey ? .stored : .absent
        draft = preferences.effectiveTemplate(language: preferences.settings.language, mode: promptKind)
        draftEndpoint = preferences.settings.endpoint?.absoluteString ?? ""
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
    /// The language a translation is written into: the preview of a translate template asks for this one (audit 2026-10-27).
    public var translationLanguage: String { preferences.settings.translationLanguage }

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
        invalidateKeyTest()
        // **A sign-in belongs to the Codex source** (audit finding, 2026-10-25): choosing another source ends the login,
        // so its process group stops and no line or failure of it can land under the new source.
        if kind != .codexCLI { cancelSignIn() }
        preferences.choose(kind, cloud: cloud)
        loadEndpointDraft()
        keyFailure = nil
        if kind == .http, cloud, preferences.hasKey { keyState = .stored }
    }

    /// **A service choice fills the address** (both the stored endpoint and the field's draft): from here, the reader's
    /// own edit starts from the service's base address rather than from the other row's.
    public func chooseProfile(_ id: String) {
        invalidateKeyTest()
        preferences.chooseProfile(id)
        loadEndpointDraft()
    }

    /// **The address field was edited**: an address is stored as it becomes valid; text that is not one yet stays in the
    /// field, marked, and the source keeps the last good address. An empty field is the reader asking for none.
    public func endpointTyped() {
        let text = draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            invalidateKeyTest()
            preferences.setEndpoint("")
            endpointInvalid = false
            return
        }
        guard MeaningPreferences.address(text) != nil else {
            endpointInvalid = true
            invalidateKeyTest()
            return
        }
        invalidateKeyTest()
        preferences.setEndpoint(text)
        // The space or newline around a pasted address is not part of it: once it is a valid address, the field shows the
        // address itself (the same text the stored value has), not the paste's padding.
        if draftEndpoint != text { draftEndpoint = text }
        endpointInvalid = false
    }

    private func loadEndpointDraft() {
        draftEndpoint = preferences.settings.endpoint?.absoluteString ?? ""
        endpointInvalid = false
    }

    /// **Check Again**'s owner, and the app's return to the front: one check at a time, ended with the pane.
    public func startStatusCheck() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in await self?.refreshStatus() }
    }

    public func refreshStatus() async {
        // **A check cancelled before it starts does nothing** (audit round 3, 2026-10-25): `startStatusCheck()` followed by
        // the pane closing must not publish "Checking…" or call the provider.
        guard !Task.isCancelled else { return }
        // **A superseded check cannot overwrite the current source's status** (audit finding, 2026-10-20), and neither
        // can a check cancelled by the pane or made for a configuration the reader has since changed (audit finding,
        // 2026-10-25: the task is driven by `StatusKey`, so a change starts a new one and cancels this one).
        if case .failed = keyState, let verdict = keyVerdict, verdict != KeyVerdict(preferences.settings) {
            restoreKeyState()
        }
        statusGeneration += 1
        let mine = statusGeneration
        let settings = preferences.settings
        status = .checking
        let found = await checkStatus(settings)
        // **Only a change in what the check reads makes it stale**: the prompt's text or the disclosure switch moving
        // while a check runs must not leave the pane saying "Checking…" forever.
        guard mine == statusGeneration, !Task.isCancelled,
              Self.sameSource(settings, preferences.settings) else { return }
        status = found
    }

    /// **What a live check and a key probe depend on**: the source, its address, the service it actually uses, its model
    /// and the key it actually sends. The view's `task(id:)` and the stale-result guard read this one value, so a check is
    /// restarted exactly when its inputs change. The *effective* service and key count: a stored profile the chosen row
    /// does not use, or a key it does not send, must not make a check stale.
    struct SourceIdentity: Hashable {
        let source: AIProviderKind?
        let endpoint: String
        let profile: String
        let model: String
        let key: String
    }

    static func sourceIdentity(_ settings: MeaningSettings) -> SourceIdentity {
        SourceIdentity(source: settings.source, endpoint: settings.endpoint?.absoluteString ?? "",
                       profile: MeaningProviders.profile(settings).id, model: settings.model,
                       key: MeaningProviders.apiKey(settings) ?? "")
    }

    private static func sameSource(_ captured: MeaningSettings, _ now: MeaningSettings) -> Bool {
        sourceIdentity(captured) == sourceIdentity(now)
    }

    // MARK: - The model list (2026-10-25)

    /// **Load the service's own model list**, on the reader's ask and never per keystroke. Every press asks the service:
    /// the list changes when a model is pulled or retired, and a cached answer would make the button look broken.
    public func loadModels() async {
        // **A task cancelled before it ran does nothing**: a cancelled button press must not start a request, and its
        // `modelsGeneration` bump would otherwise let that request speak for the pane after it is gone.
        guard !Task.isCancelled, !endpointInvalid else { return }
        guard preferences.settings.source == .http, let endpoint = preferences.settings.endpoint else {
            // **A pane with no endpoint has no load**: the generation advances so an older request cannot land here.
            modelsGeneration += 1
            resetModels()
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
            if mine == modelsGeneration { resetModels() }
            return
        }
        // **A cancelled load publishes nothing** (audit round 2, 2026-10-25): a fetch that ignores cancellation must not
        // land after the pane's own cancellation, and neither must one whose address draft is no longer an address.
        guard !Task.isCancelled, !endpointInvalid else {
            resetModels()
            return
        }
        switch result {
        case .success(let list): models = .loaded(list)
        case .failure(let error): models = .failed(error)
        }
    }

    /// **No model list is shown and none is owned**: the one reset four paths need (audit round 4, 2026-10-25).
    private func resetModels() {
        models = .idle
        modelsIdentity = nil
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
        resetModels()
    }

    /// **Nothing the pane started outlives it**: the sign-in, a model load and a key test end together.
    public func cancelPaneWork() {
        cancelSignIn()
        discardModelLoad()
        keyTestTask?.cancel()
        keyTestTask = nil
        statusTask?.cancel()
        statusTask = nil
        restoreKeyState()
    }

    /// A model picked from the list is the reader's choice, stored exactly as typing it would.
    public func chooseModel(_ id: String) {
        invalidateKeyTest()
        preferences.setModel(id)
    }

    // MARK: - The key

    public func saveKey() {
        do {
            try preferences.setKey(draftKey)
            // A test still running was about the key this replaces: its result must not speak for the new one.
            keyGeneration += 1
            draftKey = ""
            keyFailure = nil
            keyVerdict = nil
            keyState = .stored
        } catch {
            let status = (error as? MeaningKeyError)?.status ?? -1
            keyFailure = LocalizedStringResource("The Keychain refused to save the key (status \(status)).")
        }
    }

    /// **Replace**: the field comes back for a new key; a test still running no longer speaks for it, and the old key's
    /// verdict belongs to the key being replaced (audit finding, 2026-10-25).
    public func replaceKey() {
        keyGeneration += 1
        keyVerdict = nil
        keyFailure = nil
        keyState = .absent
        draftKey = ""
    }

    public func removeKey() {
        do {
            try preferences.setKey(nil)
            // The key a running test is proving is gone; its verdict must not bring `.stored` back, and a stored failure
            // verdict describes a key that is no longer there (audit round 4, 2026-10-25).
            keyGeneration += 1
            keyVerdict = nil
            keyState = .absent
            keyFailure = nil
        } catch {
            // A refused delete used to be swallowed: Remove cleared the field and the key returned after relaunch.
            let status = (error as? MeaningKeyError)?.status ?? -1
            keyFailure = LocalizedStringResource("The Keychain refused to remove the key (status \(status)).")
        }
    }

    /// **The model field's own change** (audit round 4, 2026-10-25): the probe is about the model it started for, so a
    /// typed model invalidates it as a source, profile or endpoint change does.
    public func modelTyped(_ model: String) {
        invalidateKeyTest()
        preferences.setModel(model)
    }

    /// **Test**'s owner: one probe at a time, started by the view and cancellable with it.
    public func startKeyTest() {
        keyTestTask?.cancel()
        keyTestTask = Task { [weak self] in await self?.testKey() }
    }

    /// **Test** asks the endpoint one short question (`HTTPProvider.probe`), which is the only way to know the key works.
    public func testKey() async {
        // **The field's invalid text is not an address**: probing the stored one behind it would be a verdict on a
        // server the reader is no longer naming (audit finding, 2026-10-25).
        guard !Task.isCancelled, !endpointInvalid else { return }
        keyGeneration += 1
        let mine = keyGeneration
        // **A new probe replaces the last verdict** (audit round 4, 2026-10-25): the old failure named the configuration
        // this one is proving again.
        keyVerdict = nil
        keyState = .testing
        let settings = preferences.settings
        guard let endpoint = settings.endpoint else {
            keyVerdict = KeyVerdict(settings)
            keyState = .failed(.unreachable)
            return
        }
        let failure: AIProviderError?
        do {
            let provider = try HTTPProvider(configuration: MeaningProviders.httpConfiguration(settings, endpoint: endpoint))
            _ = try await provider.probe()
            failure = nil
        } catch {
            // The probe's failures are typed `AIProviderError` already: a raw `CancellationError` cannot reach here.
            failure = error
        }
        guard mine == keyGeneration else { return }
        // **One completion rule for a success and a failure** (audit round 2, 2026-10-25): a cancelled probe is the
        // pane's choice, not the key's verdict; a result for an address the field no longer holds, or a configuration
        // the reader has since changed, proves nothing (audit findings of 2026-10-20, 2026-10-25).
        guard !Task.isCancelled, !endpointInvalid, failure != .cancelled,
              Self.sameSource(settings, preferences.settings) else {
            restoreKeyState()
            return
        }
        keyVerdict = failure.map { _ in KeyVerdict(settings) }
        keyState = failure.map { .failed($0) } ?? .stored
    }

    /// The stored key outlives a stale probe; its four-state row shows what is still true. **Its verdict goes with the
    /// configuration it described** (audit round 4, 2026-10-25): only a failure keeps one.
    private func restoreKeyState() {
        keyVerdict = nil
        keyState = preferences.hasKey ? .stored : .absent
    }

    /// **A probe belongs to the configuration it started for** (audit round 4, 2026-10-25): a change ends it at once
    /// rather than leaving the key row disabled until an obsolete request returns. A stored failure verdict is the same
    /// fact — it named the configuration the reader has now left — so it goes too.
    private func invalidateKeyTest() {
        if case .testing = keyState {
            keyGeneration += 1
            keyState = preferences.hasKey ? .stored : .absent
        } else if case .failed = keyState {
            keyState = preferences.hasKey ? .stored : .absent
        }
        keyVerdict = nil
    }

    // MARK: - The command-line sources

    /// **Sign In with Codex…** (UI33): one login at a time, owned here so the pane can cancel it; cancelling ends its
    /// process group (`CLIProcess`) and is not the source's failure. The returned task is the login's own end, cancellation
    /// included, so a caller that must know it is over awaits it instead of sleeping. The pane ignores it.
    @discardableResult
    public func startSignIn() -> Task<Void, Never>? {
        guard signInTask == nil else { return signInTask }
        signInGeneration += 1
        let mine = signInGeneration
        signingIn = true
        loginAcceptsLines = true
        loginLines = []
        let task = Task { [weak self] in
            await self?.signIn(mine)
            // A sign-in cancelled and started again meanwhile is the new one's to finish.
            guard let self, mine == self.signInGeneration else { return }
            self.signInTask = nil
            self.signingIn = false
        }
        signInTask = task
        return task
    }

    /// **Cancel** — the button, and leaving the pane (`onDisappear`): a pending sign-in does not outlive the place that
    /// shows its code.
    public func cancelSignIn() {
        signInGeneration += 1
        loginAcceptsLines = false
        signInTask?.cancel()
        signInTask = nil
        signingIn = false
        loginLines = []
    }

    /// **One ordered consumer for a login's lines**: the Codex CLI calls its handler from the process's output thread, and
    /// a task per line landed two lines in either order. The main queue is FIFO, so the lines keep the login's order.
    nonisolated static func deliver(_ line: String,
                                    to append: @escaping @MainActor @Sendable (String) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { append(line) } }
    }

    /// The login itself; `startSignIn` owns its task and its end.
    func signIn(_ mine: Int) async {
        // A line from a sign-in already cancelled is not shown under the current one.
        let append: @MainActor @Sendable (String) -> Void = { [weak self] line in
            // **A line queued before the login finished is not shown after it** (audit round 3, 2026-10-25): the output is
            // closed by the sign-in's own end, not only by a newer generation.
            guard let self, mine == self.signInGeneration, self.loginAcceptsLines else { return }
            self.loginLines.append(line)
        }
        // **The output closes on every end of this login** (audit round 3, 2026-10-25): a cancellation or supersession that
        // returns early still belonged to this generation's login.
        defer { if mine == signInGeneration { loginAcceptsLines = false } }
        do {
            if let runLogin {
                try await runLogin(append)
            } else {
                let codex = MeaningProviders.codex()
                _ = try await codex.login { line in Self.deliver(line, to: append) }
            }
            // **A finished login speaks only while Codex is still the source** (audit finding, 2026-10-25): the reader
            // may have chosen another source during it, and neither its success nor its failure is that source's.
            guard !Task.isCancelled, mine == signInGeneration, preferences.settings.source == .codexCLI else { return }
            loginAcceptsLines = false
            loginLines = []
            await refreshStatus()
        } catch {
            // A cancelled login is the reader's choice, not the source's failure; a superseded one says nothing.
            guard mine == signInGeneration, !Task.isCancelled, preferences.settings.source == .codexCLI,
                  !(error is CancellationError), (error as? AIProviderError) != .cancelled else { return }
            loginAcceptsLines = false
            // **A login's failure outranks a status check already running** (audit round 2, 2026-10-25): that check's
            // generation is older than this verdict, and its guard must not let it overwrite the failure.
            statusGeneration += 1
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
        // **An empty editor is the reader starting over** (audit round 4, 2026-10-25): it saves nothing and restores
        // nothing; the preview says the template cannot compose until text exists. Reset to Default is the way back.
        guard !draft.isEmpty else { return }
        let shipped = AITemplates.effective(language: language, mode: promptKind, stored: nil)
        if draft == shipped {
            preferences.setTemplate(nil, language: language, mode: promptKind)
        } else {
            preferences.setTemplate(draft, language: language, mode: promptKind)
        }
    }

    public func resetDraft() {
        preferences.resetTemplates(language: preferences.settings.language, mode: promptKind)
        loadDraft()
    }

    /// **Reset is offered whenever Reset would change the text** (audit round 4, 2026-10-25): an editor cleared over an
    /// unedited default has nothing else to bring the default back, so the button used to be disabled where it was needed.
    public func canResetDraft() -> Bool {
        let language = preferences.settings.language
        return preferences.isEdited(language: language, mode: promptKind)
            || draft != AITemplates.effective(language: language, mode: promptKind, stored: nil)
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
