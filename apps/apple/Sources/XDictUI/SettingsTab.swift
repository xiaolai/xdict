import Foundation

/// **Settings' panes, in order**: Dictionaries first, as Apple's Settings opens on its list (parity P39); then Reading and
/// Speech, one pane each; then **Lookup** — the shortcut, hover and the popup's appearance, one surface in one place
/// (owner's audit, 2026-10-30) — then Learning, AI (which holds the answer pane's own presentation), General (the app's
/// behaviour and its diagnostics), Setup and About. The scene's sidebar iterates these cases, so a test of the enum is a
/// test of the panes.
public enum SettingsTab: CaseIterable, Hashable, Sendable {
    case dictionaries
    case reading
    case speech
    /// **How looking up behaves** (owner's audit, 2026-10-30: it was four sections in General and the popup's list in a
    /// third pane): the shortcut and the pane's key, hover and its permission, the popup's shade and background.
    case lookup
    /// The reading history's switch and its two language sets (ADR-0023).
    case learning
    case ai
    case general
    case setup
    /// What this copy is, its licence and its source, and the one update check (owner, 2026-10-29).
    case about

    public var title: LocalizedStringResource {
        switch self {
        case .dictionaries: "Dictionaries"
        case .reading: "Reading"
        case .speech: "Speech"
        case .lookup: "Lookup"
        case .learning: "Learning"
        case .ai: "AI"
        case .general: "General"
        case .setup: "Setup"
        case .about: "About"
        }
    }

    public var symbol: String {
        switch self {
        case .dictionaries: "books.vertical"
        case .reading: "book"
        case .speech: "speaker.wave.2"
        case .lookup: "magnifyingglass"
        case .learning: "clock.arrow.circlepath"
        case .ai: "sparkles"
        case .general: "gearshape"
        case .setup: "checkmark.seal"
        case .about: "info.circle"
        }
    }
}
