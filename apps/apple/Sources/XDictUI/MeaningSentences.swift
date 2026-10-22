import Foundation
import XDictAI

/// **What the AI pane tells the reader, in their language** (plan-ai-meaning WI-6; ADR-0007 decision 10: the model hands
/// kinds, the view layer words them). Every sentence is in `Strings/Localizable.xcstrings`, in English and Simplified
/// Chinese.
public enum MeaningSentences {
    /// **The source's name**, as the reader chose it; nil when none is chosen.
    public static func source(_ kind: AIProviderKind?) -> LocalizedStringResource? {
        switch kind {
        case .none: nil
        case .appleOnDevice: LocalizedStringResource("Apple Intelligence")
        case .http: LocalizedStringResource("An OpenAI-compatible endpoint")
        case .claudeCLI: LocalizedStringResource("Claude")
        case .codexCLI: LocalizedStringResource("Codex")
        }
    }

    /// **Each source's caveat** (ADR-0021 d.3): what it costs, and what it cannot promise. Shown beside the choice.
    public static func caveat(_ kind: AIProviderKind) -> LocalizedStringResource {
        switch kind {
        case .appleOnDevice:
            LocalizedStringResource("Free and on this Mac. A small model — about 4 billion parameters — so answers may be weaker than a larger source's.")
        case .http:
            LocalizedStringResource("A server you name. XDict makes no promise about where it sends your text.")
        case .claudeCLI:
            LocalizedStringResource("Through your Claude Code sign-in. Claude Code holds the credential; XDict never reads it.")
        case .codexCLI:
            LocalizedStringResource("Through your ChatGPT sign-in, held by the Codex tool. It signs in with Codex's own login command.")
        }
    }

    /// The cloud endpoint's own caveat: unlike a local server, it holds a key, and the key has a home.
    public static let cloudCaveat =
        LocalizedStringResource("An OpenAI-compatible cloud endpoint. The key lives in your Keychain, and XDict sends it only over https.")

    /// The outcome word over an answer: what the model says it found.
    public static func outcome(_ outcome: AIOutcome) -> LocalizedStringResource {
        switch outcome {
        case .matched: LocalizedStringResource("Matched")
        case .ambiguous: LocalizedStringResource("More than one sense")
        case .noMatchingSense: LocalizedStringResource("No matching sense")
        case .insufficientContext: LocalizedStringResource("Not enough context")
        case .incompleteInput: LocalizedStringResource("Part of the entry was missing")
        case .explanationOnly: LocalizedStringResource("From the sentence alone")
        case .refused: LocalizedStringResource("The model declined")
        case .guardrail: LocalizedStringResource("The model's guardrails declined")
        case .explained: LocalizedStringResource("Explained")
        case .doesNotFit: LocalizedStringResource("Does not fit")
        }
    }

    /// Whether the answer is tied to the entry, and how the pane says so.
    public static func grounding(_ grounding: MeaningPresentation.Grounding) -> LocalizedStringResource? {
        switch grounding {
        case .none: nil
        case .grounded: LocalizedStringResource("Grounded in the entry")
        case .ungrounded: LocalizedStringResource("Not grounded in an entry")
        }
    }

    /// The entry was cut by the ask's budget; the answer may be missing what was not sent.
    public static let partialEntry =
        LocalizedStringResource("Part of this entry could not be read, so the answer may be missing something.")

    /// **The chosen sense**, as the pane labels it (plan-explain-sense WI-5).
    public static let chosenSense = LocalizedStringResource("The sense you chose")

    /// The chosen sense itself was cut, though the entry may have been whole (contract 3, §4a).
    public static let partialSense =
        LocalizedStringResource("Part of the chosen sense could not be read, so the answer may be missing something.")

    /// A `doesNotFit` verdict's offer: ask the model which sense the sentence uses instead.
    public static let doesNotFitOffer =
        LocalizedStringResource("The sense you chose does not fit this sentence. XDict can ask which sense it is.")

    /// Why the chosen-sense row is disabled: its question always sends the entry's text.
    public static let explainNeedsEntryText = LocalizedStringResource(
        "To explain a chosen sense, turn on “Send the entry’s text with the question” in Settings ▸ AI.")

