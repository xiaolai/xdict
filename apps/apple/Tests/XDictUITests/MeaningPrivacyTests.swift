import Foundation
import Testing
import XDictAI
import XDictClient
import XDictContract
import XDictUI

/// **The sentence and the key never reach a description** (`conformance/capture/CONTRACT.md` §6; ADR-0021 d.4): every
/// value the AI pane holds in memory describes itself as metadata only, and its mirror is empty so `dump` cannot walk
/// into it either. The same shape as the capture canary, for the one consumer that may read the sentence.
@MainActor
@Suite struct MeaningPrivacyTests {
    static let sentence = "They hold that view about the quiet river."

    static func session() -> MeaningSession {
        let session = MeaningSession(fetchEntryText: { _, _, _ in .failure(.wire(.interrupted)) },
                                     presented: { nil },
                                     makeProvider: { (_: MeaningSettings, _: AIMode) throws(AIProviderError) -> any AIProvider in
                                         throw .notInstalled })
        session.hold(handoff())
        return session
    }

    static func handoff() -> MeaningHandoff {
        MeaningHandoff(term: "hold", sentence: sentence, range: NSRange(location: 5, length: 4),
                       origin: MeaningOrigin(request: 1, generation: 2))
    }

    @Test func aHandedOverSentenceIsNotInAnyDescription() {
        let handoff = Self.handoff()
        for line in [String(describing: handoff), String(reflecting: handoff), handoff.debugDescription] {
            #expect(!line.contains("quiet river"), "the sentence reached a description: \(line)")
        }
        #expect(Mirror(reflecting: handoff).children.isEmpty, "dump would walk into the sentence")
        #expect(String(describing: handoff).contains("UTF-16 units"), "a description names the sizes")
        // **The term can be the whole sentence** (audit round 4, 2026-10-25): a phrase selection equal to it must not leak.
        let whole = MeaningHandoff(term: Self.sentence, sentence: Self.sentence,
                                   range: NSRange(location: 0, length: Self.sentence.utf16.count),
                                   origin: MeaningOrigin(request: 2, generation: 3))
        for line in [String(describing: whole), whole.debugDescription] {
            #expect(!line.contains("quiet river"))
        }
    }

    @Test func aDisplayedQuestionIsNotInAnyDescription() {
        let question = MeaningContext(term: "hold", sentence: Self.sentence, range: NSRange(location: 5, length: 4))
        for line in [String(describing: question), String(reflecting: question)] {
            #expect(!line.contains("quiet river"))
        }
        #expect(Mirror(reflecting: question).children.isEmpty)
    }

    @Test func aPresentationDoesNotDescribeItsSentenceOrAnswer() {
        let presentation = MeaningPresentation(
            facts: MeaningRequestFacts(questionContext: MeaningContext(term: "hold", sentence: Self.sentence,
                                                                     range: NSRange(location: 5, length: 4))),
            grounding: .grounded, outcome: nil, coverage: nil, quotes: ["private dictionary quotation"],
            explanation: "private generated explanation", problem: nil, code: nil)
        for line in [String(describing: presentation), String(reflecting: presentation)] {
            #expect(!line.contains("quiet river"))
            #expect(!line.contains("private dictionary quotation"))
            #expect(!line.contains("private generated explanation"))
        }
        #expect(Mirror(reflecting: presentation).children.isEmpty)
    }

    /// **The request facts describe nothing the reader wrote** (audit round 2, 2026-10-25): they hold the sentence and the
    /// sense, so their description is the choices alone.
    @Test func aRequestFactsValueDoesNotDescribeItsSentenceOrSense() {
        let facts = MeaningRequestFacts(
            chosenSense: AISense(id: 1, start: 0, len: 4, text: "quiet river", label: nil, section: nil, whole: true),
            questionContext: MeaningContext(term: "hold", sentence: Self.sentence, range: NSRange(location: 5, length: 4)))
        for line in [String(describing: facts), String(reflecting: facts)] {
            #expect(!line.contains("quiet river"))
        }
        #expect(Mirror(reflecting: facts).children.isEmpty)
    }

    @Test func aKeyIsNotInTheSettingsDescription() {
        var settings = MeaningSettings(source: .http, endpoint: URL(string: "http://127.0.0.1:1/v1"), model: "m",
                                       key: "sk-a-secret-value", sendEntryText: true, language: "en")
        // **The reader's edited prompt is private too** (audit round 4): a description that printed it must fail here.
        settings.templates[.grounded] = "private template canary"
        for line in [String(describing: settings), String(reflecting: settings)] {
            #expect(!line.contains("sk-a-secret-value"), "the key reached a description: \(line)")
            #expect(!line.contains("127.0.0.1"), "the address reached a description: \(line)")
            #expect(!line.contains("private template canary"), "the edited prompt reached a description: \(line)")
        }
        #expect(Mirror(reflecting: settings).children.isEmpty)
    }

    @Test func aSessionDescribesItselfAsAKindOnly() {
        let session = Self.session()
        for line in [String(describing: session), String(reflecting: session), session.debugDescription] {
            #expect(line == "MeaningSession", "a session's description stopped being a constant: \(line)")
        }
        #expect(Mirror(reflecting: session).children.isEmpty)
    }

    /// **Describing a session off the main actor neither traps nor leaks** (audit round 3, 2026-10-25): the nonisolated
    /// description is a constant, not a main-actor read.
    @Test func aSessionCanBeDescribedOffTheMainActor() async {
        let session = Self.session()
        // **Every description path, off the actor** (audit round 4, 2026-10-25): reflecting and the mirror were tested only on
        // the main actor, where an isolation regression would not show.
        let (described, reflected, empty) = await Task.detached {
            (String(describing: session), String(reflecting: session), Mirror(reflecting: session).children.isEmpty)
        }.value
        #expect(described == "MeaningSession")
        #expect(reflected == "MeaningSession")
        #expect(empty)
    }

    /// **The composed prompt holds the sentence and the entry** (WI-6's View the prompt): it may be shown in the pane,
    /// never written to a log, so its description is the size and the mode, and `dump` finds nothing.
    @Test func aSentPromptIsNotInAnyDescription() {
        // **The entry's text too, not only the sentence** (audit round 3, 2026-10-25): a distinct canary catches a
        // description that leaked the entry alone.
        let sent = MeaningSent(text: "They hold that view about the quiet river.\n\nA dictionary entry canary.",
                               mode: .grounded, source: .http, complete: true, cutAt: 10)
        for line in [String(describing: sent), String(reflecting: sent), sent.debugDescription] {
            #expect(!line.contains("quiet river"), "the sentence reached a description: \(line)")
            #expect(!line.contains("dictionary entry canary"), "the entry's text reached a description: \(line)")
        }
        #expect(Mirror(reflecting: sent).children.isEmpty)
    }
}
