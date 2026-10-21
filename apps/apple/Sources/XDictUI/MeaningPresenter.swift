import Foundation
import XDictAI

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

    public init(source: LocalizedStringResource?, grounding: Grounding, outcome: LocalizedStringResource?,
                coverage: LocalizedStringResource?, quotes: [String], explanation: String,
                problem: LocalizedStringResource?, code: String?) {
        self.source = source
        self.grounding = grounding
        self.outcome = outcome
        self.coverage = coverage
        self.quotes = quotes
        self.explanation = explanation
        self.problem = problem
        self.code = code
    }

    public var isProblem: Bool { problem != nil }
}

/// **The state the session is in, said for the pane.** Idle and asking are not presentations: before an ask there is
/// nothing to show, and while one runs the pane shows its own progress.
public enum MeaningPresenter {
    public static func present(_ state: MeaningSession.State, settings: MeaningSettings,
                               sent: MeaningSent?) -> MeaningPresentation? {
        // The request's own source when it has one: switching sources in Settings must not relabel an old answer.
        let source = MeaningSentences.source(sent?.source ?? settings.source)
        switch state {
        case .idle, .asking, .preview:
            return nil
        case .answer(let answer, let mode):
            return MeaningPresentation(
                source: source,
                grounding: mode == .grounded ? .grounded : .ungrounded,
                outcome: MeaningSentences.outcome(answer.outcome),
                coverage: mode == .grounded && sent?.complete == false ? MeaningSentences.partialEntry : nil,
                quotes: answer.quotes,
                explanation: answer.explanation,
                problem: nil,
                code: nil)
        case .template(let error):
            return problem(MeaningSentences.compose(error), code: error.code, source: source)
        case .invalid(let error):
            return problem(MeaningSentences.invalidAnswer, code: error.code, source: source)
        case .unavailable(let unavailable):
            let code: String?
            if case .provider(let error) = unavailable { code = error.code } else { code = nil }
            return problem(MeaningSentences.problem(unavailable), code: code, source: source)
        case .cancelled:
            return problem(MeaningSentences.cancelled, code: nil, source: source)
        }
    }

    private static func problem(_ problem: LocalizedStringResource, code: String?,
                                source: LocalizedStringResource?) -> MeaningPresentation {
        MeaningPresentation(source: source, grounding: .none, outcome: nil, coverage: nil, quotes: [],
                            explanation: "", problem: problem, code: code)
    }
}
