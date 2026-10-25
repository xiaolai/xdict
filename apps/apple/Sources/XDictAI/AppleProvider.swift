import Foundation
import SaySoAI
import SaySoAIApple

/// **Apple's on-device model, bound to XDict's contract** (ADR-0021 d.3, ADR-0026): sayso supplies the provider and its
/// generic answer type; this adapter fixes the answer to `AppleAnswer`, encodes it as the contract's JSON, and keeps the
/// build's floor in front of the framework — on a Mac older than the source needs, the framework is never asked.
///
/// The deployment floor is macOS 27, over sayso's own 26.4 for this provider, so no ask-time availability guard is
/// needed here; ADR-0026's floor is about telling the reader what their Mac needs, not about an API that may be absent.
public enum AppleProvider {
    /// What Apple reports here and now, or the typed system case naming both versions (ADR-0026). The framework call is
    /// an autoclosure: below the floor it is never evaluated.
    public static func availability() -> AppleAvailability {
        AppleSource.availability(running: AppleSource.running, framework: AppleOnDeviceProvider<AppleAnswer>.availability())
    }

    /// The provider the app runs: one fresh session per ask, guided into `AppleAnswer`.
    public static func make() -> any AIProvider {
        AppleOnDeviceProvider<AppleAnswer>(configuration: .init(encode: { json($0) }))
    }

    /// The generated answer as the contract's JSON: the one shape every provider returns to the validator. An
    /// unencodable answer is the empty string, which the validator refuses as a bad shape — never a fabricated answer.
    static func json(_ answer: AppleAnswer) -> String {
        let object: [String: Any] = ["outcome": answer.outcome.rawValue, "quotes": answer.quotes,
                                     "explanation": answer.explanation]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
