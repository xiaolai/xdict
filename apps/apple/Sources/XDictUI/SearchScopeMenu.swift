import Foundation
import SwiftUI
import XDictSearch

/// **The search scope's values** (parity P6, XDict's own since 2026-10-18: 24 dictionaries overflowed Apple's scope
/// bar; P7, P8, P42): All Dictionaries, then each enabled dictionary by name in the reader's order, the chosen one
/// checked, one that cannot answer greyed, each beside the Search menu's key for the same scope (⌘0, ⌘1–⌘9). The choice
/// stays in sight: the placeholder says "Search in <name>" for one dictionary. Since the search field is SwiftUI's
/// `.searchable` (owner, 2026-10-24), the values are rendered by SwiftUI — the magnifier's AppKit menu is gone.
public enum SearchScopeMenu {
    /// One line of the scope picker.
    public struct Item: Equatable, Hashable {
        public let scope: SearchScope
        public let title: String
        public let checked: Bool
        /// False for a dictionary that cannot answer now, as the Search menu greys it.
        public let enabled: Bool
        /// The Search menu's key for this scope, with ⌘; none after the ninth dictionary.
        public let key: String?
    }

    /// The picker's heading, in a menu heading's title case ("Sort By" in Finder). Its own key: "Search in" is the
    /// Details sheet's search-language picker, worded otherwise in Chinese.
    public static let title = LocalizedStringResource("Search In")

    /// The scopes, in the menu's order: every dictionary, then each enabled dictionary in the reader's order — the
    /// Search menu's order, and the one Select Next/Previous Dictionary steps through (`SearchModel.stepScope`).
    public static func scopes(_ known: [SearchSource]) -> [SearchScope] {
        [.all] + known.filter(\.enabled).map { .one($0.id) }
    }

    /// The lines for `scope`, checked by the scope searched: one no longer offered (removed, or disabled since a
    /// history entry named it) is every dictionary, as the placeholder says.
    public static func items(known: [SearchSource], scope asked: SearchScope) -> [Item] {
        let offered = scopes(known)
        let scope = offered.contains(asked) ? asked : .all
        let all = Item(scope: .all, title: String(localized: SearchSentences.allDictionaries), checked: scope == .all,
                       enabled: true, key: String(ScopeShortcut.all.character))
        let each = known.filter(\.enabled).enumerated().map { index, source in
            Item(scope: .one(source.id), title: source.name, checked: scope == .one(source.id),
                 enabled: source.handle != nil, key: ScopeShortcut.dictionary(index).map { String($0.character) })
        }
        return [all] + each
    }

    /// The field's placeholder: "Search" for every dictionary, "Search in <name>" for one.
    public static func prompt(known: [SearchSource], scope: SearchScope) -> LocalizedStringResource {
        guard case .one(let id) = scope, let source = known.first(where: { $0.id == id && $0.enabled }) else {
            return LocalizedStringResource("Search")
        }
        return LocalizedStringResource("Search in \(source.name)")
    }

    /// Whether `items` narrow the search to one dictionary.
    public static func isNarrowed(_ items: [Item]) -> Bool {
        items.contains { $0.checked && $0.scope != .all }
    }
}
