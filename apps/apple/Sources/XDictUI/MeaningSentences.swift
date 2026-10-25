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
        // **What the model did, not a verdict on it** (HIG audit 2026-10-23, UI12): "Matched" read as validation.
        case .matched: LocalizedStringResource("Chose a sense from the entry")
        case .ambiguous: LocalizedStringResource("More than one sense")
        case .noMatchingSense: LocalizedStringResource("No matching sense")
        case .insufficientContext: LocalizedStringResource("Not enough context")
        // **Neutral about what was incomplete** (audit finding, 2026-10-25): the chosen-sense question can earn this
        // outcome for a partial sense, where "the entry" would name the wrong thing.
        case .incompleteInput: LocalizedStringResource("The input was incomplete")
        case .explanationOnly: LocalizedStringResource("From the sentence alone")
        case .refused: LocalizedStringResource("The model declined")
        case .guardrail: LocalizedStringResource("The model's guardrails declined")
        case .explained: LocalizedStringResource("Explained")
        case .doesNotFit: LocalizedStringResource("Does not fit")
        }
    }

    /// **What the request used, never that the answer is right** (UI12): "Grounded" implied a guarantee the pipeline
    /// does not give — a quote found in the entry links the answer to a source; it does not validate the explanation.
    public static func grounding(_ grounding: MeaningPresentation.Grounding) -> LocalizedStringResource? {
        switch grounding {
        case .none: nil
        case .grounded: LocalizedStringResource("Uses this dictionary entry")
        case .ungrounded: LocalizedStringResource("Uses only the sentence")
        }
    }

    /// **The pane's task title** (UI17), stable in every state: the feature, not the provider.
    public static let title = LocalizedStringResource("Meaning in Context")

    /// **Generated content says so, once, beside it** (UI12; HIG Generative AI): its limit, without a warning per line.
    public static let generated = LocalizedStringResource("AI-generated. It can be wrong; check it against the entry.")

    /// The context section's label (UI09): the sentence the request is about.
    public static let contextHeading = LocalizedStringResource("In this sentence")

    /// The evidence section's label (UI10, UI11): the dictionary text the answer quotes.
    public static let evidence = LocalizedStringResource("From the entry")

    /// The quoted text could not be found on the page shown now (UI11): the reveal says so rather than doing nothing.
    public static let revealFailed = LocalizedStringResource("This text is not on the page shown now.")

    /// **The shown answer is about the sense chosen before** (UI23): the reader's later click kept it, not replaced it.
    public static let selectionMoved =
        LocalizedStringResource("You have chosen another sense since. This answer is about the one shown here.")

    /// The note's origin when the request named no source: a saved note is data and still says where it came from.
    public static let anAISource = LocalizedStringResource("an AI source")

    /// **A saved note says where it came from** (plan-companion WI-9; owner, 2026-10-25): the source (and the model when
    /// one was named), the day, and that a model wrote the wording — the reader's note never claims otherwise.
    public static func noteProvenance(source: String, model: String?, day: String) -> LocalizedStringResource {
        if let model, !model.isEmpty {
            LocalizedStringResource(
                "Saved from an XDict AI answer (\(source), \(model), \(day)). The wording is the model's.")
        } else {
            LocalizedStringResource("Saved from an XDict AI answer (\(source), \(day)). The wording is the model's.")
        }
    }

    /// **The cut, in the tense of the request** (UI19): a preview's entry *will be* cut; a sent one *was*.
    public static func cut(at bytes: UInt64, sent: Bool) -> LocalizedStringResource {
        sent ? LocalizedStringResource("The entry was cut at \(bytes) bytes, so only the part before that was sent.")
            : LocalizedStringResource("The entry is cut at \(bytes) bytes, so only the part before that will be sent.")
    }

    /// **What a preview will send, in one line each** (UI14): the recipient, and whether the entry goes with the sentence.
    public static func previewEntry(included: Bool) -> LocalizedStringResource {
        included ? LocalizedStringResource("The sentence and this entry’s text will be sent.")
            : LocalizedStringResource("Only the sentence will be sent, not the entry.")
    }

    /// **The text Copy Details puts on the pasteboard** (UI20): the stable code, for support; never the request.
    public static func errorDetails(code: String) -> String {
        "XDict meaning-in-context error: \(code)"
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
        case .entryFailure: LocalizedStringResource("The entry could not be read.")
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
        case .server(let status, let message):
            // **The server's own sentence** (measured 2026-10-25: DeepSeek names the models it serves in a 400): it is
            // shown when it gave one, because it says what to fix; a bare status otherwise.
            // **Neutral about who failed**: a 4xx is the server declining, a 5xx is the server breaking, and the same
            // sentence cannot honestly say "refused" for both.
            if message.isEmpty {
                LocalizedStringResource("The request to the source failed (HTTP \(status)).")
            } else {
                LocalizedStringResource("The request to the source failed (HTTP \(status)): \(message)")
            }
        case .timeout:
            LocalizedStringResource("The source took too long to answer.")
        case .cancelled:
            Self.cancelled
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

    /// **Why a service's model list could not be read.** The failures it shares with a provider borrow its sentences;
    /// the list's own — a service that lists nothing, a key it wants first, a refused request — have their own.
    public static func catalogue(_ error: ModelCatalogError) -> LocalizedStringResource {
        switch error {
        case .noList:
            LocalizedStringResource("This service does not list its models.")
        case .missingKey:
            LocalizedStringResource("Enter a key to see this service's models.")
        case .unreachable: provider(.unreachable)
        case .unauthorised: provider(.unauthorised)
        case .rateLimited: provider(.rateLimited)
        case .timeout: provider(.timeout)
        case .cancelled: provider(.cancelled)
        case .badShape: provider(.badShape)
        case .server(let status, let message):
            if message.isEmpty {
                LocalizedStringResource("The model-list request failed (HTTP \(status)).")
            } else {
                LocalizedStringResource("The model-list request failed (HTTP \(status)): \(message)")
            }
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
        // **The limit is XDict's own** (audit finding, 2026-10-25): `AIComposer.questionCeilingUTF8` refuses the
        // composed question before any source sees it, so the sentence must not blame the source.
        case .questionTooLong:
            LocalizedStringResource("The question is longer than XDict's limit.")
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
