import Foundation
import XDictBase

/// What the launch window says about the dictionary service: asking, its answer, or which way it failed.
public enum LaunchStatus: Equatable, Sendable {
    case asking
    case answered(CoreVersions)
    case failed(HandshakeFailure)

    /// The sentence the reader reads first.
    public var headline: LocalizedStringResource {
        switch self {
        case .asking: LocalizedStringResource("Asking the dictionary service…")
        case .answered: LocalizedStringResource("The dictionary service answered.")
        case .failed(.timedOut): LocalizedStringResource("The dictionary service did not answer in time.")
        case .failed(.unreachable): LocalizedStringResource("The dictionary service could not be reached.")
        case .failed(.refused): LocalizedStringResource("The dictionary service could not answer.")
        case .failed(.unreadable): LocalizedStringResource("The dictionary service sent an answer XDict cannot read.")
        }
    }

    /// The versions, once there are any.
    public var detail: LocalizedStringResource? {
        guard case .answered(let versions) = self else { return nil }
        return LocalizedStringResource("Core \(versions.core), protocol \(versions.protocolVersion)")
    }
}
