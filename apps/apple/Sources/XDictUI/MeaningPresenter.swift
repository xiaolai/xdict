import Foundation
import XDictAI

/// **The next step a failure offers in the pane** (HIG audit 2026-10-23, UI15): a configuration the reader fixes in
/// Settings ▸ AI, or a transient failure worth another try. Opening Settings changes nothing there: turning the entry's
/// text on stays the reader's own act (ADR-0021 d.4).
public enum MeaningRecovery: Equatable, Sendable {
    case openAISettings
    case retry
}

/// **What the answer pane shows, as values** (plan-ai-meaning WI-6; ADR-0021 d.1, d.2): the source, whether the answer is
/// grounded, the outcome word, the quoted sense or senses, the one-sentence explanation, a partial entry's warning, or
/// the typed reason nothing came back. Plain text only: the pane never renders the model's words as markup.
public struct MeaningPresentation: Equatable, Sendable {
    public enum Grounding: Equatable, Sendable {
        case none
        case grounded
        case ungrounded
    }

    /// The source's name; nil when the reader chose none.
    public let source: LocalizedStringResource?
    public let grounding: Grounding
    public let outcome: LocalizedStringResource?
    /// Set when the entry was cut before it was sent, so the answer may be missing what was not sent.
    public let coverage: LocalizedStringResource?
    /// The sense text, exactly as quoted from the entry.
    public let quotes: [String]
    public let explanation: String
    /// Why there is no answer, or what the model declined to answer.
    public let problem: LocalizedStringResource?
    /// The stable contract code behind a failure (`provider.unauthorised`, `answer.quote.notFound`), shown small.
    public let code: String?
    /// **The sense the reader chose**, in the chosen-sense mode only: shown as printed, so the pane names the target it
    /// explains (plan-explain-sense WI-5).
    public let chosenSense: AISense?
    /// The dictionary the sense was clicked in, when the window knows its name.
    public let dictionaryName: String?
    /// Part of the chosen sense was not sent: the answer may be missing what was not.
    public let senseCoverage: LocalizedStringResource?
    /// **The sentence the request was about** (UI09), from the request itself.
    public let questionContext: MeaningContext?
    /// **Where the quoted evidence comes from** (UI11): the dictionary's name, and the entry to reveal it in.
    public let evidenceSource: String?
    public let evidenceTarget: MeaningTarget?
    /// **What the reader can do about a failure** (UI15); nil for an answer, or when nothing in the pane helps.
    public let recovery: MeaningRecovery?
    /// **The reader has chosen another sense since this answer** (UI23): the answer stays, labelled as the earlier one's.
    public let selectionMoved: Bool

    public init(source: LocalizedStringResource?, grounding: Grounding, outcome: LocalizedStringResource?,
                coverage: LocalizedStringResource?, quotes: [String], explanation: String,
                problem: LocalizedStringResource?, code: String?, chosenSense: AISense? = nil,
                dictionaryName: String? = nil, senseCoverage: LocalizedStringResource? = nil,
                questionContext: MeaningContext? = nil, evidenceSource: String? = nil, evidenceTarget: MeaningTarget? = nil,
                recovery: MeaningRecovery? = nil, selectionMoved: Bool = false) {
        self.source = source
        self.grounding = grounding
        self.outcome = outcome
        self.coverage = coverage
        self.quotes = quotes
        self.explanation = explanation
        self.problem = problem
        self.code = code
        self.chosenSense = chosenSense
        self.dictionaryName = dictionaryName
        self.senseCoverage = senseCoverage
        self.questionContext = questionContext
        self.evidenceSource = evidenceSource
        self.evidenceTarget = evidenceTarget
        self.recovery = recovery
        self.selectionMoved = selectionMoved
    }

    public var isProblem: Bool { problem != nil }
}

