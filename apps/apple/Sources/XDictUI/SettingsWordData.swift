import SwiftUI
import XDictContract
import XDictSearch
import XDictTokens

/// **Settings ▸ Dictionaries ▸ Word data** (plan-word-exploration WI-5): the pack the rhymes, families, roots, forms,
/// synonyms and antonyms read, installed from a file the reader chooses, and removed. One line says what is installed —
/// version, records, sources — or which modes wait on it; a refusal sits under it in the reader's language.
///
/// The pack is not a dictionary: it never appears in the table, it is not in lookup, and removing it changes no
/// dictionary. The row says all three by what it does not offer.
public struct SettingsWordData: View {
    private let model: WordDataModel
    private let choose: () -> Void

    public init(model: WordDataModel, choose: @escaping () -> Void) {
        self.model = model
        self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Text(WordDataSentences.title)
                .font(.headline)
            ActionRow(.pane) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    sentence
                    bar
                }
            } actions: {
                if model.isWorking {
                    Button(role: .cancel) { model.cancelBuild() } label: { Text(WordDataSentences.cancel) }
                        .accessibilityIdentifier("settings.worddata.cancel")
                } else if case .installed = model.state {
                    Button(role: .destructive) { Task { await model.remove() } } label: { Text(WordDataSentences.remove) }
                        .disabled(model.busy)
                        .accessibilityIdentifier("settings.worddata.remove")
                } else {
                    Button { Task { await model.buildFromSources() } } label: { Text(WordDataSentences.build) }
                        .disabled(model.busy)
                        .accessibilityIdentifier("settings.worddata.build")
                    Button(action: choose) { Text(WordDataSentences.choose) }
                        .disabled(model.busy)
                        .accessibilityIdentifier("settings.worddata.choose")
                }
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Rectangle().strokeBorder(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.worddata")
    }

    /// What the row says, in the reader's language: the state's sentence, and what is installed under it.
    @ViewBuilder private var sentence: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            line(text, symbol: symbol)
            if case .installed(let pack) = model.state {
                Text(WordDataSentences.summary(pack))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The sentence of the state now shown.
    private var text: LocalizedStringResource {
        switch model.state {
        case .unknown, .absent: WordDataSentences.absent
        case .downloading(let progress): WordDataSentences.downloading(progress)
        case .building(let progress): WordDataSentences.building(progress)
        case .installed: WordDataSentences.installed
        case .refused(let refusal): WordDataSentences.sentence(refusal)
        case .trouble(let trouble): WordDataSentences.sentence(trouble)
        }
    }

    /// A refusal and a trouble wear the warning symbol; an installed or absent pack the information one.
    private var symbol: String {
        switch model.state {
        case .refused, .trouble: "exclamationmark.triangle"
        default: "info.circle"
        }
    }

    /// **How far the work has got, under its sentence** (2026-10-31): a determinate bar where the amount is known, and
    /// a moving one where it is not — never a bar at zero while the download or the build is under way. Nothing once
    /// the pack is installed or a failure's sentence takes the progress's place.
    @ViewBuilder private var bar: some View {
        if model.phase != nil {
            ProgressBarView(bar: ProgressBar.of(fraction: model.fraction))
                .accessibilityIdentifier("settings.worddata.progress")
        }
    }

    private func line(_ text: LocalizedStringResource, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}
