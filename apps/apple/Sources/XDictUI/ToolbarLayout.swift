import Foundation

/// **The main window's toolbar at every width** (Codex's UX decision §1–§2, 2026-10-17): the search field 200–280 pt
/// and always there; below 820 pt the scope is a symbol and Return to Original Word yields to the overflow menu; the
/// detail never under 360 pt. The window's title is the shown entry's headword, "Look Up" before one.
public enum ToolbarLayout {
    public static let compactBelow: CGFloat = 820
    public static let searchWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (200, 240, 280)
    public static let detailMinimum: CGFloat = 360
    public static let sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (220, 280, 420)

    public static func isCompact(width: CGFloat) -> Bool { width < compactBelow }

    public static func windowTitle(headword: String?) -> String {
        headword ?? String(localized: "Look Up")
    }
}
