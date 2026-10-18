import Foundation
import XDictSearch
import XDictTokens

/// **The main window's measures, as Apple's Dictionary has them** (parity ledger P1, P2, P5, P9; owner's decisions of
/// 2026-10-17, which replace Codex's 640 pt toolbar of the same day): a 400 × 300 pt minimum, the title "XDict" (P2, XDict's own) with
/// "N found" under it after a search, a search field that grows to Apple's 327 pt, and a sidebar about 183 pt wide that
/// appears only after a search. At the minimum the toolbar's Back/Forward and text-size pairs go to its overflow before
/// the search field does (P8).
public enum ToolbarLayout {
    public static let minimumWindow: (width: CGFloat, height: CGFloat) = (Tokens.Window.mainMinimumWidth,
                                                                         Tokens.Window.mainMinimumHeight)
    /// The content's minimum height: the window's less the 52 pt toolbar (measured: 300 pt content made a 352 pt window).
    public static let minimumContentHeight: CGFloat = minimumWindow.height - Tokens.Control.toolbar
    public static let searchWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (
        Tokens.Window.searchFieldMin, Tokens.Window.searchFieldIdeal, Tokens.Window.searchFieldMax)
    public static let sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (
        Tokens.Window.sidebarMin, Tokens.Window.sidebarIdeal, Tokens.Window.sidebarMax)

    /// Below this width the title gives way to the search field (P8).
    public static func titleYields(width: CGFloat) -> Bool { width < Tokens.Window.titleYields }

    /// The title sits over the content column, beside the field: it gives way when that column, the window less the
    /// sidebar, is narrow. A 583 pt window with the 183 pt sidebar a search brings leaves a 400 pt column; Apple's
    /// 444 pt window with its sidebar shows no title.
    public static func titleYields(window: CGFloat, sidebar: CGFloat) -> Bool { titleYields(width: window - sidebar) }

    /// The search field's width in a window `window` points wide (P5): Apple's 327 pt at its 859 pt window, in proportion
    /// to the window between the field's least and most. Given to the field as its width, not a range: a toolbar sizes a
    /// hosted AppKit view by its ideal, and an `NSSearchField` has no intrinsic width, so a min/max range alone left it
    /// near its least whatever the window (owner, 2026-10-18: "search field's width is too short").
    public static func searchFieldWidth(window: CGFloat) -> CGFloat {
        let scaled = (searchWidth.ideal * window / Tokens.Window.searchFieldAtWindow).rounded()
        return min(max(scaled, searchWidth.min), searchWidth.max)
    }

    /// The window's title, always: "XDict", where Apple's says "Dictionary" (P2, the owner's deviation of 2026-10-18).
    public static var windowTitle: LocalizedStringResource { LocalizedStringResource("XDict") }

    /// Under the title after a search: how many headwords the list found; nothing for none, or for spelling guesses.
    public static func subtitle(found: Int?) -> LocalizedStringResource? {
        found.map { LocalizedStringResource("\($0) found") }
    }
}

/// **The scope bar's buttons that fit** (P6, P8): every one when they all fit, else as many as fit beside the »
/// overflow button, "All" always.
public enum ScopeBarLayout {
    public static let height: CGFloat = Tokens.Control.scopeBar
    public static let buttonHeight: CGFloat = Tokens.Row.scopeButton
    public static let leading: CGFloat = Tokens.Inset.scopeLeading
    public static let moreWidth: CGFloat = Tokens.Control.scopeMore

    /// How many of the buttons, of `widths` in order, show in `available` points.
    public static func shown(widths: [CGFloat], available: CGFloat) -> Int {
        let room = available - leading
        if widths.reduce(0, +) <= room { return widths.count }
        var used: CGFloat = 0, count = 0
        for width in widths {
            guard used + width <= room - moreWidth else { break }
            used += width
            count += 1
        }
        return max(min(1, widths.count), count)
    }

    /// The scopes the bar offers, in its order: All, then each enabled dictionary in the reader's order.
    public static func scopes(_ known: [SearchSource]) -> [SearchScope] {
        [.all] + known.filter(\.enabled).map { .one($0.id) }
    }
}
