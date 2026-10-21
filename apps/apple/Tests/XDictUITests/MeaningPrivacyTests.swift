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
        #expect(String(describing: handoff).contains("hold"), "the term is not context: it names the value")
    }

    @Test func aKeyIsNotInTheSettingsDescription() {
        let settings = MeaningSettings(source: .http, endpoint: URL(string: "http://127.0.0.1:1/v1"), model: "m",
                                       key: "sk-a-secret-value", sendEntryText: true, language: "en")
        for line in [String(describing: settings), String(reflecting: settings)] {
            #expect(!line.contains("sk-a-secret-value"), "the key reached a description: \(line)")
            #expect(!line.contains("127.0.0.1"), "the address reached a description: \(line)")
        }
        #expect(Mirror(reflecting: settings).children.isEmpty)
    }

    @Test func aSessionDescribesItsStateAndNotItsReader() {
        let session = MeaningSession(fetchEntryText: { _, _, _ in .failure(.wire(.interrupted)) },
                                     presented: { nil }, makeProvider: { (_: MeaningSettings) throws(AIProviderError) -> any AIProvider in throw .notInstalled })
        session.hold(Self.handoff())
        for line in [String(describing: session), String(reflecting: session)] {
            #expect(!line.contains("quiet river"), "the sentence reached a description: \(line)")
        }
        #expect(Mirror(reflecting: session).children.isEmpty)
    }

    /// **The composed prompt holds the sentence and the entry** (WI-6's View the prompt): it may be shown in the pane,
    /// never written to a log, so its description is the size and the mode, and `dump` finds nothing.
    @Test func aSentPromptIsNotInAnyDescription() {
        let sent = MeaningSent(text: "They hold that view about the quiet river.\n\nentry text",
                               mode: .grounded, source: .http, complete: true, cutAt: 10)
        for line in [String(describing: sent), String(reflecting: sent), sent.debugDescription] {
            #expect(!line.contains("quiet river"), "the prompt reached a description: \(line)")
        }
        #expect(Mirror(reflecting: sent).children.isEmpty)
    }
}
