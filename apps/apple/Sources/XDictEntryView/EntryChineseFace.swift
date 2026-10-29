import AppKit
import XDictTokens

/// **The face Chinese text is drawn in** (owner, 2026-10-29: "中英文混合排版…非常难看"; `dev-docs/note-cjk-typography-2026-10-29.md`):
/// the reading style's own Songti SC unless the reader picks another. The Latin face is not the reader's choice — it is
/// the style's `ui-serif` (New York) — so only the Chinese side moves.
///
/// **A name is not a font.** An unknown family name resolves silently to Helvetica, which has no Han at all (measured:
/// `NSFont(name: "New York")` → Helvetica, and `Hiragino Sans CNS` on a Mac without it too). So a face is offered only
/// when the family the name *resolves to* is the one asked for — tsundoku's `ChineseFace.isInstalled`, kept here.
public enum EntryChineseFace: String, CaseIterable, Sendable {
    /// The reading style's own: the system's Chinese serif, which pairs with New York's serif Latin.
    case songti
    /// The system's Chinese sans: larger on the page, the modern macOS face.
    case pingfang
    /// A brush-like serif, for a reader who wants the dictionary to read as a printed book.
    case kaiti
    /// Hiragino's Simplified cut: a sans with a body between Songti's and PingFang's.
    case hiragino

    /// The family the page is set in for this face.
    public var family: String {
        switch self {
        case .songti: "Songti SC"
        case .pingfang: "PingFang SC"
        case .kaiti: "Kaiti SC"
        case .hiragino: "Hiragino Sans GB"
        }
    }

    /// The CSS font list the page gets: the chosen family, then every family the reading style would have used, so a
    /// character the chosen face lacks still finds a Chinese face rather than a Latin one.
    public var stack: String {
        guard let style = Tokens.ReadingStyle.root.first(where: { $0.0 == "font-cjk" })?.1 else { return "\"\(family)\"" }
        return "\"\(family)\", \(style)"
    }

    /// Whether this Mac can draw it: the family the name resolves to, never the name asked for.
    public var isInstalled: Bool { Self.isInstalled(family) }

    /// Whether the system can draw `family` — the family a name **resolves to**, never the name asked for. `Hiragino
    /// Sans CNS` is not on this Mac and asking for it returns Helvetica; a name that is not installed must read as one.
    public static func isInstalled(_ family: String) -> Bool {
        // The font manager answers nil for a family this Mac does not have — never a substitute: `NSFont(name:)` returns
        // Helvetica for a missing name, and the manager does not.
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }

    /// What Settings calls it: the family's own name, so a reader can match it in Font Book.
    public var title: String { family }
}
