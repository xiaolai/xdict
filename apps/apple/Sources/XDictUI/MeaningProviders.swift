import Foundation
import XDictAI
import XDictBase

/// **What a source's live check found** (Settings ▸ AI): ready, with a version or model when there is one to name;
/// configured as far as a local check can prove, with the version or model it found; not set up yet; or the typed
/// reason it cannot run. The view words every case.
public enum MeaningSourceStatus: Equatable, Sendable {
    case checking
    case notConfigured
    case ready(String)
    /// **Set up as far as a local check can prove** (audit finding, 2026-10-25): Claude Code's check proves the program
    /// and its version, not the sign-in inside XDict's own configuration, which only an ask reveals. Saying "Ready"
    /// there would promise something nothing checked; `detail` is the version the check found.
    case configured(String)
    case failed(AIProviderError)
}

/// **The sources `MeaningSettings` may name** (ADR-0021 d.3), each built for the settings the reader chose. Apple's model
/// and an HTTP endpoint need no folder; the two CLI sources run in XDict-owned ones under the app's Application Support,
/// so none of the reader's own configuration, MCP servers, hooks or instructions is inherited — and their sign-in is the
/// CLI's own, made in that home.
public enum MeaningProviders {
    /// **The source for a question's own shape** (contract 6): a translation's answer has fields a meaning answer does
    /// not, so the schema and the guided type are chosen from the mode, never patched afterwards.
    public static func make(_ settings: MeaningSettings, mode: AIMode) throws(AIProviderError) -> any AIProvider {
        switch settings.source {
        case .none:
            throw .notInstalled
        case .appleOnDevice:
            return AppleProvider.make(mode: mode)
        case .http:
            guard let endpoint = settings.endpoint else { throw .unreachable }
            return try HTTPProvider(configuration: httpConfiguration(settings, endpoint: endpoint))
        case .claudeCLI:
            return claude(mode: mode)
        case .codexCLI:
            return codex()
        }
    }

    /// **Claude Code in XDict's own configuration**: its sign-in is made in `folder("claude")`, never in the reader's.
    static func claude(mode: AIMode = .grounded) -> ClaudeCLIProvider {
        ClaudeCLIProvider(configuration: .init(configDirectory: folder("claude"), workingDirectory: folder("work"),
                                              model: nil, answerSchema: AIAnswerSchema.claude(for: mode)))
    }

    /// **Codex in the app's own home**: the provider makes and checks that home before its probe reads the sign-in in
    /// it (sayso 0.5.1's order); XDict only names the folders. The pre-creation this used to do was a workaround for
    /// that order, and it swallowed a failed creation with `try?`.
    static func codex() -> CodexCLIProvider {
        // **The initializer no longer throws** (sayso 0.5.2/0.5.3): the provider makes its home and checks the sign-in.
        CodexCLIProvider(configuration: .init(codexHome: folder("codex"), workingDirectory: folder("work"), model: nil))
    }

    /// **Whether a source can answer, without asking a model** (Settings ▸ AI's live status): local checks only — the
    /// on-device model's availability, an endpoint's shape, a CLI's presence, version and sign-in. Nothing here sends the
    /// reader's text. What a check cannot prove says `.configured`, never `.ready`.
    public static func status(_ settings: MeaningSettings) async -> MeaningSourceStatus {
        guard let source = settings.source else { return .notConfigured }
        switch source {
        case .appleOnDevice:
            let availability = AppleProvider.availability()
            return availability == .available ? .ready("") : .failed(.unavailable(availability))
        case .http:
            guard let endpoint = settings.endpoint else { return .notConfigured }
            // **A service that needs a key is not set up without one**: the constructor would pass — only a request
            // proves a key — but "Ready" beside an empty key field would be a promise nothing checked.
            if profile(settings).keyRequired, (apiKey(settings) ?? "").isEmpty { return .notConfigured }
            do {
                _ = try HTTPProvider(configuration: httpConfiguration(settings, endpoint: endpoint))
                // **The constructor proves the address's shape, not the key** (audit finding, 2026-10-25): callers say
                // Configured, and Test — a probe — is what can say more.
                return .configured(settings.model)
            } catch {
                return .failed(error)
            }
        case .claudeCLI:
            // **Typed, never a cast and a fallback** (audit finding, 2026-10-25): the provider is built as itself, and
            // its check proves the program and version. The sign-in in XDict's own configuration is checked by the
            // first ask, so this is `.configured`, not `.ready`.
            do {
                return .configured(try await claude().check())
            } catch {
                return .failed(error)
            }
        case .codexCLI:
            do {
                return .ready(try await codex().check())
            } catch {
                return .failed(error)
            }
        }
    }

    /// The service these settings name: the stored profile when it belongs to the chosen row, Custom otherwise.
    static func profile(_ settings: MeaningSettings) -> AIProviderProfile {
        MeaningProfiles.selected(settings)
    }

    /// **The HTTP configuration for these settings**: the address, the model, the one stored key when this row sends
    /// one, and the chosen service's auth and token-field preference from sayso's profile table.
    /// **One answer's token budget** (owner, 2026-10-27; sayso 0.5.3's `answerTokens`): a reasoning model spends part of
    /// it before it writes a word, and sayso's default 1,024 was measured cutting `deepseek-flash` off mid-answer on
    /// longer sentences — `finish_reason: "length"`, refused as "the answer was cut off". A budget costs nothing until it
    /// is used, so this is set well above what the answer itself needs (2,000 characters at most).
    ///
    /// **The next limit behind it is sayso's own clock, not this number**: `HTTPProvider.resourceTimeout` is 90 s for the
    /// whole request, so a budget past roughly eight thousand tokens turns a cut-off answer into a timeout on any endpoint
    /// slower than ~90 tokens a second. Raising this again is only worth it together with a longer timeout.
    static let answerTokens = 8_192

    static func httpConfiguration(_ settings: MeaningSettings, endpoint: URL) -> HTTPProvider.Configuration {
        let profile = MeaningProfiles.selected(settings)
        return .init(endpoint: endpoint, model: settings.model, apiKey: apiKey(settings),
                     auth: profile.auth, tokenField: profile.tokenField, answerTokens: answerTokens)
    }

    /// XDict's own folder for a source's configuration or working directory.
    static func folder(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: XDictIdentity.app).appending(path: "AI").appending(path: name)
    }

    /// **The key only when it belongs to this endpoint choice**: the cloud row's key is never sent to a local server.
    static func apiKey(_ settings: MeaningSettings) -> String? {
        settings.usesKey ? settings.key : nil
    }

}
