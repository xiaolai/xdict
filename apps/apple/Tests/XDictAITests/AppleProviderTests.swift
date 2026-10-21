import Foundation
import Testing
@testable import XDictAI

/// **Apple's on-device model as a provider** (ADR-0021 d.3): availability is reported, not assumed; an unavailable model
/// refuses before a session exists; a real generation runs only when asked for by name (`XDICT_AI_APPLE=1`). No test here
/// turns on a network or spends a provider's quota.
struct AppleProviderTests {
    @Test func availabilityIsOneKnownCase() {
        let availability = AppleOnDeviceProvider.availability()
        #expect(AppleAvailability.allCases.contains(availability))
    }

    /// When Apple's model cannot run here, the provider says exactly why and never creates a session.
    @Test(.enabled(if: AppleOnDeviceProvider.availability() != .available))
    func anUnavailableModelIsATypedRefusal() async {
        let provider = AppleOnDeviceProvider()
        let reason = AppleOnDeviceProvider.availability()
        guard reason != .available else {
            Issue.record("the test ran with the model available")
            return
        }
        await #expect(throws: AIProviderError.unavailable(reason)) { try await provider.answer(to: "q") }
    }

    /// A real answer, only on the reader's word: `XDICT_AI_APPLE=1 swift test --filter AppleProviderTests`.
    @Test(.enabled(if: AppleOnDeviceProvider.availability() == .available
                   && ProcessInfo.processInfo.environment["XDICT_AI_APPLE"] == "1"))
    func aRealGeneration() async throws {
        let provider = AppleOnDeviceProvider()
        let text = try await provider.answer(to: "Answer with the single word: pong")
        #expect(!text.isEmpty)
    }

    /// **The generated answer serialises to the contract's one shape** (measured 2026-10-20: free-form answers failed it
    /// in 19 of 24 entries; guided generation writes these three fields).
    @Test func theGeneratedAnswerIsTheContractsJSON() throws {
        let answer = AppleAnswer(outcome: .ambiguous, quotes: ["a ship's hold", "to hold dear"],
                                 explanation: "Two senses.")
        let json = try AppleOnDeviceProvider.json(answer)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["outcome", "quotes", "explanation"])
        #expect(object["outcome"] as? String == "ambiguous")
        #expect(object["quotes"] as? [String] == ["a ship's hold", "to hold dear"])
        #expect(object["explanation"] as? String == "Two senses.")
    }

    @Test func aFrameworkMessageIsScrubbedOfTheQuestion() {
        struct Echo: Error, CustomStringConvertible {
            let description: String
        }
        let question = "a very private sentence"
        let scrubbed = AppleOnDeviceProvider.scrubbed(Echo(description: "failed on: \(question)"), question: question)
        #expect(!scrubbed.contains(question))
        #expect(scrubbed.contains("<question>"))
    }

    @Test func anEndpointIsNotAnAppleProvider() {
        #expect(AppleOnDeviceProvider().id == AIProviderID(kind: .appleOnDevice))
    }
}
