import Foundation
import XDictSearch

/// **The main window's measures, as Apple's Dictionary has them** (parity ledger P1, P2, P5, P9; owner's decisions of
/// 2026-10-17, which replace Codex's 640 pt toolbar of the same day): a 400 × 300 pt minimum, the title "Dictionary" with
/// "N found" under it after a search, a search field that grows to Apple's 327 pt, and a sidebar about 183 pt wide that
/// appears only after a search. At the minimum the toolbar's Back/Forward and text-size pairs go to its overflow before
/// the search field does (P8).
public enum ToolbarLayout {
    public static let minimumWindow: (width: CGFloat, height: CGFloat) = (400, 300)
    /// The content's minimum height: the window's less the 52 pt toolbar (measured: 300 pt content made a 352 pt window).
    public static let minimumContentHeight: CGFloat = minimumWindow.height - 52
    public static let searchWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (110, 327, 420)
    public static let sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (150, 183, 320)

    /// Below this window width the title gives way to the search field (P8).
    public static func titleYields(width: CGFloat) -> Bool { width < 560 }

    /// The window's title, always.
    public static var windowTitle: LocalizedStringResource { LocalizedStringResource("Dictionary") }

    /// Under the title after a search: how many headwords the list found; nothing for none, or for spelling guesses.
    public static func subtitle(found: Int?) -> LocalizedStringResource? {
        found.map { LocalizedStringResource("\($0) found") }
    }
}

/// **The scope bar's buttons that fit** (P6, P8): every one when they all fit, else as many as fit beside the »
/// overflow button, "All" always.
public enum ScopeBarLayout {
    public static let height: CGFloat = 36
    public static let buttonHeight: CGFloat = 22
    public static let leading: CGFloat = 7
    public static let moreWidth: CGFloat = 36

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
