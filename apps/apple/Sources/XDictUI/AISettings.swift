import AppKit
import Combine
import SwiftUI
import XDictAI
import XDictTokens

/// **AI, in Settings** (plan-ai-meaning WI-6; ADR-0021 d.12, d.13): the sources in the order of what it costs to set one
/// up, each with its caveat and a live local check; the one disclosure switch; the cloud key's four states; and the
/// prompt — shown, editable, previewed byte for byte, and resettable. The response contract is the app's, never edited.
public struct AISettings: View {
    @State private var model = AISettingsModel(preferences: .shared)
    /// The advanced prompt group: closed by default, opened by the reader or by a Settings search that found a row in it.
    @State private var advancedShown = false
    /// The sign-in page the system refused to open, if any: its address stays on screen to copy.
    @State private var unopenedURL: URL?
    private let route: SettingsRoute

    public init(route: SettingsRoute = .shared) {
        self.route = route
    }

    /// A model of its own: a test must not read the reader's Keychain or write their preferences.
    init(model: AISettingsModel, route: SettingsRoute) {
        _model = State(initialValue: model)
        self.route = route
    }

    public var body: some View {
        @Bindable var model = model
        Form {
            sourceSection(model: model)

            if model.preferences.settings.source == .http {
                endpointSection(model: model)
            }
            if model.preferences.settings.source == .codexCLI {
                codexSection(model: model)
            }
            if model.preferences.settings.source == .claudeCLI {
                claudeSection
            }
            disclosureSection(model: model)
            promptSection(model: model)
        }
        .settingsPane()
        // **A corrected address, service, model or key re-runs the check** (audit finding, 2026-10-20): the same identity
        // the result guard reads, so the two cannot disagree (audit round 1, 2026-10-25).
        .task(id: AISettingsModel.sourceIdentity(model.preferences.settings)) {
            // **One owner for a status check**: the activation handler starts the same task through `startStatusCheck()`,
            // so the two triggers cannot run duplicates (audit round 4, 2026-10-25).
            model.startStatusCheck()
        }
        .onChange(of: model.preferences.settings.language) { model.loadDraft() }
        .onChange(of: model.promptKind) { model.loadDraft() }
        .onChange(of: model.draft) { model.draftChanged() }
        // **A capability can change while the pane is open** (audit finding, 2026-10-25): Apple Intelligence switched on
        // in System Settings, a CLI installed in Terminal. Coming back to XDict checks again, and a failed status
        // offers the same check by hand.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.startStatusCheck()
        }
        // **Nothing the pane started outlives it** (UI33; audit finding, 2026-10-25): sign-in, model load and key test.
        .onDisappear { model.cancelPaneWork() }
        // A Settings search that found a row inside Advanced opens it (UI30).
        .onAppear { revealIfAsked() }
        .onChange(of: route.revealSerial) { revealIfAsked() }
    }

    /// **The source choice and its live status** (UI32): the one native radio group, then what the check found. An address
    /// the field holds but the reader has not finished typing is named here, because the status still describes the saved
    /// one (audit round 3, 2026-10-25).
    @ViewBuilder private func sourceSection(model: AISettingsModel) -> some View {
        @Bindable var model = model
        Section {
            if model.preferences.settings.source == nil {
                Text("No source is chosen, so XDict never asks anything. Dictionaries still work as before.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.no-source")
            }
            // **One native single choice**: a radio group announces the group, the chosen source and each change to
            // VoiceOver, and moves with the arrow keys, as a row of look-alike buttons did not.
            Picker(selection: $model.choice) {
                ForEach(AISourceChoice.allCases, id: \.self) { choice in
                    sourceLabel(choice)
                        .tag(choice)
                        .accessibilityIdentifier("ai.source.\(choice.identifier)")
                }
            } label: {
                Text("Where answers come from")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(Text("Where answers come from"))
            .accessibilityIdentifier("ai.source")
            .settingsAnchor(.aiSource)
            if model.preferences.settings.source != nil {
                statusRow
            }
        } header: {
            Text("Where answers come from")
        }
    }

    private func revealIfAsked() {
        if route.revealed == SettingsSearch.Anchor.aiPrompt { advancedShown = true }
    }

    // MARK: - Sources

    /// One choice's label: its name, its caveat, and — for Apple's — the system it needs when this Mac is older.
    private func sourceLabel(_ choice: AISourceChoice) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            switch choice {
            case .off: Text("Off")
            case .local: Text("A local endpoint")
            case .cloud: Text("A cloud endpoint")
            case .apple, .codex, .claude:
                if let name = MeaningSentences.source(choice.kind, model: model.preferences.settings.model,
                                                      endpoint: model.preferences.settings.endpoint) { Text(name) }
            }
            if let kind = choice.kind {
                Text(choice.cloud ? MeaningSentences.cloudCaveat : MeaningSentences.caveat(kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // **A floor is named where the reader would choose it** (ADR-0026): never a row silently absent.
            if choice == .apple, let notice = model.appleSystemNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.apple.system")
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if model.endpointInvalid {
            // **The field's text is not the address in use** (audit round 3, 2026-10-25): saying "Configured" beside it
            // described the last saved address, which the reader cannot see.
            Label {
                Text("This is not an address, so requests still use the last saved one.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("ai.status.endpoint-invalid")
        } else {
            statusBody
        }
    }

    @ViewBuilder private var statusBody: some View {
        switch model.status {
        case .checking: checkingRow
        case .notConfigured: Text("Not set up yet.").foregroundStyle(.secondary)
        case .ready(let detail): readyRow(detail)
        case .configured(let detail): configuredRow(detail)
        case .failed(let error): failedRow(error)
        }
    }

    private var checkingRow: some View {
        progressRow("Checking…")
    }

    /// **One progress row** (audit round 3, 2026-10-25): the status check and the key test differed only in their word.
    private func progressRow(_ label: LocalizedStringResource) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            ProgressView().controlSize(.small)  // placement: spinner
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func readyRow(_ detail: String) -> some View {
        statusSummary(LocalizedStringResource("Ready"), detail: detail)
            .accessibilityIdentifier("ai.status.ready")
    }

    /// **Configured, not Ready** (audit finding, 2026-10-25): the check proves what is installed or built, not that the
    /// key or sign-in works. A word that promised more would be believed.
    private func configuredRow(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            statusSummary(LocalizedStringResource("Configured"), detail: detail)
            configuredCaption
        }
        .accessibilityIdentifier("ai.status.configured")
    }

    /// **One status row for both words** (audit round 2, 2026-10-25): they differed only in the word they say.
    private func statusSummary(_ title: LocalizedStringResource, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            Label { Text(title) } icon: { Image(systemName: "checkmark.circle") }
                .foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// What the check did not prove, by the source it could not prove it for. **Test exists only on the cloud row**
    /// (audit round 1, 2026-10-25): a local endpoint has no key to test, so its caption says what was and was not
    /// checked without naming a button the pane does not show.
    @ViewBuilder private var configuredCaption: some View {
        if model.preferences.settings.source == .http {
            if model.preferences.httpCloud {
                Text("Test checks the key; a question will say if it does not work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The address is well formed. A question will say whether the server answers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Claude Code is installed. Whether it is signed in is checked by the first question.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failedRow(_ error: AIProviderError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Label {
                Text(MeaningSentences.provider(error))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .accessibilityIdentifier("ai.status.failure")
            // **A failure is not the last word** (audit finding, 2026-10-25): installing the tool or switching a
            // capability on happens outside this pane, so the reader can ask for the check again.
            Button("Check Again") { model.startStatusCheck() }  // placement: form-pane
                .accessibilityIdentifier("ai.status.check")
        }
    }

    // MARK: - An endpoint

    private func endpointSection(model: AISettingsModel) -> some View {
        Section {
            serviceRow(model: model)
            addressRow(model: model)
            modelRow(model: model)
            if model.preferences.httpCloud {
                keyRows(model: model)
            }
        } header: {
            Text("The server")
        }
    }

    /// **The service comes first**: it fills the address and tells the provider how the key travels; Custom leaves both
    /// to the reader. Its own note is the service-specific guidance sayso's table carries.
    private func serviceRow(model: AISettingsModel) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Picker(selection: Binding(get: { model.profile.id }, set: { model.chooseProfile($0) })) {
                ForEach(MeaningProfiles.offered(cloud: model.preferences.httpCloud)) { profile in
                    serviceLabel(profile).tag(profile.id)
                }
            } label: {
                Text("Service")
            }
            .accessibilityIdentifier("ai.service")
            Text("A service fills in its address. Custom uses the one you type.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = model.profile.note {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.service.note")
            }
        }
    }

    /// **The address keeps its own draft** (audit finding, 2026-10-25): the field always shows what the reader typed;
    /// text that is not an address is marked and leaves the last good address stored, rather than snapping back under
    /// the cursor or silently replacing a working server with an unreachable string.
    private func addressRow(model: AISettingsModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            TextField(text: $model.draftEndpoint, prompt: Text(verbatim: "http://127.0.0.1:11434/v1")) {
                Text("Address")
            }
            .accessibilityIdentifier("ai.endpoint")
            .onChange(of: model.draftEndpoint) { model.endpointTyped() }
            if model.endpointInvalid {
                Text("Enter an address that begins http:// or https://, with a host.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ai.endpoint.invalid")
            } else {
                Text("An OpenAI-compatible address, such as http://127.0.0.1:11434/v1 for Ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The model, the service's own list on the reader's ask, and why the list did not come.
    private func modelRow(model: AISettingsModel) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            // **A typed model ends a probe too** (audit round 4, 2026-10-25): a verdict on the old model was speaking
            // for a configuration the reader had already changed.
            TextField(text: Binding(get: { model.preferences.settings.model },
                                    set: { model.modelTyped($0) })) {
                Text("Model")
            }
            .accessibilityIdentifier("ai.model")
            // **Not every service answers without one** (audit finding, 2026-10-25): "Empty lets the server choose" is
            // false for a service that requires a model, so the sentence promises nothing the service keeps.
            Text("The model the service answers with. A service that requires one refuses the question without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            modelListControls(model: model)
            modelsNote(model: model)
        }
    }

    /// **The service's own list, on the reader's ask** (2026-10-25): the button fetches it; the menu offers it (or the
    /// service's few known names before a fetch); typing above remains the final word.
    private func modelListControls(model: AISettingsModel) -> some View {
        HStack(spacing: Tokens.Space.s) {
            Button("Load Models") { model.startModelLoad() }  // placement: form-pane
                .disabled(model.modelsShown == .loading || model.preferences.settings.endpoint == nil
                          || model.endpointInvalid)
                .accessibilityIdentifier("ai.models.load")
            if model.modelsShown == .loading {
                ProgressView().controlSize(.small)  // placement: spinner
            }
            if !model.modelChoices.isEmpty {
                Menu {  // placement: form-pane
                    ForEach(model.modelChoices, id: \.self) { id in
                        Button { model.chooseModel(id) } label: { Text(verbatim: id) }
                    }
                } label: {
                    Text("Choose a Model")
                }
                .accessibilityIdentifier("ai.models.menu")
            }
        }
    }

    /// A service's label: its own name (a proper noun, shown verbatim), or the localized Custom.
    @ViewBuilder private func serviceLabel(_ profile: AIProviderProfile) -> some View {
        if profile.id == MeaningProfiles.custom {
            Text("Custom")
        } else {
            Text(verbatim: profile.name)
        }
    }

    /// Why the list did not come, or that it was empty; nothing while it has not been asked for.
    @ViewBuilder private func modelsNote(model: AISettingsModel) -> some View {
        switch model.modelsShown {
        case .failed(let error):
            Text(MeaningSentences.catalogue(error))
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("ai.models.failure")
        case .loaded(let list) where list.isEmpty:
            Text("This service listed no models; type one above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    /// **The cloud key's four states** (ADR-0021 d.3): paste once, then Test, Replace or Remove. The Keychain holds it;
    /// nothing here writes it anywhere else.
    @ViewBuilder private func keyRows(model: AISettingsModel) -> some View {
        switch model.keyState {
        case .absent: keyEntry(model: model)
        case .stored: keyStored(model: model)
        case .testing: keyTesting
        case .failed(let error): keyRefused(model: model, error: error)
        }
        if let failure = model.keyFailure {
            Text(failure).foregroundStyle(.red).font(.caption)
        }
    }

    private func keyEntry(model: AISettingsModel) -> some View {
        @Bindable var model = model
        return Group {
            SecureField(text: $model.draftKey) { Text("Key") }
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai.key")
            Button("Save Key") { model.saveKey() }  // placement: form-pane
                .disabled(model.draftKey.isEmpty)
                .accessibilityIdentifier("ai.key.save")
        }
    }

    private func keyStored(model: AISettingsModel) -> some View {
        Group {
            Label {
                Text("Stored in the Keychain")
            } icon: {
                Image(systemName: "checkmark.seal")
            }
            keyButtons(model: model)
        }
    }

    private var keyTesting: some View {
        progressRow("Testing…")
    }

    private func keyRefused(model: AISettingsModel, error: AIProviderError) -> some View {
        Group {
            Label {
                Text(MeaningSentences.provider(error))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            keyButtons(model: model)
        }
    }

    private func keyButtons(model: AISettingsModel) -> some View {
        HStack(spacing: Tokens.Space.s) {
            // **A test is about the address in the field** (audit finding, 2026-10-25): while that is not an address,
            // the verdict would be about the one behind it.
            Button("Test") { model.startKeyTest() }  // placement: form-pane
                .disabled(model.endpointInvalid)
                .accessibilityIdentifier("ai.key.test")
            Button("Replace") {  // placement: form-pane
                model.replaceKey()
            }
            .accessibilityIdentifier("ai.key.replace")
            Button("Remove") { model.removeKey() }  // placement: form-pane
                .accessibilityIdentifier("ai.key.remove")
        }
    }

    // MARK: - The command-line sources

    /// **The Codex sign-in, structured** (UI33): the page to open and the code to enter as their own controls, progress
    /// and Cancel beside them, and the login's raw lines under Details. Leaving the pane cancels it (`onDisappear`).
    private func codexSection(model: AISettingsModel) -> some View {
        Section {
            if model.signingIn {
                codexSignIn(model: model, login: model.login)
            } else {
                Button("Sign In with Codex…") {  // placement: form-pane
                    unopenedURL = nil
                    model.startSignIn()
                }
                    .accessibilityIdentifier("ai.codex.signin")
                Text("XDict keeps a Codex sign-in of its own, apart from the one in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Codex")
        }
    }

    /// A running login's rows: progress, the page, the code, and the tool's own lines.
    @ViewBuilder private func codexSignIn(model: AISettingsModel, login: CodexLogin) -> some View {
        codexWaiting(model: model)
        if let url = login.url { codexPage(url) }
        if let code = login.code { codexCode(code) }
        if !model.loginLines.isEmpty { codexDetails(model: model) }
    }

    private func codexWaiting(model: AISettingsModel) -> some View {
        ActionRow {
            HStack(spacing: Tokens.Space.xs) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text("Waiting for you to sign in…")
            }
        } actions: {
            Button("Cancel") {  // placement: form-pane
                unopenedURL = nil
                model.cancelSignIn()
            }
                .accessibilityIdentifier("ai.codex.cancel")
        }
    }

    /// The sign-in page, opened by the system, and its refusal said rather than swallowed — the address stays on screen
    /// to copy, because the sign-in cannot finish without it (audit finding, 2026-10-25).
    private func codexPage(_ url: URL) -> some View {
        Group {
            ActionRow {
                Text(verbatim: url.host() ?? url.absoluteString).foregroundStyle(.secondary)
            } actions: {
                Button("Open Sign-In Page") { open(url) }  // placement: form-pane
                    .accessibilityIdentifier("ai.codex.open")
            }
            if unopenedURL == url {
                Text("The sign-in page could not be opened. Copy its address and open it in your browser.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("ai.codex.open.failure")
                ActionRow {
                    Text(verbatim: url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                } actions: {
                    Button("Copy Address") { copy(url.absoluteString) }  // placement: form-pane
                        .accessibilityIdentifier("ai.codex.open.copy")
                }
            }
        }
    }

    private func codexCode(_ code: String) -> some View {
        ActionRow {
            LabeledContent {
                Text(verbatim: code).font(.title3.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("ai.codex.code")
            } label: {
                Text("Code")
            }
        } actions: {
            Button("Copy Code") { copy(code) }  // placement: form-pane
                .accessibilityIdentifier("ai.codex.copy")
        }
    }

    private func codexDetails(model: AISettingsModel) -> some View {
        DisclosureGroup {
            // The login's own lines, verbatim. Data, never translated.
            ForEach(Array(model.loginLines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: CodexLogin.stripEscapes(line)).font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } label: {
            Text("Details")
        }
    }

    /// **Claude Code signs in where XDict runs it** (audit finding, 2026-10-25): a bare `claude` in Terminal signs into
    /// the reader's own configuration, which XDict never reads; this command names XDict's and creates it first.
    private var claudeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text("XDict runs Claude Code in its own configuration, apart from the one in Terminal. To sign in there, run this in Terminal and follow the sign-in it shows:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: claudeSignInCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ai.claude.command")
                Button("Copy Command") { copy(claudeSignInCommand) }  // placement: form-pane
                    .accessibilityIdentifier("ai.claude.copy")
            }
        } header: {
            Text("Claude")
        }
    }

    /// The exact shell line that signs in where XDict's Claude Code runs: the same `CLAUDE_CONFIG_DIR` the provider sets.
    /// The folder is one single-quoted shell word (audit round 1, 2026-10-25): a home directory containing `$`, a
    /// backtick or `"` is then literal text, not a substitution the reader's paste would execute.
    private var claudeSignInCommand: String {
        let folder = Self.shellQuoted(MeaningProviders.folder("claude").path(percentEncoded: false))
        return "mkdir -p \(folder) && CLAUDE_CONFIG_DIR=\(folder) claude"
    }

    /// A path as one shell word: single quotes, and each embedded single quote closed, escaped and reopened — the one
    /// quoting that leaves `$`, backticks, `"` and `\` literal.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The pasteboard, once: a code, an address or a command the reader must type exactly.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// **The system's own open, and its refusal said**: `NSWorkspace.open` answers whether it opened anything.
    private func open(_ url: URL) {
        unopenedURL = NSWorkspace.shared.open(url) ? nil : url
    }

    // MARK: - What leaves XDict

    private func disclosureSection(model: AISettingsModel) -> some View {
        Section {
            Toggle(isOn: Binding(get: { model.preferences.settings.sendEntryText },
                                 set: { model.preferences.setSendEntryText($0) })) {
                Text("Send the entry’s text with the question")
                Text("Off, only the sentence around the word is sent — to every source, one on this Mac included.")
            }
            .accessibilityIdentifier("ai.send-entry")
            Toggle(isOn: Binding(get: { model.preferences.settings.previewBeforeSending },
                                 set: { model.preferences.setPreviewBeforeSending($0) })) {
                Text("Show the request before asking")
                Text("On, choosing a question shows exactly what will be sent, with Send and Cancel, the first time a sentence is asked. Off, the question is asked when you choose it.")
            }
            .accessibilityIdentifier("ai.preview-before-sending")
            Toggle(isOn: Binding(get: { model.preferences.settings.askOnOpen },
                                 set: { model.preferences.setAskOnOpen($0) })) {
                Text("Ask when the answer pane opens")
                Text("A captured sentence opens the pane and asks the question you last chose. Off, the pane opens and you choose the question.")
            }
            .accessibilityIdentifier("ai.ask-on-open")
        } header: {
            Text("What leaves XDict")
        }
        .settingsAnchor(.aiEntryText)
    }

    // MARK: - The prompt

    /// **The answer's language, in the ordinary flow; the prompt, under Advanced** (UI18): a reader configures an
    /// ordinary explanation without meeting template variables or the response contract. An edit stays saved and
    /// labelled *your wording, not measured* (ADR-0021), on the closed disclosure's label too.
    private func promptSection(model: AISettingsModel) -> some View {
        Group {
            Section {
                languageRow(model: model)
            } header: {
                Text("The answer")
            }
            Section {
                DisclosureGroup(isExpanded: $advancedShown) {
                    advancedPrompt(model: model)
                } label: {
                    HStack(spacing: Tokens.Space.s) {
                        Text("Customize the Prompt")
                        if model.hasEditedPrompt {
                            editedBadge("ai.prompt.edited.any")
                        }
                    }
                }
                .accessibilityIdentifier("ai.prompt.advanced")
                .settingsAnchor(.aiPrompt)
            } header: {
                Text("Advanced")
            }
        }
    }

    /// **The answer's language** (UI18): the templates the editor shows are that language's, and the preferences' own
    /// change observer loads them — a setter that also loaded them here loaded every switch twice (audit finding,
    /// 2026-10-25).
    private func languageRow(model: AISettingsModel) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Picker(selection: Binding(get: { model.preferences.settings.language },
                                      set: { model.preferences.setLanguage($0) })) {
                Text("English").tag("en")
                Text("Simplified Chinese").tag("zh-Hans")
            } label: {
                Text("Answer language")
            }
            .accessibilityIdentifier("ai.language")
            .settingsAnchor(.aiLanguage)
            // **What the choice does, exactly** (contract 4, §4b): it is the answer's language, not only the prompt's;
            // quotes stay verbatim in the dictionary's language; the instruction is the app's, so an edited prompt
            // cannot remove it.
            Text("The explanation is written in this language. Quotes stay in the dictionary’s own language, and an edited prompt does not change this: the instruction is the app’s.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ai.language.caption")
            // **Where a translation is written into** (owner, 2026-10-26: the pane's own "Into …" menu was redundant,
            // and the reader's target belongs with the other answer settings): one choice, the pane has none of its own.
            Picker(selection: Binding(get: { model.preferences.settings.translationLanguage },
                                      set: { model.preferences.setTranslationLanguage($0) })) {
                ForEach(MeaningSentences.translationLanguages, id: \.self) { tag in
                    Text(MeaningSentences.languageName(tag)).tag(tag)
                }
            } label: {
                Text("Translate into")
            }
            .accessibilityIdentifier("ai.translation-language")
            .settingsAnchor(.aiTranslationLanguage)
        }
    }

    @ViewBuilder private func advancedPrompt(model: AISettingsModel) -> some View {
        @Bindable var model = model
        Picker(selection: $model.promptKind) {
            Text("Grounded in the entry").tag(AIMode.grounded)
            Text("From the sentence alone").tag(AIMode.sentenceOnly)
            Text("Explaining a chosen sense").tag(AIMode.explainSense)
            Text("Translating the sentence").tag(AIMode.translate)
            Text("Explaining the grammar").tag(AIMode.explainGrammar)
        } label: {
            Text("Question kind")
            Text("Each kind has its own prompt.")
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("ai.prompt.kind")
        promptEditor(model: model)
        promptGuidance
        promptPreview(model: model)
        promptContract(model: model)
    }

    private func promptEditor(model: AISettingsModel) -> some View {
        @Bindable var model = model
        return Group {
            TextEditor(text: $model.draft)
                .font(.body.monospaced())
                .frame(minHeight: Tokens.Control.promptEditor)
                .accessibilityLabel(Text("Prompt"))
                .accessibilityIdentifier("ai.prompt.editor")
            if model.preferences.isEdited(language: model.language, mode: model.promptKind) {
                editedBadge("ai.prompt.edited")
            }
            Button("Reset to Default") { model.resetDraft() }  // placement: form-pane
                .disabled(!model.canResetDraft())
                .accessibilityIdentifier("ai.prompt.reset")
        }
    }

    /// **The edit badge, once** (audit finding, 2026-10-25): the closed disclosure and the editor say the same thing,
    /// and two hand-written copies had already drifted apart.
    private func editedBadge(_ identifier: String) -> some View {
        Label {
            Text("Your wording, not measured")
        } icon: {
            Image(systemName: "pencil")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }

    private var promptGuidance: some View {
        Text(Self.guidance(for: model.promptKind))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **Each kind's own placeholders** (audit round 2, 2026-10-25): the composer requires two, permits `{language}` and
    /// requires or forbids `{entry}` and `{sense}` by mode; one sentence that listed all five alike taught a rule the
    /// composer does not have.
    static func guidance(for kind: AIMode) -> LocalizedStringResource {
        switch kind {
        case .grounded:
            LocalizedStringResource("The prompt needs {term}, {sentence} and {entry}; {language} is optional and {sense} is not used here. A missing or unknown placeholder is refused before anything is sent. XDict appends the response format, which cannot be edited.")
        case .sentenceOnly:
            LocalizedStringResource("The prompt needs {term} and {sentence}; {language} is optional, and {entry} and {sense} are not used here. A missing or unknown placeholder is refused before anything is sent. XDict appends the response format, which cannot be edited.")
        case .explainSense:
            LocalizedStringResource("The prompt needs {term}, {sentence}, {entry} and {sense}; {language} is optional. A missing or unknown placeholder is refused before anything is sent. XDict appends the response format, which cannot be edited.")
        case .translate:
            LocalizedStringResource("The prompt needs {term} and {sentence}; {language} names the language to translate into and is optional here, and {entry} and {sense} are not used. A missing or unknown placeholder is refused before anything is sent. XDict appends the response format, which cannot be edited.")
        case .explainGrammar:
            LocalizedStringResource("The prompt needs {term} and {sentence}; {language} is optional, and {entry} and {sense} are not used. A missing or unknown placeholder is refused before anything is sent. XDict appends the response format, which cannot be edited.")
        }
    }

    private func promptPreview(model: AISettingsModel) -> some View {
        DisclosureGroup {
            previewText(model: model)
            Text(model.promptKind.carriesEntry
                 ? LocalizedStringResource("This is a sample: the sentence you capture and the entry you see are sent instead, when the entry-text switch is on.")
                 : LocalizedStringResource("This is a sample: only the sentence you capture is sent."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Text("Preview the request")
        }
        .accessibilityIdentifier("ai.prompt.preview")
    }

    private func promptContract(model: AISettingsModel) -> some View {
        DisclosureGroup {
            // **The chosen-sense kind has its own contract** (contract 3, §6a): showing the other one would describe an
            // answer this ask never accepts.
            Text(verbatim: AIComposer.responseContract(for: model.promptKind))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        } label: {
            // **The disclosure shows the response format** (audit round 2, 2026-10-25): the language line and the
            // state blocks are also appended, and "every request" claimed to show all of them.
            Text("Response Format")
        }
    }

    @ViewBuilder private func previewText(model: AISettingsModel) -> some View {
        switch MeaningPreview.compose(template: model.draft, language: model.language, mode: model.promptKind) {
        case .success(let text):
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ai.prompt.preview.text")
        case .failure(let error):
            Text(MeaningSentences.compose(error))
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("ai.prompt.preview.error")
        }
    }
}
