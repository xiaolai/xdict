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

    /// Everything a live check depends on: a corrected address, model or key re-runs it (audit finding, 2026-10-20).
    private struct StatusKey: Hashable {
        let source: AIProviderKind?
        let endpoint: String
        let profile: String
        let model: String
        let usesKey: Bool
        let key: String
    }

    public var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if model.preferences.settings.source == nil {
                    Text("No source is chosen, so XDict never asks anything. Dictionaries still work as before.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ai.no-source")
                }
                // **One native single choice** (UI32): a radio group announces the group, the chosen source and each
                // change to VoiceOver, and moves with the arrow keys, as a row of look-alike buttons did not.
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
        .task(id: StatusKey(source: model.preferences.settings.source,
                            endpoint: model.preferences.settings.endpoint?.absoluteString ?? "",
                            profile: MeaningProviders.profile(model.preferences.settings).id,
                            model: model.preferences.settings.model,
                            usesKey: model.preferences.settings.usesKey,
                            key: MeaningProviders.apiKey(model.preferences.settings) ?? "")) {
            await model.refreshStatus()
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
                if let name = MeaningSentences.source(choice.kind) { Text(name) }
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
        switch model.status {
        case .checking: checkingRow
        case .notConfigured: Text("Not set up yet.").foregroundStyle(.secondary)
        case .ready(let detail): readyRow(detail)
        case .configured(let detail): configuredRow(detail)
        case .failed(let error): failedRow(error)
        }
    }

    private var checkingRow: some View {
        HStack(spacing: Tokens.Space.xs) {
            ProgressView().controlSize(.small)  // placement: spinner
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    private func readyRow(_ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            Label { Text("Ready") } icon: { Image(systemName: "checkmark.circle") }
                .foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("ai.status.ready")
    }

    /// **Configured, not Ready** (audit finding, 2026-10-25): the check proves what is installed or built, not that the
    /// key or sign-in works. A word that promised more would be believed.
    private func configuredRow(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                Label { Text("Configured") } icon: { Image(systemName: "checkmark.circle") }
                    .foregroundStyle(.secondary)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            configuredCaption
        }
        .accessibilityIdentifier("ai.status.configured")
    }

    /// What the check did not prove, by the source it could not prove it for.
    @ViewBuilder private var configuredCaption: some View {
        if model.preferences.settings.source == .http {
            Text("Test checks the key; a question will say if it does not work.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            TextField(text: Binding(get: { model.preferences.settings.model },
                                    set: { model.preferences.setModel($0) })) {
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
        HStack(spacing: Tokens.Space.xs) {
            ProgressView().controlSize(.small)  // placement: spinner
            Text("Testing…").foregroundStyle(.secondary)
        }
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
                Button("Sign In with Codex…") { model.startSignIn() }  // placement: form-pane
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
            Button("Cancel") { model.cancelSignIn() }  // placement: form-pane
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
    private var claudeSignInCommand: String {
        let folder = MeaningProviders.folder("claude").path(percentEncoded: false)
        return "mkdir -p \"\(folder)\" && CLAUDE_CONFIG_DIR=\"\(folder)\" claude"
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
        Picker(selection: Binding(get: { model.preferences.settings.language },
                                  set: { model.preferences.setLanguage($0) })) {
            Text("English").tag("en")
            Text("Simplified Chinese").tag("zh-Hans")
        } label: {
            Text("Answer language")
        }
        .accessibilityIdentifier("ai.language")
        .settingsAnchor(.aiLanguage)
    }

    @ViewBuilder private func advancedPrompt(model: AISettingsModel) -> some View {
        @Bindable var model = model
        Picker(selection: $model.promptKind) {
            Text("Grounded in the entry").tag(AIMode.grounded)
            Text("From the sentence alone").tag(AIMode.sentenceOnly)
            Text("Explaining a chosen sense").tag(AIMode.explainSense)
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
                .disabled(!model.preferences.isEdited(language: model.language, mode: model.promptKind))
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
        Text("The prompt uses {term}, {sentence}, {entry}, {sense} and {language}; a missing or unknown one is refused before anything is sent. XDict appends the response format, which cannot be edited.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func promptPreview(model: AISettingsModel) -> some View {
        DisclosureGroup {
            previewText(model: model)
            Text("This is a sample: the sentence you capture and the entry you see are sent instead.")
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
            Text(verbatim: model.promptKind == .explainSense ? AIComposer.explainResponseContract
                                                             : AIComposer.responseContract)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        } label: {
            Text("What XDict adds to every request")
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
