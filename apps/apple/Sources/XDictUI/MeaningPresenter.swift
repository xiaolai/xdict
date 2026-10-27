import Foundation
import XDictAI
import XDictClient

/// **The next step a failure offers in the pane** (HIG audit 2026-10-23, UI15): a configuration the reader fixes in
/// Settings ▸ AI, or a transient failure worth another try. Opening Settings changes nothing there: turning the entry's
/// text on stays the reader's own act (ADR-0021 d.4).
public enum MeaningRecovery: Equatable, Sendable {
    case openAISettings
    case retry
}

/// **What the request itself carries into the pane** (audit round 2, 2026-10-25): the source, the chosen sense, the
/// dictionary it was clicked in, its cut, the sentence, and the evidence's source and target — one mapping from the
/// frozen `MeaningSent`, read by every presentation.
public struct MeaningRequestFacts: Equatable, Sendable {
    public let source: String?
    public let chosenSense: AISense?
    public let dictionaryName: String?
    public let senseCoverage: LocalizedStringResource?
    public let questionContext: MeaningContext?
    public let evidenceSource: String?
    public let evidenceTarget: MeaningTarget?
    /// The model the request named, when it named one: the note's provenance carries it (audit round 4).
    public let model: String?

    /// The request's own source when it has one: switching sources in Settings must not relabel an old answer. **The
    /// entry's and the sense's cuts are two facts** (contract 3, §4a): a whole entry can hold a partial sense.
    public init(sent: MeaningSent?, settings: MeaningSettings) {
        source = sent.map { MeaningSentences.frozenSource($0) }
            ?? MeaningSentences.source(settings.source, model: settings.model, host: settings.endpoint?.host())
        chosenSense = sent?.sense
        dictionaryName = sent?.dictionaryName
        senseCoverage = sent?.sense?.whole == false ? MeaningSentences.partialSense : nil
        questionContext = sent?.questionContext
        evidenceSource = sent?.target == nil ? nil : sent?.dictionaryName
        evidenceTarget = sent?.target
        model = sent?.model
    }

    /// A value a test or a caller builds by hand.
    public init(source: String? = nil, chosenSense: AISense? = nil, dictionaryName: String? = nil,
                senseCoverage: LocalizedStringResource? = nil, questionContext: MeaningContext? = nil,
                evidenceSource: String? = nil, evidenceTarget: MeaningTarget? = nil, model: String? = nil) {
        self.source = source
        self.chosenSense = chosenSense
        self.dictionaryName = dictionaryName
        self.senseCoverage = senseCoverage
        self.questionContext = questionContext
        self.evidenceSource = evidenceSource
        self.evidenceTarget = evidenceTarget
        self.model = model
    }
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

    /// **What the request itself carries into the pane**, built once from the frozen request.
    public let facts: MeaningRequestFacts
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
    /// **What the reader can do about a failure** (UI15); nil for an answer, or when nothing in the pane helps.
    public let recovery: MeaningRecovery?
    /// **The reader has chosen another sense since this answer** (UI23): the answer stays, labelled as the earlier one's.
    public let selectionMoved: Bool

    /// The request's facts, read through the presentation: the source's name, the sense the reader chose, the dictionary
    /// it was clicked in, its cut, the sentence, and the evidence's source and target.
    public var source: String? { facts.source }
    public var chosenSense: AISense? { facts.chosenSense }
    public var dictionaryName: String? { facts.dictionaryName }
    public var senseCoverage: LocalizedStringResource? { facts.senseCoverage }
    public var questionContext: MeaningContext? { facts.questionContext }
    public var evidenceSource: String? { facts.evidenceSource }
    public var evidenceTarget: MeaningTarget? { facts.evidenceTarget }

    /// **What Copy Answer puts on the pasteboard** (plan-companion WI-10): the explanation, then each quote it rests on,
    /// separated by a blank line — text, never markup, and nothing the pane does not show.
    public var copyText: String { answerText(separator: "\n\n") }

    /// The note's opening: the explanation, then each quote on its own line (audit round 4, 2026-10-25: one rule shared with
    /// Copy Answer, so the two cannot format the same answer differently).
    var noteBody: String { answerText(separator: "\n") }

