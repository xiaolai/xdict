import SwiftUI
import XDictAI
import XDictEntryView
import XDictTokens

/// **The answer to one "meaning here" tap** (plan-ai-meaning WI-6; ADR-0021 d.1, d.2): the source, whether the answer is
/// grounded, the outcome, the quoted sense or senses — each findable in the entry — the one-sentence explanation, a
/// partial entry's warning, and the exact request that was sent. Plain text only: the model's words are never rendered
/// as markup.
public struct MeaningAnswerPane: View {
    let state: SearchWindowState
    @State private var promptShown = false

    public init(state: SearchWindowState) {
        self.state = state
    }

    public var body: some View {
        // **The pane's content is capped at the inspector's declared minimum.** macOS 27 proposes the inspector's content
        // a container wider than the visible column, so content laid out to the proposal is drawn past the pane's edge
        // and clipped — plain text and a scroll view alike (tour `main.meaningPreview`, three renders, 2026-10-20). The
        // cap is the width the inspector promises; a wider column shows the content left-aligned inside it.
        ScrollView {
            content
                .padding(Tokens.Space.l)
                .frame(maxWidth: Tokens.Window.meaningPaneMin, alignment: .leading)
        }
        .accessibilityIdentifier("meaning.pane")
    }

    private var settings: MeaningSettings {
        state.meaning.settingsProvider?() ?? state.meaning.settings
    }

    @ViewBuilder private var content: some View {
        switch state.meaning.state {
        case .idle:
            ContentUnavailableView {
                Label("No Answer Yet", systemImage: "sparkles")
            } description: {
                Text("Capture a word and choose Meaning Here beside it. XDict asks the source you chose what the word means in that sentence.")
            }
        case .asking:
            asking
        case .preview(let sent):
            preview(sent)
        default:
            if let presentation = MeaningPresenter.present(state.meaning.state, settings: settings,
                                                           sent: state.meaning.sent) {
                answer(presentation)
            }
        }
    }

    /// **What the ask will send, before it is sent** (ADR-0021 d.13): the composed request, byte for byte, and the cut
    /// if the entry exceeded the budget. Send composes again (the same bytes) and asks; Cancel sends nothing.
    private func preview(_ sent: MeaningSent) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("This is what will be sent")
                .font(.headline)
            if let source = MeaningSentences.source(settings.source) {
                Text("To “\(source)”").font(.caption).foregroundStyle(.secondary)
            }
            if let sense = sent.sense {
                chosenSense(sense, dictionary: sent.dictionaryName)
            }
            PromptText(text: sent.text)
                .accessibilityIdentifier("meaning.preview.text")
            if !sent.complete {
                Text("The entry was cut at \(sent.cutAt) bytes, so only the part before that was sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Tokens.Space.s) {
                Button("Send") { state.meaning.ask() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.send")
                Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
            }
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.s) {
                ProgressView().controlSize(.small)  // placement: spinner
                if let source = MeaningSentences.source(state.meaning.settingsProvider?().source
                                                        ?? state.meaning.settings.source) {
                    Text("Asking “\(source)”…")
                } else {
                    Text("Asking…")
                }
            }
            Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
                .accessibilityIdentifier("meaning.cancel")
        }
    }

    @ViewBuilder private func answer(_ presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            if let source = presentation.source {
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = presentation.problem {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: presentation.grounding == .none ? "exclamationmark.triangle" : "info.circle")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("meaning.problem")
            }
            if let outcome = presentation.outcome {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                    Text(outcome).font(.headline)
                    if let grounding = MeaningSentences.grounding(presentation.grounding) {
                        Text(grounding).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let coverage = presentation.coverage {
                Label { Text(coverage) } icon: { Image(systemName: "scissors") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.coverage")
            }
            if let sense = presentation.chosenSense {
                chosenSense(sense, dictionary: presentation.dictionaryName)
            }
            if let coverage = presentation.senseCoverage {
                Label { Text(coverage) } icon: { Image(systemName: "scissors") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.sense.coverage")
            }
            ForEach(presentation.quotes, id: \.self) { quote in
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(verbatim: quote)
                        .font(.body.italic())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("meaning.quote")
                    Button("Show in the Entry") {  // placement: inspector-row
                        _ = state.entry.performFind(quote)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("meaning.show-in-entry")
                }
            }
            if !presentation.explanation.isEmpty {
                Text(verbatim: presentation.explanation)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("meaning.explanation")
            }
            if let code = presentation.code {
                Text(verbatim: code).font(.caption).foregroundStyle(.tertiary)
            }
            if let sent = state.meaning.sent {
                DisclosureGroup(isExpanded: $promptShown) {
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        PromptText(text: sent.text)
                        if !sent.complete {
                            Text("The entry was cut at \(sent.cutAt) bytes, so only the part before that was sent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("View the Prompt")
                }
                .accessibilityIdentifier("meaning.prompt")
            }
            if case .answer(let answer, mode: .explainSense) = state.meaning.state, answer.outcome == .doesNotFit {
                // **The verdict is not the end of the question** (plan-explain-sense WI-5): the model can be asked
                // which sense the sentence uses instead, on the same sentence and entry.
                Text(MeaningSentences.doesNotFitOffer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ask Which Sense It Is") {  // placement: inspector-row
                    state.meaning.askSelection()
                }
                .accessibilityIdentifier("meaning.selection-ask")
            }
            if state.meaning.canAsk {
                Button("Ask Again") { state.meaning.askAgain() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.again")
            }
        }
    }

    /// **The sense as printed** (plan-explain-sense WI-5): its label and its text, verbatim from the core's projection,
    /// and the dictionary it was clicked in when that is not obvious.
    @ViewBuilder private func chosenSense(_ sense: AISense, dictionary: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text(MeaningSentences.chosenSense).font(.caption).foregroundStyle(.secondary)
            if let label = sense.label, !label.isEmpty {
                Text(verbatim: label).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(verbatim: sense.text)
                .textSelection(.enabled)
                .accessibilityIdentifier("meaning.sense")
            if let dictionary {
                Text(verbatim: dictionary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// **The exact request, scrollable and verbatim** (ADR-0021 d.13): the response contract's JSON line has no spaces to
/// wrap at, and the inspector proposes its content a container wider than the visible column, so plain `Text` was drawn
/// past the pane's edge and clipped (tour `main.meaningPreview`, 2026-10-20). Two scrollers keep every byte reachable
/// without changing it.
struct PromptText: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Tokens.Control.promptEditor)
        .accessibilityIdentifier("meaning.prompt.text")
    }
}

/// **"Meaning here" on the presented term** (ADR-0021 d.1): a tap, never automatic. The popover expands into the window
/// it hands the sentence to; the main window opens the answer pane in place.
struct MeaningAskButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {  // placement: meaning-chip
            action()
        } label: {
            Label("Meaning Here", systemImage: "sparkles")
        }
        .disabled(!enabled)
        .help("Ask the source you chose what this word means in this sentence.")
        .accessibilityIdentifier("meaning.ask")
    }
}