    /// Why no answer came.
    public static func problem(_ unavailable: MeaningSession.Unavailable) -> LocalizedStringResource {
        switch unavailable {
        case .noSource: LocalizedStringResource("Choose a source in Settings ▸ AI.")
        case .noContext: LocalizedStringResource("There is no captured sentence to answer about.")
        case .noEntry: LocalizedStringResource("No entry is on screen for this sentence.")
        case .entryUnreadable: LocalizedStringResource("The entry could not be read.")
        case .consentChanged:
            LocalizedStringResource("The entry-text switch changed while the question was being prepared, so nothing was sent.")
        case .noSense:
            LocalizedStringResource("The chosen sense is not in this entry.")
        case .entryTextOff:
            LocalizedStringResource("This question sends the entry’s text. Turn on “Send the entry’s text with the question” in Settings ▸ AI.")
        case .provider(let error): provider(error)
        }
    }

    /// A source's typed failure, said plainly.
    public static func provider(_ error: AIProviderError) -> LocalizedStringResource {
        switch error {
        case .insecureEndpoint:
            LocalizedStringResource("The address is not a secure https address. XDict sends a key only over https.")
        case .redirectRefused:
            LocalizedStringResource("The server redirected the request elsewhere, so XDict stopped.")
        case .unreachable:
            LocalizedStringResource("The source could not be reached.")
        case .unauthorised:
            LocalizedStringResource("The source did not accept the credential.")
        case .modelNotFound:
            LocalizedStringResource("The source does not have that model.")
        case .rateLimited:
            LocalizedStringResource("The source is busy or over its limit.")
        case .refused:
            LocalizedStringResource("The source declined to answer.")
        case .truncated:
            LocalizedStringResource("The answer was cut off, so it is not shown.")
        case .badShape:
            LocalizedStringResource("The source answered in a shape XDict does not understand.")
        case .timeout:
            LocalizedStringResource("The source took too long to answer.")
        case .cancelled:
            LocalizedStringResource("The ask was cancelled.")
        case .notInstalled:
            LocalizedStringResource("The command-line tool is not installed.")
        case .notSignedIn:
            LocalizedStringResource("The command-line tool is not signed in.")
        case .versionTooOld:
            LocalizedStringResource("The command-line tool is older than this feature needs.")
        case .unsupportedAuth:
            LocalizedStringResource("The command-line tool is signed in with a kind of credential XDict does not use.")
        case .unavailable(let reason):
            availability(reason)
        case .contextExceeded:
            LocalizedStringResource("The question is longer than this source can take.")
        case .guardrail:
            LocalizedStringResource("The model's guardrails declined to answer this.")
        case .framework:
            LocalizedStringResource("The source failed in a way XDict does not recognise.")
        }
    }

    /// Why Apple's model cannot run here.
    public static func availability(_ reason: AppleAvailability) -> LocalizedStringResource {
        switch reason {
        case .available: LocalizedStringResource("Apple Intelligence is ready.")
        case .deviceNotEligible: LocalizedStringResource("This Mac cannot run Apple Intelligence.")
        case .appleIntelligenceNotEnabled:
            LocalizedStringResource("Apple Intelligence is off. Turn it on in System Settings.")
        case .modelNotReady: LocalizedStringResource("Apple's model is still getting ready.")
        case .system(let required, let running):
            LocalizedStringResource("Apple Intelligence needs macOS \(required) or later; this Mac runs macOS \(running).")
        case .unknown: LocalizedStringResource("Apple's model cannot answer here.")
        }
    }

    /// Why a prompt could not be composed (ADR-0021 d.13): the reader can fix every one of these in the editor.
    public static func compose(_ error: AIComposeError) -> LocalizedStringResource {
        switch error {
        case .unknownPlaceholder(let name):
            LocalizedStringResource("The prompt uses {\(name)}, which XDict does not know.")
        case .missingPlaceholder(let name):
            LocalizedStringResource("The prompt must include {\(name)}.")
        case .entryInSentenceOnly:
            LocalizedStringResource("This prompt may not use {entry} while the entry is not sent.")
        case .templateTooLong:
            LocalizedStringResource("The prompt is too long.")
        case .entryRequired:
            LocalizedStringResource("There is no entry to send for this ask.")
        case .questionTooLong:
            LocalizedStringResource("The request is too long for the source.")
        case .senseOutsideExplainSense:
            LocalizedStringResource("This prompt may not use {sense} outside the chosen-sense question.")
        case .senseRequired:
            LocalizedStringResource("There is no chosen sense to explain.")
        case .senseTextMismatch:
            LocalizedStringResource("The chosen sense does not match the entry that would be sent.")
        }
    }

    /// The model answered, but not in a form the contract accepts; the code says which check failed.
    public static let invalidAnswer = LocalizedStringResource("The source's answer did not pass XDict's check.")

    /// Escape, a newer ask, or closing the presentation.
    public static let cancelled = LocalizedStringResource("The ask was cancelled.")
}