    private func answerText(separator: String) -> String {
        ([explanation] + quotes.map { "“\($0)”" })
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    public init(facts: MeaningRequestFacts, grounding: Grounding, outcome: LocalizedStringResource?,
                coverage: LocalizedStringResource?, quotes: [String], explanation: String,
                problem: LocalizedStringResource?, code: String?, recovery: MeaningRecovery? = nil,
                selectionMoved: Bool = false) {
        self.facts = facts
        self.grounding = grounding
        self.outcome = outcome
        self.coverage = coverage
        self.quotes = quotes
        self.explanation = explanation
        self.problem = problem
        self.code = code
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
        // **The request's facts, built once** (audit round 2, 2026-10-25): the answer and failure paths read them from
        // the frozen request, so they cannot map the same fields differently.
        let facts = MeaningRequestFacts(sent: sent, settings: settings)
        switch state {
        case .idle, .asking, .preview:
            return nil
        case .answer(let answer, let mode):
            return MeaningPresentation(
                facts: facts,
                // The chosen-sense question sends the entry, so its answer is grounded like the model's own choice;
                // contract 6's two operations carry none, and say so in the same words a sentence-only ask does.
                grounding: mode.carriesEntry ? .grounded : .ungrounded,
                outcome: MeaningSentences.outcome(answer.outcome),
                coverage: mode.carriesEntry && sent?.complete == false ? MeaningSentences.partialEntry : nil,
                quotes: answer.quotes,
                // **A translation's answer is its translation** (contract 6 §5b): the same field the pane's Copy and
                // Save as Note read, so one rule formats every mode's answer.
                explanation: mode == .translate && answer.outcome == .translated
                    ? (answer.translation ?? "") : answer.explanation,
                problem: nil,
                code: nil,
                selectionMoved: moved(sent: sent, mode: mode, selection: selection))
        case .template(let error):
            return problem(MeaningSentences.compose(error), code: error.code, facts: facts,
                           recovery: recovery(for: error))
        case .invalid(let error):
            return problem(MeaningSentences.invalidAnswer, code: error.code, facts: facts, recovery: .retry)
        case .unavailable(let unavailable):
            let code: String?
            if case .provider(let error) = unavailable { code = error.code } else { code = nil }
            return problem(MeaningSentences.problem(unavailable), code: code, facts: facts,
                           recovery: recovery(unavailable))
        case .cancelled:
            return problem(MeaningSentences.cancelled, code: nil, facts: facts, recovery: .retry)
        }
    }

    /// **The note an explicit save writes** (plan-companion WI-9; owner, 2026-10-25): the explanation, each quote on its
    /// own line in the pane's quotation marks, then a provenance line naming the source, the model when one was named, and
    /// that a model wrote the wording. **Everything comes from the presentation's frozen facts** (audit round 4): a request
    /// started while a save waits cannot pair its source with the old explanation. The sentence is never part of it; the day
    /// is the UTC calendar day, so a test can read it.
    public static func noteText(presentation: MeaningPresentation, date: Date,
                                translate: (LocalizedStringResource) -> String = { String(localized: $0) }) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let source = presentation.facts.source ?? String(localized: MeaningSentences.anAISource)
        let provenance = translate(MeaningSentences.noteProvenance(source: source,
                                                                   model: presentation.facts.model, day: day))
        return ([presentation.noteBody] + [provenance]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The answer was about a chosen sense, and the reader's choice is now **another** sense. Nil is not "moved": the
    /// label says "You have chosen another sense since", which would be false when none is chosen, and the answer already
    /// names its own sense (`chosenSense`). `clearingTheChosenSenseKeepsTheAnswer` pins this (audit round 1, 2026-10-25).
    private static func moved(sent: MeaningSent?, mode: AIMode, selection: MeaningSelection?) -> Bool {
        guard mode == .explainSense, let sense = sent?.sense else { return false }
        guard let selection else { return false }
        if selection.sense != sense.id { return true }
        guard let target = sent?.target else { return false }
        return target.dictionary != selection.dictionary || target.entry != selection.entry
    }

    /// **A settings problem goes to Settings** (audit round 3, 2026-10-25): a placeholder's name, its presence, its size
    /// or its kind is fixed in the template; a question refused for its input — a required entry or sense, a sense range
    /// the entry does not hold, a question over its ceiling — has no setting to change, and a button would loop.
    static func recovery(for error: AIComposeError) -> MeaningRecovery? {
        switch error {
        case .unknownPlaceholder, .missingPlaceholder, .entryInSentenceOnly, .entryWithoutEntry,
             .senseOutsideExplainSense, .templateTooLong:
            .openAISettings
        case .questionTooLong, .entryRequired, .senseRequired, .senseTextMismatch:
            nil
        }
    }

    /// **The next step for a missing answer** (UI15): configuration goes to Settings ▸ AI, a transient failure is
    /// retried, and what the pane cannot help with offers nothing rather than a button that loops.
    static func recovery(_ unavailable: MeaningSession.Unavailable) -> MeaningRecovery? {
        switch unavailable {
        case .noSource, .entryTextOff, .consentChanged: .openAISettings
        case .noContext, .noEntry, .noSense: nil
        case .entryFailure(let failure):
            // **A transport or a superseded call is worth another ask**; a file or an import problem is not.
            switch failure {
            case .wire, .superseded: .retry
            case .fileUnavailable, .reopenNeedsImport, .needsFiles: nil
            }
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
                                facts: MeaningRequestFacts, recovery: MeaningRecovery?) -> MeaningPresentation {
        MeaningPresentation(facts: facts, grounding: .none, outcome: nil, coverage: nil, quotes: [],
                            explanation: "", problem: problem, code: code, recovery: recovery)
    }
}
