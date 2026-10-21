import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// The eight outcomes as a guided type: the model may generate only these (`CONTRACT.md` §5).
@Generable
enum AppleAnswerOutcome: String, CaseIterable {
    case matched
    case ambiguous
    case noMatchingSense
    case insufficientContext
    case incompleteInput
    case explanationOnly
    case refused
    case guardrail
}

/// **The contract's answer, generated into fields** (ADR-0021 d.2): the sense quoted from the entry, one sentence, and
/// one of the eight outcomes. The validator, not the model, decides whether the quote is in the text that was sent.
@Generable
struct AppleAnswer {
    @Guide(description: "One of the eight outcomes: matched, ambiguous, noMatchingSense, insufficientContext, incompleteInput, explanationOnly, refused, guardrail.")
    let outcome: AppleAnswerOutcome
    @Guide(description: "The exact text of the dictionary sense, copied character for character from the entry: one quote for matched, two or three for ambiguous, none for any other outcome.")
    let quotes: [String]
    @Guide(description: "One sentence without a line break.")
    let explanation: String
}
#endif

/// **Apple's on-device model as a provider** (ADR-0021 d.3): free and private where it exists, about 4B and weaker than
/// the hosted models, and available only on an eligible Mac with Apple Intelligence on. It never falls back to another
/// provider: a refusal or an unavailable model is the answer the reader gets.
public struct AppleOnDeviceProvider: AIProvider {
    public let id = AIProviderID(kind: .appleOnDevice)

    public init() {}

    /// What Apple reports here and now, mapped to our own closed set.
    public static func availability() -> AppleAvailability {
        #if canImport(FoundationModels)
        return mapped(SystemLanguageModel.default.availability)
        #else
        return .unknown
        #endif
    }

    public func answer(to question: String) async throws(AIProviderError) -> String {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if case .unavailable(let reason) = model.availability {
            throw .unavailable(Self.mappedReason(reason))
        }
        // **The context is checked before the ask** (measured 2026-10-20: a 263 KiB question took 24–26 s to fail on the
        // 8,192-token window). The count is the model's own; a count that cannot be taken leaves the ask to fail typed.
        if let tokens = try? await model.tokenCount(for: question), tokens > model.contextSize {
            throw .contextExceeded
        }
        // One session per ask: no history between questions (`CONTRACT.md` §8.3; ADR-0021 d.8). **Guided generation**
        // (ADR-0021 d.2): the answer is generated into the contract's fields, not asked for as prose that happens to be
        // JSON — measured 2026-10-20, free-form answers failed the shape check in 19 of 24 entries.
        let session = LanguageModelSession(model: model)
        do {
            let response = try await session.respond(to: question, generating: AppleAnswer.self,
                                                     options: GenerationOptions(temperature: 0))
            return try Self.json(response.content)
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded: throw .contextExceeded
            case .refusal, .guardrailViolation: throw .guardrail
            default: throw .framework(Self.scrubbed(error, question: question))
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .framework(Self.scrubbed(error, question: question))
        }
        #else
        throw .unavailable(.unknown)
        #endif
    }

    /// The generated answer as the contract's JSON: the one shape every provider returns to the validator.
    static func json(_ answer: AppleAnswer) throws(AIProviderError) -> String {
        let object: [String: Any] = ["outcome": answer.outcome.rawValue, "quotes": answer.quotes,
                                     "explanation": answer.explanation]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw .badShape
        }
        return String(decoding: data, as: UTF8.self)
    }

    #if canImport(FoundationModels)
    static func mapped(_ availability: SystemLanguageModel.Availability) -> AppleAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return mappedReason(reason)
        @unknown default:
            return .unknown
        }
    }

    static func mappedReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AppleAvailability {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unknown
        }
    }
    #endif

    /// A framework message with the question cut out of it and bounded — a framework may echo the prompt, and a log line
    /// is not the place for the reader's sentence.
    static func scrubbed(_ error: any Error, question: String) -> String {
        var text = String(describing: error)
        if !question.isEmpty {
            text = text.replacingOccurrences(of: question, with: "<question>")
        }
        return String(text.prefix(200))
    }
}
