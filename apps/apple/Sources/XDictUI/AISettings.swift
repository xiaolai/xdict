import AppKit
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
                            model: model.preferences.settings.model,
                            usesKey: model.preferences.settings.usesKey,
                            key: model.preferences.settings.key ?? "")) {
            await model.refreshStatus()
        }
        .onChange(of: model.preferences.settings.language) { model.loadDraft() }
        .onChange(of: model.promptKind) { model.loadDraft() }
        .onChange(of: model.draft) { model.draftChanged() }
        // **A pending sign-in does not outlive the pane that shows its code** (UI33).
        .onDisappear { model.cancelSignIn() }
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
        case .checking:
            HStack(spacing: Tokens.Space.xs) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .notConfigured:
            Text("Not set up yet.").foregroundStyle(.secondary)
        case .ready(let detail):
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                Label { Text("Ready") } icon: { Image(systemName: "checkmark.circle") }
                    .foregroundStyle(.secondary)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("ai.status.ready")
        case .failed(let error):
            Label {
                Text(MeaningSentences.provider(error))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .accessibilityIdentifier("ai.status.failure")
        }
    }

    // MARK: - An endpoint

    private func endpointSection(model: AISettingsModel) -> some View {
        @Bindable var model = model
        return Section {
            // Each field is its own Form row: the field's label is the row's label, said once
            // (`RepeatedLabelTests`), with its sentence under it.
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                TextField(text: Binding(get: { model.preferences.settings.endpoint?.absoluteString ?? "" },
                                        set: { text in model.preferences.setEndpoint(text) }),
                          prompt: Text(verbatim: "http://127.0.0.1:11434/v1")) {
                    Text("Address")
                }
                .accessibilityIdentifier("ai.endpoint")
                Text("An OpenAI-compatible address, such as http://127.0.0.1:11434/v1 for Ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                TextField(text: Binding(get: { model.preferences.settings.model },
                                        set: { text in model.preferences.update { $0.model = text } })) {
                    Text("Model")
                }
                .accessibilityIdentifier("ai.model")
                Text("Empty lets the server choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.preferences.httpCloud {
                keyRows(model: model)
            }
        } header: {
            Text("The server")
        }
    }

    /// **The cloud key's four states** (ADR-0021 d.3): paste once, then Test, Replace or Remove. The Keychain holds it;
    /// nothing here writes it anywhere else.
    @ViewBuilder private func keyRows(model: AISettingsModel) -> some View {
        @Bindable var model = model
        switch model.keyState {
        case .absent:
            SecureField(text: $model.draftKey) { Text("Key") }
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai.key")
            Button("Save Key") { model.saveKey() }  // placement: form-pane
                .disabled(model.draftKey.isEmpty)
                .accessibilityIdentifier("ai.key.save")
        case .stored:
            Label {
                Text("Stored in the Keychain")
            } icon: {
                Image(systemName: "checkmark.seal")
            }
            keyButtons(model: model)
        case .testing:
            HStack(spacing: Tokens.Space.xs) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .failed(let error):
            Label {
                Text(MeaningSentences.provider(error))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            keyButtons(model: model)
        }
        if let failure = model.keyFailure {
            Text(failure).foregroundStyle(.red).font(.caption)
        }
    }

    private func keyButtons(model: AISettingsModel) -> some View {
        HStack(spacing: Tokens.Space.s) {
            Button("Test") { Task { await model.testKey() } }  // placement: form-pane
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
                let login = model.login
                ActionRow {
                    HStack(spacing: Tokens.Space.xs) {
                        ProgressView().controlSize(.small)  // placement: spinner
                        Text("Waiting for you to sign in…")
                    }
                } actions: {
                    Button("Cancel") { model.cancelSignIn() }  // placement: form-pane
                        .accessibilityIdentifier("ai.codex.cancel")
                }
                if let url = login.url {
                    ActionRow {
                        Text(verbatim: url.host() ?? url.absoluteString).foregroundStyle(.secondary)
                    } actions: {
                        Button("Open Sign-In Page") { _ = NSWorkspace.shared.open(url) }  // placement: form-pane
                            .accessibilityIdentifier("ai.codex.open")
                    }
                }
                if let code = login.code {
                    ActionRow {
                        LabeledContent {
                            Text(verbatim: code).font(.title3.monospaced()).textSelection(.enabled)
                                .accessibilityIdentifier("ai.codex.code")
                        } label: {
                            Text("Code")
                        }
                    } actions: {
                        Button("Copy Code") {  // placement: form-pane
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        .accessibilityIdentifier("ai.codex.copy")
                    }
                }
                if !model.loginLines.isEmpty {
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

    private var claudeSection: some View {
        Section {
            Text("Run claude in Terminal once to sign in. XDict never reads that sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude")
        }
    }

    // MARK: - What leaves XDict

    private func disclosureSection(model: AISettingsModel) -> some View {
        Section {
            Toggle(isOn: Binding(get: { model.preferences.settings.sendEntryText },
                                 set: { on in model.preferences.update { $0.sendEntryText = on } })) {
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
        @Bindable var model = model
        return Group {
            Section {
                Picker(selection: Binding(get: { model.preferences.settings.language },
                                          set: { language in
                                              model.preferences.update { $0.language = language }
                                              model.loadDraft()
                                          })) {
                    Text("English").tag("en")
                    Text("Simplified Chinese").tag("zh-Hans")
                } label: {
                    Text("Answer language")
                }
                .accessibilityIdentifier("ai.language")
                .settingsAnchor(.aiLanguage)
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
                            Label {
                                Text("Your wording, not measured")
                            } icon: {
                                Image(systemName: "pencil")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ai.prompt.edited.any")
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
        TextEditor(text: $model.draft)
            .font(.body.monospaced())
            .frame(minHeight: Tokens.Control.promptEditor)
            .accessibilityLabel(Text("Prompt"))
            .accessibilityIdentifier("ai.prompt.editor")
        if model.preferences.isEdited(language: model.language, mode: model.promptKind) {
            Label {
                Text("Your wording, not measured")
            } icon: {
                Image(systemName: "pencil")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai.prompt.edited")
        }
        Button("Reset to Default") { model.resetDraft() }  // placement: form-pane
            .disabled(!model.preferences.isEdited(language: model.language, mode: model.promptKind))
            .accessibilityIdentifier("ai.prompt.reset")
        Text("The prompt uses {term}, {sentence}, {entry}, {sense} and {language}; a missing or unknown one is refused before anything is sent. XDict appends the response format, which cannot be edited.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        DisclosureGroup {
            previewText(model: model)
            Text("This is a sample: the sentence you capture and the entry you see are sent instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Text("Preview the request")
        }
        .accessibilityIdentifier("ai.prompt.preview")
        DisclosureGroup {
            // **The chosen-sense kind has its own contract** (contract 3, §6a): showing the other one would
            // describe an answer this ask never accepts.
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
