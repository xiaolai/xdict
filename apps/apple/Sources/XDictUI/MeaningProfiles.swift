import Foundation
import XDictAI

/// **The services Settings ▸ AI offers, as sayso's profile table made a choice** (2026-10-25): the servers on this Mac
/// on the local row, the cloud services on the cloud row, and Custom on both. A profile supplies the address, how the
/// key travels and which token-limit field to send first; the key itself is the reader's one stored key, shared.
///
/// The table is sayso's, so a service added there appears here without a second list; what is XDict's is which row a
/// service belongs to, what an install that never chose one is inferred to use, and the words the pane shows.
public enum MeaningProfiles {
    /// Custom's id in the table: the reader supplies the address.
    public static let custom = "custom"

    /// Whether a profile is a server on this Mac. By its address, not a flag: loopback is what makes it local.
    public static func isLocal(_ profile: AIProviderProfile) -> Bool {
        guard let host = profile.baseURL?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// The profiles a row offers, in the table's order, Custom last.
    public static func offered(cloud: Bool) -> [AIProviderProfile] {
        AIProviderProfile.known.filter { $0.id != custom && isLocal($0) == !cloud } + [.custom]
    }

    /// **The profile a settings value actually uses**: the stored one when it belongs to the chosen row, Custom
    /// otherwise. Choosing the other row therefore hides a service without forgetting it — switching back restores it.
    public static func selected(_ settings: MeaningSettings) -> AIProviderProfile {
        let profile = AIProviderProfile.profile(id: settings.profile) ?? .custom
        guard profile.id != custom else { return .custom }
        return isLocal(profile) == !settings.usesKey ? profile : .custom
    }

    /// **The profile an address belongs to**, for an install that predates the choice: an exact match on a known base
    /// address (trailing slash aside), Custom otherwise. The address stays the reader's; this only names its service.
    public static func matching(endpoint: URL?) -> String {
        guard let endpoint else { return custom }
        let text = normalized(endpoint)
        return AIProviderProfile.known.first {
            guard let base = $0.baseURL else { return false }
            return normalized(base) == text
        }?.id ?? custom
    }

    private static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
