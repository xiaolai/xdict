import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **The service table made a choice** (2026-10-25): which row a service belongs to, which service an address names, and
/// what "Configured" needs before it is said.
@MainActor
struct MeaningProfilesTests {
    static func profile(_ address: String) -> AIProviderProfile {
        AIProviderProfile(id: "test", name: "Test", baseURL: URL(string: address), auth: .none, keyRequired: false,
                          tokenField: .maxTokensFirst, modelsPath: "models", modelsNeedKey: false,
                          modelsSendKey: false, modelFilter: .all)
    }

    /// **Scheme and host fold case; the path does not**: `/V1` is not `/v1`.
    @Test func anAddressMatchesItsServiceCaseSensitivelyInThePath() {
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://API.OpenAI.com/v1")) == "openai")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://API.OpenAI.com/V1")) == "custom")
        #expect(MeaningProfiles.matching(endpoint: URL(string: "https://openrouter.ai/api/v1/")) == "openrouter")
    }

    /// **Loopback is the whole range, not one address**: `127.0.0.0/8`, `localhost` with or without its terminal dot,
    /// and the IPv6 loopback are local; a near-miss is not.
    @Test func loopbackIsTheWholeRangeAndALocalhostDot() {
        #expect(MeaningProfiles.isLocal(Self.profile("http://127.0.0.2:11434/v1")))
        #expect(MeaningProfiles.isLocal(Self.profile("http://localhost:11434/v1")))
        #expect(MeaningProfiles.isLocal(Self.profile("http://localhost.:11434/v1")))
        #expect(MeaningProfiles.isLocal(Self.profile("http://[::1]:11434/v1")))
        #expect(!MeaningProfiles.isLocal(Self.profile("https://api.example.com/v1")))
        #expect(!MeaningProfiles.isLocal(Self.profile("http://128.0.0.1:11434/v1")))
        #expect(!MeaningProfiles.isLocal(Self.profile("http://127.0.0:11434/v1")))
    }

    /// **A service that needs a key is not configured without one**, and an HTTPS row with one is *configured*, never
    /// *ready* (audit findings, 2026-10-25): the constructor would pass without a key, and only a probe proves one —
    /// "Ready" would promise what nothing checked.
    @Test func aServiceThatNeedsAKeyIsNotConfiguredWithoutOne() async throws {
        let endpoint = try #require(URL(string: "https://api.openai.com/v1"))
        var settings = MeaningSettings(source: .http, endpoint: endpoint, profile: "openai", usesKey: true)
        #expect(await MeaningProviders.status(settings) == .notConfigured)
        settings.key = "sk-shared"
        #expect(await MeaningProviders.status(settings) == .configured(""))
        settings.model = "a-model"
        #expect(await MeaningProviders.status(settings) == .configured("a-model"))
    }
}
