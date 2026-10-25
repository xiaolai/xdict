import AppKit
import SwiftUI
import XDictAI
import XDictCapture
import XDictEntryView
import XDictTokens

/// **The answer to one "meaning here" tap** (plan-ai-meaning WI-6; ADR-0021 d.1, d.2; HIG audit 2026-10-23): the task's
/// title, the sentence the request was about, the explanation first, then the dictionary text it quotes with the
/// dictionary named, and the request's and an error's technical details behind disclosures. Plain text only: the
/// model's words are never rendered as markup.
public struct MeaningAnswerPane: View {
    let state: SearchWindowState
    /// The sheet shows the pane's title and source above the answer; the pane window does not (owner, 2026-10-24:
    /// its own top area is redundant — ⌘I toggles it).
    let showsHeader: Bool
    @State private var promptShown = false
    @State private var detailsShown = false
    /// The visible column's width, measured (UI04); nil until the first measurement.
    @State private var visible: CGFloat?
    /// A reveal that found nothing on the page shown now (UI11).
    @State private var revealFailed: String?

    public init(state: SearchWindowState, showsHeader: Bool = true) {
        self.state = state
        self.showsHeader = showsHeader
    }

    public var body: some View {
        // **The content follows the visible column** (UI04). macOS 27 proposes the inspector's content a container wider
        // than the visible column, so content laid out to the proposal was drawn past the pane's edge and clipped (tour
        // `main.meaningPreview`, 2026-10-20); the fix then capped it at the inspector's minimum, which left a widened
        // pane's room empty. The width is now measured where it is drawn — the part of the pane the window shows — and
        // held within the inspector's declared bounds.
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                // **The Examples section lives in this pane** (ADR-0031's owner decision, plan-reverse-examples
                // WI-5): above the Meaning answer when both are shown, alone when only a Chinese query opened it.
                if state.panes.examplesShown {
                    ExamplesSection(state: state)
                }
                if state.panes.meaningShown || !state.panes.examplesShown {
                    if showsHeader { header }
                    content
                }
            }
            .padding(Tokens.Space.l)
            .frame(width: MeaningPaneWidth.content(visible: visible), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background { VisibleWidth { visible = $0 } }
        .accessibilityIdentifier("meaning.pane")
    }

    private var settings: MeaningSettings {
        state.meaning.settingsProvider?() ?? state.meaning.settings
    }

