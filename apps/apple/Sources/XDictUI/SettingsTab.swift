import Foundation

/// **Settings' panes, in order** (ADR-0012 d.1, amended 2026-10-20): Dictionaries first, as Apple's Settings opens on its
/// list (parity P39); then Reading & Speech; then General; then AI (ADR-0021 d.12); then Setup — the board that used to
/// have a window of its own, now a pane like the rest; and last About (owner, 2026-10-29). The scene's sidebar iterates
/// these cases, so a test of the enum is a test of the panes.
public enum SettingsTab: CaseIterable, Hashable, Sendable {
    case dictionaries
    case readingAndSpeech
    /// The reading history's switch and its two language sets (ADR-0023).
    case learning
    case general
    case ai
    case setup
    /// What this copy is, its licence and its source, and the one update check (owner, 2026-10-29).
    case about

    public var title: LocalizedStringResource {
        switch self {
        case .dictionaries: "Dictionaries"
        case .readingAndSpeech: "Reading & Speech"
        case .learning: "Learning"
        case .general: "General"
        case .ai: "AI"
        case .setup: "Setup"
        case .about: "About"
        }
    }

    public var symbol: String {
        switch self {
        case .dictionaries: "books.vertical"
        case .readingAndSpeech: "book"
        case .learning: "clock.arrow.circlepath"
        case .general: "gearshape"
        case .ai: "sparkles"
        case .setup: "checkmark.seal"
        case .about: "info.circle"
        }
    }
}
