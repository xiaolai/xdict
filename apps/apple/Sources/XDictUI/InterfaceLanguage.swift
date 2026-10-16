import Foundation

/// **The language of XDict's own words** (plan-macos-v1 WI-9): the system's by default, or English or Simplified Chinese
/// chosen in Settings. The choice is the app's own `AppleLanguages`, which macOS reads at launch, so it takes effect when
/// XDict next opens. Dictionary content is never translated.
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let key = "AppleLanguages"

    public var id: String { rawValue }

    /// The choice in the app's own domain only: `AppleLanguages` read through `UserDefaults` falls through to the
    /// global domain, the system's list, which is not a choice the reader made here.
    public static func current(in defaults: UserDefaults, domain: String) -> InterfaceLanguage {
        guard let first = (defaults.persistentDomain(forName: domain)?[key] as? [String])?.first else { return .system }
        return InterfaceLanguage(rawValue: first) ?? .system
    }

    public func apply(to defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set([rawValue], forKey: Self.key)
        }
    }

    /// Each language named in itself, so a reader who cannot read the other can still find theirs.
    public var name: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("The system's language")
        case .english: LocalizedStringResource("English")
        case .simplifiedChinese: LocalizedStringResource("简体中文")
        }
    }
}
