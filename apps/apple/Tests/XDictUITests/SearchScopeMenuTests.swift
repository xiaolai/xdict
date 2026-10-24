import AppKit
import Foundation
import SwiftUI
import Testing
import XDictContract
import XDictSearch
import XDictTestSupport
@testable import XDictUI

/// **The scope menu** (P6, XDict's own since 2026-10-18: 24 dictionaries overflowed the scope bar; P7, P8, P42): the
/// search field's magnifier drops down "Search In": All Dictionaries, then each enabled dictionary in the reader's order,
/// the chosen one checked, one that cannot answer greyed, each with the Search menu's key. The chosen scope stays in
/// sight: the placeholder names a single dictionary and the magnifier changes. Read on AppKit's own `NSSearchField`, its
/// `searchMenuTemplate` and the search button's accessibility element, with the field's own coordinator as the target,
/// without a window on screen.
@MainActor
struct SearchScopeMenuTests {
    static func source(_ name: String, enabled: Bool = true, ready: Bool = true) -> SearchSource {
        SearchSource(id: UUID(), name: name, edition: nil, preferencesKey: name, enabled: enabled,
                     state: ready ? .ready(DictId(rawValue: name)) : .indexing(fraction: nil))
    }

    static let alpha = source("Alpha")
    static let off = source("Off", enabled: false)
    static let beta = source("Beta", ready: false)
    static let gamma = source("Gamma")
    static let known = [alpha, off, beta, gamma]

    static func english(_ resource: LocalizedStringResource) -> String {
        (try? CompiledCatalog.text(resource, in: "en")) ?? "the catalog did not compile"
    }

    static func chinese(_ resource: LocalizedStringResource) -> String {
        (try? CompiledCatalog.text(resource, in: "zh-Hans")) ?? "the catalog did not compile"
    }

    /// What the window is given when a line is chosen (`state.model.setScope`).
    final class Chosen {
        var scopes: [SearchScope] = []
    }

    /// The search field's own coordinator, its parent handing a chosen scope to `chosen`.
    static func coordinator(_ chosen: Chosen = Chosen()) -> SearchField.Coordinator {
        let coordinator = SearchField.Coordinator()
        coordinator.parent = SearchField(text: "", prompt: "Search", onScope: { chosen.scopes.append($0) }, focus: 0,
                                         onChange: { _ in }, onSubmit: {}, onMove: { _ in false },
                                         onCancel: { false })
        return coordinator
    }

    static func show(_ field: KeyboardSearchField, _ scope: SearchScope, _ coordinator: SearchField.Coordinator) {
        field.showScopes(SearchScopeMenu.items(known: known, scope: scope), target: coordinator,
                         action: #selector(SearchField.Coordinator.choseScope(_:)))
    }

    static func field(_ scope: SearchScope, _ coordinator: SearchField.Coordinator) -> KeyboardSearchField {
        let field = KeyboardSearchField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        show(field, scope, coordinator)
        return field
    }

    /// What the search button's accessibility element answers, as VoiceOver and the drivers read it.
    static func button(_ field: NSSearchField, _ attribute: String) -> Any? {
        guard let cell = field.cell as? NSSearchFieldCell, let element = cell.accessibilitySearchButton() as? NSObject
        else { return nil }
        let read = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: read) else { return nil }
        return element.perform(read, with: attribute)?.takeUnretainedValue()
    }

    /// The menu the magnifier drops down: AppKit's copy of the template, on the search button's cell.
    static func dropped(_ field: NSSearchField) -> NSMenu? {
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.menu
    }

    // MARK: - The items

