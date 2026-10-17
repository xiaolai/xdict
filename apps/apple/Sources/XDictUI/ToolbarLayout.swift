import Foundation

/// **The main window's toolbar at every width** (Codex's UX decision §1–§2, 2026-10-17): the search field 200–280 pt
/// and always there; when the detail column is under 560 pt the scope is a symbol and Return to Original Word yields to
/// the overflow menu. Measured on the tour, 2026-10-17: the toolbar's items sit over the detail column only, so a
/// window threshold (Codex's 820) left the full scope pushing search into overflow at 820 with the sidebar open, and
/// a 360 pt detail could not hold Back, Forward, the scope symbol, search and the overflow; 400 can. The sidebar's ideal is
/// 240 so the two fit the 640 pt window as they are: a split squeezed below the sidebar's own width (an ideal of 280 with
/// a 420 detail) pushed the sidebar's content off its leading edge rather than laying it out again. The window's title is the shown entry's headword, "Look Up" before one.
public enum ToolbarLayout {
    public static let compactBelow: CGFloat = 560
    public static let searchWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (200, 240, 280)
    public static let detailMinimum: CGFloat = 400
    public static let sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (220, 240, 420)

    public static func isCompact(width: CGFloat) -> Bool { width < compactBelow }

    public static func windowTitle(headword: String?) -> String {
        headword ?? String(localized: "Look Up")
    }
}
