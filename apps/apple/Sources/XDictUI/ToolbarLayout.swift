import Foundation
import XDictTokens

/// **The main window's measures, as Apple's Dictionary has them** (parity ledger P1, P2, P9; owner's decisions of
/// 2026-10-17, which replace Codex's 640 pt toolbar of the same day): a 400 × 300 pt minimum, the title "XDict" (P2,
/// XDict's own) with "N found" under it after a search, and a sidebar about 183 pt wide that appears only after a
/// search. The search field is SwiftUI's `.searchable` (owner, 2026-10-24): the system owns its width, its collapse and
/// its place in the toolbar's overflow.
public enum ToolbarLayout {
    public static let minimumWindow: (width: CGFloat, height: CGFloat) = (Tokens.Window.mainMinimumWidth,
                                                                         Tokens.Window.mainMinimumHeight)
    /// The content's minimum height: the window's less the 52 pt toolbar (measured: 300 pt content made a 352 pt window).
    public static let minimumContentHeight: CGFloat = minimumWindow.height - Tokens.Control.toolbar
    public static let sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (
        Tokens.Window.sidebarMin, Tokens.Window.sidebarIdeal, Tokens.Window.sidebarMax)

    /// Below this width the title gives way to the search field (P8).
    public static func titleYields(width: CGFloat) -> Bool { width < Tokens.Window.titleYields }

    /// The title sits over the content column, beside the field: it gives way when that column, the window less the
    /// sidebar, is narrow. A 583 pt window with the 183 pt sidebar a search brings leaves a 400 pt column; Apple's
    /// 444 pt window with its sidebar shows no title.
    public static func titleYields(window: CGFloat, sidebar: CGFloat) -> Bool { titleYields(width: window - sidebar) }

    /// The window's title, always: "XDict", where Apple's says "Dictionary" (P2, the owner's deviation of 2026-10-18).
    public static var windowTitle: LocalizedStringResource { LocalizedStringResource("XDict") }

    /// **A window's title: the word it shows, else "XDict"** (HIG audit 2026-10-23, UI08, revisiting P2 at the owner's
    /// approval): the Window menu and Mission Control tell two untabbed windows apart by what they show; the title stays
    /// concise, one word. `windowTitle` above stays the empty window's.
    public static func windowTitle(word: String?) -> String { tabTitle(word: word) }

    /// A tab's label: the word it shows, else the window's title. The window's own title stays "XDict" (above); a
    /// tab with the same text as every other tab tells the reader nothing (owner, 2026-10-18).
    public static func tabTitle(word: String?) -> String {
        let trimmed = word?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: windowTitle) : trimmed
    }

    /// Under the title after a search: how many headwords the list found; nothing for none, or for spelling guesses.
    public static func subtitle(found: Int?) -> LocalizedStringResource? {
        found.map { LocalizedStringResource("\($0) found") }
    }
}