    @Test func allThenEachEnabledDictionaryInTheReadersOrder() {
        let items = SearchScopeMenu.items(known: Self.known, scope: .all)
        #expect(items.map(\.scope) == [.all, .one(Self.alpha.id), .one(Self.beta.id), .one(Self.gamma.id)])
        #expect(items.map(\.title) == [String(localized: SearchSentences.allDictionaries), "Alpha", "Beta", "Gamma"])
        #expect(items.map(\.checked) == [true, false, false, false])
        #expect(items.map(\.enabled) == [true, true, false, true], "a dictionary that cannot answer is greyed")
        #expect(SearchScopeMenu.items(known: Self.known, scope: .one(Self.gamma.id)).map(\.checked)
                    == [false, false, false, true])
        // The same scopes, in the same order, as Select Next/Previous Dictionary steps through.
        #expect(items.map(\.scope) == SearchScopeMenu.scopes(Self.known))
    }

    /// **P7**: each item carries the Search menu's key for the same scope (⌘0, then ⌘1–⌘9 by the enabled dictionaries'
    /// order), so the menu mirrors the shortcuts and they reach what the menu offers.
    @Test func eachItemMirrorsTheSearchMenusKey() throws {
        let many = (1...11).map { Self.source("D\($0)") }
        let items = SearchScopeMenu.items(known: many, scope: .all)
        try #require(items.count == many.count + 1)
        #expect(items[0].key == String(ScopeShortcut.all.character))
        for (index, source) in many.enumerated() {
            #expect(items[index + 1].scope == .one(source.id))
            #expect(items[index + 1].key == ScopeShortcut.dictionary(index).map { String($0.character) })
        }
        #expect(items[10].key == nil && items[11].key == nil, "no key after the ninth, as in the Search menu")
    }

    // MARK: - The scope in sight

    @Test func thePlaceholderNamesASingleDictionaryInBothLanguages() {
        #expect(Self.english(SearchScopeMenu.prompt(known: Self.known, scope: .all)) == "Search")
        #expect(Self.chinese(SearchScopeMenu.prompt(known: Self.known, scope: .all)) == "搜索")
        let one = SearchScopeMenu.prompt(known: Self.known, scope: .one(Self.gamma.id))
        #expect(Self.english(one) == "Search in Gamma")
        #expect(Self.chinese(one) == "在 Gamma 中搜索")
        // A scope no longer known reads as every dictionary, which the model falls back to.
        #expect(Self.english(SearchScopeMenu.prompt(known: Self.known, scope: .one(UUID()))) == "Search")
        #expect(Self.english(SearchScopeMenu.title) == "Search In")
        #expect(Self.chinese(SearchScopeMenu.title) == "搜索范围")
    }

    /// The menu's heading has a key of its own: "Search in" is the Details sheet's search-language picker
    /// (LibraryDetail), 查询语言 in Chinese, and a shared key made that picker read 搜索范围 (acceptance, 2026-10-18).
    @Test func theMenuTitleAndTheDetailsPickerKeepTheirOwnWords() {
        let picker = LocalizedStringResource("Search in")
        #expect(Self.chinese(picker) == "查询语言")
        #expect(Self.chinese(SearchScopeMenu.title) != Self.chinese(picker))
        #expect(SearchScopeMenu.title.key != picker.key)
    }

    /// A scope no longer known (a restored history entry naming a removed dictionary) is every dictionary, as the
    /// model searches it: All Dictionaries is checked, matching the button's value and the placeholder.
    @Test func aRemovedScopeChecksAllDictionaries() {
        let items = SearchScopeMenu.items(known: Self.known, scope: .one(UUID()))
        #expect(items.map(\.checked) == [true, false, false, false])
        #expect(SearchScopeMenu.items(known: Self.known, scope: .one(Self.off.id)).map(\.checked)
                    == [true, false, false, false], "a disabled dictionary is not offered, so not chosen")
    }

    /// The window's own wiring (`SearchWindow.searchField`, what its toolbar shows): the placeholder, the menu and
    /// so the magnifier follow the model's scope, never a constant.
    @Test func theWindowWiresTheFieldToTheScope() {
        func field(_ scope: SearchScope) -> ToolbarSearchItem {
            SearchWindow.searchField(text: "", known: Self.known, scope: scope, focus: 0, onScope: { _ in },
                                     onChange: { _ in }, onSubmit: {}, onMove: { _ in false }, onCancel: { false })
        }
        #expect(field(.all).prompt == String(localized: SearchScopeMenu.prompt(known: Self.known, scope: .all)))
        let gamma = field(.one(Self.gamma.id))
        #expect(gamma.prompt == String(localized: SearchScopeMenu.prompt(known: Self.known, scope: .one(Self.gamma.id))))
        #expect(gamma.prompt != field(.all).prompt, "one dictionary is named in the placeholder")
        #expect(gamma.scopes == SearchScopeMenu.items(known: Self.known, scope: .one(Self.gamma.id)))
        #expect(SearchScopeMenu.isNarrowed(gamma.scopes) && !SearchScopeMenu.isNarrowed(field(.all).scopes))
    }

    @Test func theMagnifierChangesWhenOneDictionaryIsChosen() throws {
        let coordinator = Self.coordinator()
        let field = Self.field(.all, coordinator)
        let button = try #require((field.cell as? NSSearchFieldCell)?.searchButtonCell)
        let plain = button.image
        #expect(plain != nil)
        Self.show(field, .one(Self.alpha.id), coordinator)
        #expect(button.image != nil && button.image !== plain, "one dictionary: a magnifier of its own")
        #expect(button.image?.isTemplate == false, "tinted, not drawn as a template in the label colour")
        Self.show(field, .all, coordinator)
        #expect(button.image === plain, "every dictionary again: AppKit's own magnifier")
    }

    // MARK: - The menu on the field

    @Test func theFieldsMenuIsSearchInWithEveryScope() throws {
        let field = Self.field(.one(Self.alpha.id), Self.coordinator())
        let menu = try #require(Self.dropped(field), "the magnifier drops down no menu")
        #expect(field.searchMenuTemplate != nil)
        let header = try #require(menu.items.first)
        #expect(header.isSectionHeader && header.title == String(localized: SearchScopeMenu.title))
        let scopes = Array(menu.items.dropFirst())
        #expect(scopes.map(\.title) == [String(localized: SearchSentences.allDictionaries), "Alpha", "Beta", "Gamma"])
        #expect(scopes.map(\.state) == [.off, .on, .off, .off])
        #expect(scopes.map(\.isEnabled) == [true, true, false, true])
        // AppKit's copy of the template enables its items by validation: the target's answer keeps one greyed.
        let validated = scopes.map { ($0.target as? any NSMenuItemValidation)?.validateMenuItem($0) }
        #expect(validated == [true, true, false, true], "an unavailable dictionary stays greyed when the menu opens")
        #expect(scopes.map(\.keyEquivalent) == ["0", "1", "2", "3"])
        #expect(scopes.allSatisfy { $0.keyEquivalentModifierMask == .command })
    }

    /// The round trip: choosing an item gives its scope to the window (`state.model.setScope`), and the scope given back
    /// re-checks the menu and changes the button's value.
    @Test func choosingAnItemReachesTheWindowAndComesBackChecked() throws {
        let chosen = Chosen()
        let coordinator = Self.coordinator(chosen)
        let field = Self.field(.all, coordinator)
        let gamma = try #require(Self.dropped(field)?.items.first { $0.title == "Gamma" })
        let action = try #require(gamma.action)
        #expect(NSApplication.shared.sendAction(action, to: gamma.target, from: gamma))
        #expect(chosen.scopes == [.one(Self.gamma.id)])
        let scope = try #require(chosen.scopes.last)
        Self.show(field, scope, coordinator)
        #expect(Self.dropped(field)?.items.dropFirst().map(\.state) == [.off, .off, .off, .on])
        #expect(Self.button(field, "AXValue") as? String == "Gamma")
    }

    // MARK: - Accessibility

    /// **P42**: the magnifier is a button named "Search In", identified `scope.menu`, its value the chosen scope, and
    /// it offers its menu (AXShowMenu) — what replaces the scope bar's radio group.
    @Test func theMenuButtonReadsItsNameAndTheChosenScope() throws {
        let coordinator = Self.coordinator()
        let field = Self.field(.all, coordinator)
        #expect(Self.button(field, "AXRole") as? String == "AXButton")
        #expect(Self.button(field, "AXDescription") as? String == String(localized: SearchScopeMenu.title))
        #expect(Self.button(field, "AXIdentifier") as? String == "scope.menu")
        #expect(Self.button(field, "AXValue") as? String == String(localized: SearchSentences.allDictionaries))
        Self.show(field, .one(Self.alpha.id), coordinator)
        #expect(Self.button(field, "AXValue") as? String == "Alpha")
        let element = try #require((field.cell as? NSSearchFieldCell)?.accessibilitySearchButton() as? NSObject)
        let names = element.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String]
        #expect(names?.contains("AXShowMenu") == true)
    }

    // MARK: - The scope bar is gone

    /// The deletion guard: no scope bar, its layout, its radio group or its 36 pt row remains in the shell's sources or
    /// its tokens; the entry starts under the toolbar.
    @Test func noScopeBarRemains() throws {
        let sources = try SourceScan.files(under: Manifest.package.appending(path: "Sources"))
        #expect(!sources.isEmpty)
        let hits = sources.filter { _, text in
            ["ScopeBar", "scope.bar", "scope.option", "ScopeRadioGroup", "Control.scopeBar"].contains { text.contains($0) }
        }
        #expect(hits.map(\.file.lastPathComponent) == [])
        let tokens = try String(contentsOf: Manifest.package.appending(path: "Tokens/tokens.toml"), encoding: .utf8)
        #expect(!tokens.contains("scopeBar") && !tokens.contains("scopeMore") && !tokens.contains("scopeButton"))
    }
}
