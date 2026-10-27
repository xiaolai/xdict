import Foundation
import Testing
@testable import XDictAI

/// **Apple's on-device model, bound to XDict's contract** (ADR-0021 d.3, ADR-0026): XDict's floor sits in front of
/// sayso's mapped framework answer, the provider is built through one public factory, and the generated answer
/// serialises to the contract's one shape. The provider's own behaviour is sayso's test; what is XDict's is the binding.
struct AppleProviderTests {
    /// **The answer is one the build knows** (sayso dropped `isKnownCase` in 0.5.2/0.5.3): `.unknown` is the case for a
    /// reason this build cannot name, and XDict's floor must never see it on a Mac that reaches this front door.
    @Test func availabilityIsOneKnownCase() {
        #expect(AppleProvider.availability() != .unknown)
    }

    /// **A system older than the build's source is named with both versions** (ADR-0026), and the framework is not asked
    /// on a system that may not have it: the autoclosure stays unevaluated below the floor.
    @Test func anOlderSystemIsATypedCaseThatNamesBothVersions() {
        #expect(AppleSource.availability(running: "15.7", framework: .available)
                == .system(required: "27", running: "15.7"))
        #expect(AppleSource.availability(running: "26.5", framework: .available)
                == .system(required: "27", running: "26.5"))
        #expect(AppleSource.availability(running: "27.0", framework: .available) == .available)
        #expect(AppleSource.availability(running: "27.0", framework: .modelNotReady) == .modelNotReady)

        var asked = false
        func framework() -> AppleAvailability {
            asked = true
            return .available
        }
        _ = AppleSource.availability(running: "15.7", framework: framework())
        #expect(!asked, "the framework must not be touched below the floor")
        _ = AppleSource.availability(running: "27.0", framework: framework())
        #expect(asked)
    }

    /// When Apple's model cannot run here, the bound provider says exactly why and never creates a session.
    @Test(.enabled(if: AppleProvider.availability() != .available))
    func anUnavailableModelIsATypedRefusal() async {
        let provider = AppleProvider.make()
        let reason = AppleProvider.availability()
        guard reason != .available else {
            Issue.record("the test ran with the model available")
            return
        }
        await #expect(throws: AIProviderError.unavailable(reason)) { try await provider.answer(to: "q") }
    }

    /// A real answer through the binding, only on the reader's word:
    /// `XDICT_AI_APPLE=1 swift test --filter AppleProviderTests`.
    @Test(.enabled(if: AppleProvider.availability() == .available
                   && ProcessInfo.processInfo.environment["XDICT_AI_APPLE"] == "1"))
    func aRealGeneration() async throws {
        let text = try await AppleProvider.make().answer(to: "Answer with the single word: pong")
        #expect(!text.isEmpty)
    }

    /// **The generated answer serialises to the contract's one shape** (measured 2026-10-20: free-form answers failed it
    /// in 19 of 24 entries; guided generation writes these three fields).
    @Test func theGeneratedAnswerIsTheContractsJSON() throws {
        let answer = AppleAnswer(outcome: .ambiguous, quotes: ["a ship's hold", "to hold dear"],
                                 explanation: "Two senses.")
        let json = AppleProvider.json(answer)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["outcome", "quotes", "explanation"])
        #expect(object["outcome"] as? String == "ambiguous")
        #expect(object["quotes"] as? [String] == ["a ship's hold", "to hold dear"])
        #expect(object["explanation"] as? String == "Two senses.")
    }

    @Test func anAppleProviderHasItsOwnIdentity() {
        #expect(AppleProvider.make().id == AIProviderID(kind: .appleOnDevice))
    }
}
