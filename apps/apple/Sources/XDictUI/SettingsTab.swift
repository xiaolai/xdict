import Foundation

/// **Settings' panes, in order** (ADR-0012 d.1): Dictionaries first, as Apple's Settings opens on its list (parity P39);
/// then Reading & Speech; then General. The scene's `TabView` iterates these cases, so a test of the enum is a test of
/// the window's panes.
public enum SettingsTab: CaseIterable, Hashable, Sendable {
    case dictionaries
    case readingAndSpeech
    case general

    public var title: LocalizedStringResource {
        switch self {
        case .dictionaries: "Dictionaries"
        case .readingAndSpeech: "Reading & Speech"
        case .general: "General"
        }
    }

    public var symbol: String {
        switch self {
        case .dictionaries: "books.vertical"
        case .readingAndSpeech: "book"
        case .general: "gearshape"
        }
    }
}
