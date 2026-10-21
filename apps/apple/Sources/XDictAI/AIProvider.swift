import Foundation

/// Which source answers: a kind the app persists and shows, never a prompt or a key (`CONTRACT.md` §8.3; ADR-0021 d.3).
public enum AIProviderKind: String, Sendable, Equatable, CaseIterable {
    case appleOnDevice
    case http
    case claudeCLI
    case codexCLI
}

/// A provider's identity: its kind and, for an endpoint, the address it talks to. No display text, no secret.
public struct AIProviderID: Sendable, Equatable {
    public let kind: AIProviderKind
    public let endpoint: URL?

    public init(kind: AIProviderKind, endpoint: URL? = nil) {
        self.kind = kind
        self.endpoint = endpoint
    }
}

/// **What a provider is** (ADR-0021 d.6): it takes the composed question and returns the model's raw answer text.
/// Validation is `AIAnswerValidator`'s and the caller's; nothing here interprets the answer, and nothing here falls back
/// to another provider (no automatic chain, d.3).
public protocol AIProvider: Sendable {
    var id: AIProviderID { get }

    /// The raw answer text for a composed question (`AIComposer.compose`). A cancelled ask throws `.cancelled`, never a
    /// network failure.
    func answer(to question: String) async throws(AIProviderError) -> String
}

/// **Why a provider did not answer** (ADR-0021 d.10). Every case is typed and free of the question, the key and any
/// endpoint credential: a description is safe for a log line because there is nothing in it to scrub.
public enum AIProviderError: Error, Equatable, Sendable {
    /// An `http` endpoint that is not loopback, refused before anything is sent.
    case insecureEndpoint
    /// A redirect would leave the endpoint's origin (scheme, host and port); never followed, so the key never travels.
    case redirectRefused
    case unreachable
    case unauthorised
    case modelNotFound
    case rateLimited
    /// The model or the server declined to answer.
    case refused
    /// The answer was cut off (`finish_reason` of `length`): a partial answer is never a result.
    case truncated
    /// The response was not the shape the contract asks for.
    case badShape
    case timeout
    case cancelled
    /// The CLI a source runs is not installed (or the explicit path does not resolve).
    case notInstalled
    /// The reader's CLI has no usable sign-in for this source.
    case notSignedIn
    /// The CLI is older than the version this source needs.
    case versionTooOld
    /// The CLI is signed in a way this source does not accept (an API key, or an unknown mode).
    case unsupportedAuth
    /// Apple's on-device model cannot run here, with the framework's own reason.
    case unavailable(AppleAvailability)
    /// The question did not fit the on-device model's context window.
    case contextExceeded
    /// The model's guardrails refused the text.
    case guardrail
    /// Any other framework failure, its message scrubbed of the question and bounded.
    case framework(String)

    /// A stable, display-free code the app can log and word itself.
    public var code: String {
        switch self {
        case .insecureEndpoint: "provider.insecureEndpoint"
        case .redirectRefused: "provider.redirectRefused"
        case .unreachable: "provider.unreachable"
        case .unauthorised: "provider.unauthorised"
        case .modelNotFound: "provider.modelNotFound"
        case .rateLimited: "provider.rateLimited"
        case .refused: "provider.refused"
        case .truncated: "provider.truncated"
        case .badShape: "provider.badShape"
        case .timeout: "provider.timeout"
        case .cancelled: "provider.cancelled"
        case .notInstalled: "provider.notInstalled"
        case .notSignedIn: "provider.notSignedIn"
        case .versionTooOld: "provider.versionTooOld"
        case .unsupportedAuth: "provider.unsupportedAuth"
        case .unavailable(let reason): "provider.unavailable.\(reason.code)"
        case .contextExceeded: "provider.contextExceeded"
        case .guardrail: "provider.guardrail"
        case .framework: "provider.framework"
        }
    }
}

extension AIProviderError: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AIProviderError(\(code))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Why Apple's on-device model cannot run, as our own closed set (the framework's enum is neither `Codable` nor
/// `CaseIterable`, and may gain a case — ADR-0021 d.3).
public enum AppleAvailability: Sendable, Equatable, CaseIterable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// **The system is older than this build's Apple source requires** (ADR-0026): the version the source needs and the
    /// one this Mac runs. This is a reason of its own, never `.unknown`: the reader is told which system would work.
    case system(required: String, running: String)
    /// A reason this build does not know.
    case unknown

    /// Every case, for the tests and the rows that must word each one; the system case carries sample versions.
    public static var allCases: [AppleAvailability] {
        [.available, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
         .system(required: String(AppleSource.requiredMacOS), running: "15.0"), .unknown]
    }

    /// A stable, display-free code for logs and the provider error's identity (never a sentence).
    public var code: String {
        switch self {
        case .available: "available"
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .system(let required, let running): "system.\(required).\(running)"
        case .unknown: "unknown"
        }
    }
}
