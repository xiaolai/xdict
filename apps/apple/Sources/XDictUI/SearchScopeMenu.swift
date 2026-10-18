import AppKit
import SwiftUI
import XDictSearch
import XDictTokens

/// **The scope menu** (parity P6, XDict's own since 2026-10-18: the owner's option A, after 24 dictionaries overflowed
/// Apple's scope bar; P7, P8, P42): the search field's magnifier drops down "Search In" — All Dictionaries, then each
/// enabled dictionary by name in the reader's order, the chosen one checked, one that cannot answer greyed, each beside
/// the Search menu's key for the same scope (⌘0, ⌘1–⌘9). It is AppKit's own `searchMenuTemplate`, so the field keeps
/// every other behaviour of an `NSSearchField`. The choice stays in sight: the placeholder says "Search in <name>" for
/// one dictionary, and the magnifier turns the accent colour.
public enum SearchScopeMenu {
    /// One line of the menu.
    public struct Item: Equatable {
        public let scope: SearchScope
        public let title: String
        public let checked: Bool
        /// False for a dictionary that cannot answer now, as the Search menu greys it.
        public let enabled: Bool
        /// The Search menu's key for this scope, with ⌘; none after the ninth dictionary.
        public let key: String?
    }

    /// What a line carries to the field's target: its scope, and whether it may be chosen now.
    public final class Choice: NSObject {
        public let scope: SearchScope
        let enabled: Bool
        init(_ scope: SearchScope, enabled: Bool) { (self.scope, self.enabled) = (scope, enabled) }
    }

    /// The menu's heading and the magnifier's accessibility name, in a menu heading's title case ("Sort By" in Finder).
    /// Its own key: "Search in" is the Details sheet's search-language picker, worded otherwise in Chinese.
    public static let title = LocalizedStringResource("Search In")

    /// The scopes, in the menu's order: every dictionary, then each enabled dictionary in the reader's order — the
    /// Search menu's order, and the one Select Next/Previous Dictionary steps through (`SearchModel.stepScope`).
    public static func scopes(_ known: [SearchSource]) -> [SearchScope] {
        [.all] + known.filter(\.enabled).map { .one($0.id) }
    }

    /// The lines for `scope`, checked by the scope searched: one no longer offered (removed, or disabled since a
    /// history entry named it) is every dictionary, as the placeholder and the button's value say.
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

    /// The menu AppKit copies onto the magnifier. Its copy enables lines by validation whatever the template says, so
    /// the target answers `validate` too.
    @MainActor
    static func menu(_ items: [Item], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: String(localized: title))
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: String(localized: title)))
        for item in items {
            let line = NSMenuItem(title: item.title, action: action, keyEquivalent: item.key ?? "")
            line.keyEquivalentModifierMask = .command
            line.target = target
            line.representedObject = Choice(item.scope, enabled: item.enabled)
            line.state = item.checked ? .on : .off
            line.isEnabled = item.enabled
            menu.addItem(line)
        }
        return menu
    }

    /// Whether a line of the menu may be chosen: a dictionary that cannot answer now is greyed.
    @MainActor
    public static func validate(_ line: NSMenuItem) -> Bool {
        (line.representedObject as? Choice)?.enabled ?? false
    }

    /// Whether `items` narrow the search to one dictionary: the magnifier changes then.
    public static func isNarrowed(_ items: [Item]) -> Bool {
        items.contains { $0.checked && $0.scope != .all }
    }

    /// The magnifier while one dictionary is chosen: filled and in the accent colour, so a narrowed search is seen
    /// before the placeholder is read.
    @MainActor
    static var narrowedMagnifier: NSImage? {
        let colour = NSImage.SymbolConfiguration(hierarchicalColor: Tokens.Colour.accent.nsColor)
        let image = NSImage(systemSymbolName: "magnifyingglass.circle.fill",
                            accessibilityDescription: nil)?.withSymbolConfiguration(colour)
        image?.isTemplate = false
        return image
    }
}

extension KeyboardSearchField {
    /// The scope menu on the magnifier, its look and its accessibility, for `items`.
    func showScopes(_ items: [SearchScopeMenu.Item], target: AnyObject, action: Selector) {
        guard items != scopes else { return }
        scopes = items
        searchMenuTemplate = SearchScopeMenu.menu(items, target: target, action: action)
        guard let button = (cell as? NSSearchFieldCell)?.searchButtonCell else { return }
        if plainMagnifier == nil { plainMagnifier = button.image }
        let chosen = items.first(where: \.checked)
        button.image = SearchScopeMenu.isNarrowed(items) ? SearchScopeMenu.narrowedMagnifier : plainMagnifier
        button.setAccessibilityIdentifier("scope.menu")
        button.setAccessibilityLabel(String(localized: SearchScopeMenu.title))
        button.setAccessibilityValue(chosen?.title ?? String(localized: SearchSentences.allDictionaries))
    }
}