    /// **The pane's purpose before any answer** (UI17): the task's title; the source is secondary.
    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(MeaningSentences.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let source = MeaningSentences.source(state.meaning.sent?.source ?? settings.source) {
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("meaning.title")
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
                                                           sent: state.meaning.sent,
                                                           selection: state.meaning.selection) {
                answer(presentation)
            }
        }
    }

    /// **What the ask will send, before it is sent** (ADR-0021 d.13; UI14): who receives it, the sentence, whether the
    /// entry goes, and a cut in the future tense (UI19); the exact bytes behind a disclosure, copyable. Send composes
    /// nothing new (the same bytes) and asks; Cancel sends nothing.
    private func preview(_ sent: MeaningSent) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Review before sending")
                .font(.subheadline.weight(.semibold))
            if let source = MeaningSentences.source(settings.source) {
                Text("To “\(source)”")
            }
            if let context = sent.questionContext {
                MeaningContextView(context: context)
            }
            Text(MeaningSentences.previewEntry(included: sent.mode != .sentenceOnly))
                .foregroundStyle(.secondary)
            if let sense = sent.sense {
                chosenSense(sense, dictionary: sent.dictionaryName)
            }
            if !sent.complete {
                Text(MeaningSentences.cut(at: sent.cutAt, sent: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $promptShown) {
                exactRequest(sent.text)
                    .accessibilityIdentifier("meaning.preview.text")
            } label: {
                Text("Exact Request")
            }
            HStack(spacing: Tokens.Space.sm) {
                Button("Send") { state.meaning.sendPreview() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.send")
                Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
            }
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.s) {
                ProgressView().controlSize(.small)  // placement: spinner
                if let source = MeaningSentences.source(settings.source) {
                    Text("Asking “\(source)”…")
                } else {
                    Text("Asking…")
                }
            }
            if let context = state.meaning.held.map(MeaningContext.init) {
                MeaningContextView(context: context)
            }
            Button("Cancel") { state.meaning.cancel() }  // placement: inspector-row
                .accessibilityIdentifier("meaning.cancel")
        }
    }

    @ViewBuilder private func answer(_ presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            if let context = presentation.questionContext {
                MeaningContextView(context: context)
            }
            if let problem = presentation.problem {
                problemView(problem, presentation: presentation)
            }
            if presentation.selectionMoved {
                Label { Text(MeaningSentences.selectionMoved) } icon: { Image(systemName: "arrow.uturn.backward") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.selection-moved")
            }
            if let outcome = presentation.outcome {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text(outcome).font(.subheadline.weight(.semibold))
                    if let grounding = MeaningSentences.grounding(presentation.grounding) {
                        Text(grounding).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // **The answer to the reader's question first** (UI10), then the source text it rests on.
            if !presentation.explanation.isEmpty {
                Text(verbatim: presentation.explanation)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meaning.explanation")
                Label { Text(MeaningSentences.generated) } icon: { Image(systemName: "sparkles") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.generated")
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
            if !presentation.quotes.isEmpty {
                evidence(presentation)
            }
            if let coverage = presentation.coverage {
                Label { Text(coverage) } icon: { Image(systemName: "scissors") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meaning.coverage")
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
            if let sent = state.meaning.sent {
                DisclosureGroup(isExpanded: $promptShown) {
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        exactRequest(sent.text)
                        if !sent.complete {
                            Text(MeaningSentences.cut(at: sent.cutAt, sent: true))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Request Details")
                }
                .accessibilityIdentifier("meaning.prompt")
            }
            // A failure's own recovery replaces Ask Again (UI15): two buttons for one retry read as two actions.
            if state.meaning.canAsk, presentation.recovery == nil {
                Button("Ask Again") { state.meaning.askAgain() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.again")
            }
        }
    }

    /// **The plain problem, its next step, then the code** (UI15, UI20): an ordinary reader acts on the first two; the
    /// code is for support, behind a disclosure with Copy Details.
    private func problemView(_ problem: LocalizedStringResource, presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Label {
                Text(problem)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("meaning.problem")
            switch presentation.recovery {
            case .openAISettings:
                Button("Open AI Settings…") { SettingsRoute.shared.showPane(.ai) }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.recover.settings")
            case .retry:
                Button("Try Again") { state.meaning.askAgain() }  // placement: inspector-row
                    .accessibilityIdentifier("meaning.recover.retry")
            case nil:
                EmptyView()
            }
            if let code = presentation.code {
                DisclosureGroup(isExpanded: $detailsShown) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
                        Text(verbatim: code).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy Details") {  // placement: inspector-row
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MeaningSentences.errorDetails(code: code), forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                } label: {
                    Text("Error Details").font(.caption)
                }
                .accessibilityIdentifier("meaning.error-details")
            }
        }
    }

    /// **The dictionary text the answer quotes, with its dictionary** (UI10, UI11): after the explanation, each quote
    /// one step from its place in the entry; a reveal that finds nothing says so.
    private func evidence(_ presentation: MeaningPresentation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                Text(MeaningSentences.evidence)
                if let name = presentation.evidenceSource {
                    Text(verbatim: "· \(name)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meaning.evidence.source")
            ForEach(presentation.quotes, id: \.self) { quote in
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(verbatim: quote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meaning.quote")
                    Button("Show in the Entry") {  // placement: inspector-row
                        reveal(quote, in: presentation.evidenceTarget)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("meaning.show-in-entry")
                    if revealFailed == quote {
                        Text(MeaningSentences.revealFailed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("meaning.reveal-failed")
                    }
                }
            }
        }
    }

    private func reveal(_ quote: String, in target: MeaningTarget?) {
        revealFailed = nil
        let found = state.revealEvidence(quote, target: target)
        Task { @MainActor in
            if await found.value == false { revealFailed = quote }
        }
    }

    /// The exact bytes, scrollable, and a Copy button: what a careful reader or support needs, one step away (UI14).
    private func exactRequest(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            PromptText(text: text)
            Button("Copy Request") {  // placement: inspector-row
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.caption)
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
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meaning.sense")
            if let dictionary {
                Text(verbatim: dictionary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// **The sentence a request is about, the word emphasized** (UI09): an ellipsis says where the capture cut it.
struct MeaningContextView: View {
    let context: MeaningContext

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(MeaningSentences.contextHeading).font(.caption).foregroundStyle(.secondary)
            Text(Self.attributed(context))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meaning.context")
    }

    /// The sentence with the term strongly emphasized at its range, and an ellipsis at each end the capture cut.
    static func attributed(_ context: MeaningContext) -> AttributedString {
        var sentence = AttributedString(context.sentence)
        if let range = context.range, let found = Range(range, in: context.sentence),
           let marked = Range<AttributedString.Index>(found, in: sentence) {
            sentence[marked].inlinePresentationIntent = .stronglyEmphasized
        }
        var out = AttributedString()
        if context.cut.contains(.start) { out += AttributedString("…") }
        out += sentence
        if context.cut.contains(.end) { out += AttributedString("…") }
        return out
    }
}

/// **The answer pane's width** (UI04): the visible column's, within the inspector's declared bounds — the promised
/// minimum until it is measured, never wider than the declared maximum.
enum MeaningPaneWidth {
    static let minimum = Tokens.Window.meaningPaneMin
    static let maximum = Tokens.Window.meaningPaneMax

    static func content(visible: CGFloat?) -> CGFloat {
        guard let visible else { return minimum }
        return min(max(visible, minimum), maximum)
    }
}

/// **The width of the part of a view the window shows** (UI04): its frame clipped by its ancestors and by the window's
/// content, measured in AppKit, where the clipping happens, not taken from SwiftUI's proposal.
struct VisibleWidth: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: NSView {
        var changed: ((CGFloat) -> Void)?
        private var last: CGFloat?
        private var pending = false

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                // **The window's own resizes count** (owner, 2026-10-24): the drawer grows the pane window after this
                // view's layout, and without this the last width measured was a narrow intermediate one — the content
                // then sat at its minimum with a wide empty margin beside it.
                for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                                                           name: name, object: window)
                }
            }
            scheduleMeasurement()
        }

        @objc private func windowChanged(_ notification: Notification) { scheduleMeasurement() }

        private func scheduleMeasurement() {
            guard !pending else { return }
            pending = true
            // A synchronous callback mutates the SwiftUI state that sizes this very view during native layout.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.measure()
            }
        }

        private func measure() {
            guard let window, let content = window.contentView else { return }
            let inWindow = convert(visibleRect, to: nil)
            let shown = inWindow.intersection(content.convert(content.bounds, to: nil))
            guard !shown.isNull, shown.width > 0 else { return }
            let width = shown.width.rounded(.down)
            guard width != last else { return }
            last = width
            changed?(width)
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
