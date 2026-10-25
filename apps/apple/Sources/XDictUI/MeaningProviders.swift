import Foundation
import XDictAI
import XDictBase

/// **What a source's live check found** (Settings ▸ AI): ready, with a version or model when there is one to name; not
/// set up yet; or the typed reason it cannot run. The view words every case.
public enum MeaningSourceStatus: Equatable, Sendable {
    case checking
    case notConfigured
    case ready(String)
    case failed(AIProviderError)
}

/// **The sources `MeaningSettings` may name** (ADR-0021 d.3), each built for the settings the reader chose. Apple's model
/// and an HTTP endpoint need no folder; the two CLI sources run in XDict-owned ones under the app's Application Support,
/// so none of the reader's own configuration, MCP servers, hooks or instructions is inherited — and their sign-in is the
/// CLI's own, made in that home.
public enum MeaningProviders {
    public static func make(_ settings: MeaningSettings) throws(AIProviderError) -> any AIProvider {
        switch settings.source {
        case .none:
            throw .notInstalled
        case .appleOnDevice:
            return AppleProvider.make()
        case .http:
            guard let endpoint = settings.endpoint else { throw .unreachable }
            return try HTTPProvider(configuration: httpConfiguration(settings, endpoint: endpoint))
        case .claudeCLI:
            return ClaudeCLIProvider(configuration: .init(configDirectory: folder("claude"), workingDirectory: folder("work"),
                                                         model: nil, answerSchema: AIAnswerSchema.claude))
        case .codexCLI:
            // **The provider makes and checks the app's own home** (sayso 0.5.1 creates it before the probe reads the
            // sign-in in it); XDict only names the folders. The pre-creation this used to do was a workaround for the
            // order 0.5.1 fixes, and it swallowed a failed creation with `try?`.
            return try CodexCLIProvider(configuration: .init(codexHome: folder("codex"),
                                                             workingDirectory: folder("work"), model: nil))
        }
    }

    /// **Whether a source can answer, without asking a model** (Settings ▸ AI's live status): local checks only — the
    /// on-device model's availability, an endpoint's shape, a CLI's presence, version and sign-in. Nothing here sends the
    /// reader's text.
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
                return .ready(settings.model)
            } catch {
                return .failed(error)
            }
        case .claudeCLI, .codexCLI:
            do {
                let provider = try make(settings)
                if let claude = provider as? ClaudeCLIProvider { return .ready(try await claude.check()) }
                if let codex = provider as? CodexCLIProvider { return .ready(try await codex.check()) }
                return .ready("")
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
    static func httpConfiguration(_ settings: MeaningSettings, endpoint: URL) -> HTTPProvider.Configuration {
        let profile = MeaningProfiles.selected(settings)
        return .init(endpoint: endpoint, model: settings.model, apiKey: apiKey(settings),
                     auth: profile.auth, tokenField: profile.tokenField)
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
