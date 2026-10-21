import SwiftUI
import XDictAI
import XDictTokens

/// **AI, in Settings** (plan-ai-meaning WI-6; ADR-0021 d.12, d.13): the sources in the order of what it costs to set one
/// up, each with its caveat and a live local check; the one disclosure switch; the cloud key's four states; and the
/// prompt — shown, editable, previewed byte for byte, and resettable. The response contract is the app's, never edited.
public struct AISettings: View {
    @State private var model = AISettingsModel(preferences: .shared)

    public init() {}

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
                sourceRow(nil, title: LocalizedStringResource("Off"), identifier: "off")
                sourceRow(.appleOnDevice, identifier: "apple")
                sourceRow(.http, title: LocalizedStringResource("A local endpoint"), identifier: "local")
                sourceRow(.http, cloud: true, title: LocalizedStringResource("A cloud endpoint"), identifier: "cloud")
                sourceRow(.codexCLI, identifier: "codex")
                sourceRow(.claudeCLI, identifier: "claude")
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
    }

    // MARK: - Sources

    private func selected(_ kind: AIProviderKind?, cloud: Bool = false) -> Bool {
        guard model.preferences.settings.source == kind else { return false }
        if kind != .http { return true }
        return model.preferences.httpCloud == cloud
    }

    private func sourceRow(_ kind: AIProviderKind?, cloud: Bool = false, title: LocalizedStringResource? = nil,
                           identifier: String) -> some View {
        Button {  // placement: form-pane
            model.select(kind, cloud: cloud)
        } label: {
            HStack(alignment: .top, spacing: Tokens.Space.s) {
                Image(systemName: selected(kind, cloud: cloud) ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected(kind, cloud: cloud) ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    if let title {
                        Text(title)
                    } else if let name = MeaningSentences.source(kind) {
                        Text(name)
                    }
                    if let kind {
                        Text(kind == .http && cloud ? MeaningSentences.cloudCaveat : MeaningSentences.caveat(kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ai.source.\(identifier)")
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
                                        set: { text in model.preferences.update { $0.endpoint = URL(string: text) } }),
                          prompt: Text(verbatim: "http://127.0.0.1:11434/v1")) {
                    Text("Address")
                }
                .accessibilityIdentifier("ai.endpoint")
                Text("The server’s OpenAI-compatible base address, such as http://127.0.0.1:11434/v1 for Ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                TextField(text: Binding(get: { model.preferences.settings.model },
                                        set: { text in model.preferences.update { $0.model = text } })) {
                    Text("Model")
                }
                .accessibilityIdentifier("ai.model")
                Text("The model’s name at that server; empty lets the server choose.")
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
                Text("XDict is the only writer; the key never enters a preferences file.")
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

    private func codexSection(model: AISettingsModel) -> some View {
        Section {
            if model.signingIn {
                HStack(spacing: Tokens.Space.xs) {
                    ProgressView().controlSize(.small)  // placement: spinner
                    Text("Signing in…")
                }
                // The login's own lines: the address and the code the reader needs. Data, shown verbatim.
                ForEach(model.loginLines, id: \.self) { line in
                    Text(verbatim: line).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                Button("Sign In with Codex…") { Task { await model.signIn() } }  // placement: form-pane
                    .accessibilityIdentifier("ai.codex.signin")
                Text("XDict runs its own copy of the Codex tool in its own folder. If you have never signed in, this prints a web address and a code to enter there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Codex")
        }
    }

    private var claudeSection: some View {
        Section {
            Text("XDict runs the claude command with its own configuration folder. Run claude in Terminal once to sign in; Claude Code holds that sign-in and XDict never reads it.")
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
                Text("Off, only the sentence around the word is sent. One rule for every source: a server on this Mac is not an exception.")
            }
            .accessibilityIdentifier("ai.send-entry")
        } header: {
            Text("What leaves XDict")
        }
    }

    // MARK: - The prompt

    private func promptSection(model: AISettingsModel) -> some View {
        @Bindable var model = model
        return Section {
            Picker(selection: Binding(get: { model.preferences.settings.language },
                                      set: { language in
                                          model.preferences.update { $0.language = language }
                                          model.loadDraft()
                                      })) {
                Text("English").tag("en")
                Text("Simplified Chinese").tag("zh-Hans")
            } label: {
                Text("Answer language")
                Text("The language the explanation is written in; the prompt’s default wording follows it.")
            }
            .accessibilityIdentifier("ai.language")
            Picker(selection: $model.promptKind) {
                Text("Grounded in the entry").tag(AIMode.grounded)
                Text("From the sentence alone").tag(AIMode.sentenceOnly)
            } label: {
                Text("Question kind")
                Text("Two prompts: one sends the entry’s text, the other only the sentence.")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("ai.prompt.kind")
            TextEditor(text: $model.draft)
                .font(.body.monospaced())
                .frame(minHeight: Tokens.Control.promptEditor)
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
                Text(verbatim: AIComposer.responseContract)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text("What XDict adds to every request")
            }
        } header: {
            Text("The prompt")
        } footer: {
            Text("The response format is appended by XDict and cannot be edited. The prompt uses {term}, {sentence}, {entry} and {language}; a missing or unknown one is refused before anything is sent.")
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