/// **The state the session is in, said for the pane.** Idle and asking are not presentations: before an ask there is
/// nothing to show, and while one runs the pane shows its own progress.
public enum MeaningPresenter {
    /// `selection` is the reader's current choice: an explain-sense answer about another one says so (UI23).
    public static func present(_ state: MeaningSession.State, settings: MeaningSettings,
                               sent: MeaningSent?, selection: MeaningSelection? = nil) -> MeaningPresentation? {
        // The request's own source when it has one: switching sources in Settings must not relabel an old answer.
        let source = MeaningSentences.source(sent?.source ?? settings.source)
        let chosen = sent?.sense
        // **The entry's and the sense's cuts are two facts** (contract 3, §4a): a whole entry can hold a partial sense.
        let senseCoverage = sent?.sense?.whole == false ? MeaningSentences.partialSense : nil
        switch state {
        case .idle, .asking, .preview:
            return nil
        case .answer(let answer, let mode):
            return MeaningPresentation(
                source: source,
                // The chosen-sense question sends the entry, so its answer is grounded like the model's own choice.
                grounding: mode == .sentenceOnly ? .ungrounded : .grounded,
                outcome: MeaningSentences.outcome(answer.outcome),
                coverage: mode != .sentenceOnly && sent?.complete == false ? MeaningSentences.partialEntry : nil,
                quotes: answer.quotes,
                explanation: answer.explanation,
                problem: nil,
                code: nil,
                chosenSense: chosen,
                dictionaryName: sent?.dictionaryName,
                senseCoverage: senseCoverage,
                questionContext: sent?.questionContext,
                evidenceSource: sent?.target == nil ? nil : sent?.dictionaryName,
                evidenceTarget: sent?.target,
                recovery: nil,
                selectionMoved: moved(sent: sent, mode: mode, selection: selection))
        case .template(let error):
            return problem(MeaningSentences.compose(error), code: error.code, source: source, sent: sent,
                           recovery: .openAISettings)
        case .invalid(let error):
            return problem(MeaningSentences.invalidAnswer, code: error.code, source: source, sent: sent,
                           recovery: .retry)
        case .unavailable(let unavailable):
            let code: String?
            if case .provider(let error) = unavailable { code = error.code } else { code = nil }
            return problem(MeaningSentences.problem(unavailable), code: code, source: source, sent: sent,
                           recovery: recovery(unavailable))
        case .cancelled:
            return problem(MeaningSentences.cancelled, code: nil, source: source, sent: sent, recovery: .retry)
        }
    }

    /// The answer was about a chosen sense, and the reader's choice is now another sense or none.
    private static func moved(sent: MeaningSent?, mode: AIMode, selection: MeaningSelection?) -> Bool {
        guard mode == .explainSense, let sense = sent?.sense else { return false }
        guard let selection else { return false }
        if selection.sense != sense.id { return true }
        guard let target = sent?.target else { return false }
        return target.dictionary != selection.dictionary || target.entry != selection.entry
    }

    /// **The next step for a missing answer** (UI15): configuration goes to Settings ▸ AI, a transient failure is
    /// retried, and what the pane cannot help with offers nothing rather than a button that loops.
    static func recovery(_ unavailable: MeaningSession.Unavailable) -> MeaningRecovery? {
        switch unavailable {
        case .noSource, .entryTextOff, .consentChanged: .openAISettings
        case .noContext, .noEntry, .entryUnreadable, .noSense: nil
        case .provider(let error): recovery(error)
        }
    }

    static func recovery(_ error: AIProviderError) -> MeaningRecovery? {
        switch error {
        case .insecureEndpoint, .redirectRefused, .unauthorised, .modelNotFound, .notInstalled, .notSignedIn,
             .versionTooOld, .unsupportedAuth, .unavailable, .contextExceeded:
            .openAISettings
        case .unreachable, .rateLimited, .truncated, .badShape, .timeout, .cancelled, .framework:
            .retry
        case .server(let status, _):
            // A refused request is usually a setting to change (a model name, a balance, a parameter); a server-side
            // failure is worth one more try.
            (400..<500).contains(status) ? .openAISettings : .retry
        case .refused, .guardrail:
            nil
        }
    }

    private static func problem(_ problem: LocalizedStringResource, code: String?,
                                source: LocalizedStringResource?, sent: MeaningSent?,
                                recovery: MeaningRecovery?) -> MeaningPresentation {
        MeaningPresentation(source: source, grounding: .none, outcome: nil, coverage: nil, quotes: [],
                            explanation: "", problem: problem, code: code, chosenSense: sent?.sense,
                            dictionaryName: sent?.dictionaryName,
                            senseCoverage: sent?.sense?.whole == false ? MeaningSentences.partialSense : nil,
                            questionContext: sent?.questionContext, recovery: recovery)
    }
}
