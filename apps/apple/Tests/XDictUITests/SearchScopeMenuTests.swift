import Foundation
import SwiftUI
import Testing
import XDictContract
import XDictSearch
import XDictTestSupport
import XDictUI

/// **The search scope's values** (P6, XDict's own since 2026-10-18: 24 dictionaries overflowed Apple's scope bar; P7,
/// P8, P42): All Dictionaries, then each enabled dictionary in the reader's order, the chosen one checked, one that
/// cannot answer greyed, each with the Search menu's key; the placeholder names a single dictionary. The search field
/// is SwiftUI's `.searchable` (owner, 2026-10-24), so these are plain values with no AppKit field behind them.
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
    /// order), so the picker mirrors the shortcuts and they reach what it offers.
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

    /// The heading has a key of its own: "Search in" is the Details sheet's search-language picker (LibraryDetail),
    /// 查询语言 in Chinese, and a shared key made that picker read 搜索范围 (acceptance, 2026-10-18).
    @Test func theMenuTitleAndTheDetailsPickerKeepTheirOwnWords() {
        let picker = LocalizedStringResource("Search in")
        #expect(Self.chinese(picker) == "查询语言")
        #expect(Self.chinese(SearchScopeMenu.title) != Self.chinese(picker))
        #expect(SearchScopeMenu.title.key != picker.key)
    }

    /// A scope no longer known (a restored history entry naming a removed dictionary) is every dictionary, as the
    /// model searches it: All Dictionaries is checked, matching the placeholder.
    @Test func aRemovedScopeChecksAllDictionaries() {
        let items = SearchScopeMenu.items(known: Self.known, scope: .one(UUID()))
        #expect(items.map(\.checked) == [true, false, false, false])
        #expect(SearchScopeMenu.items(known: Self.known, scope: .one(Self.off.id)).map(\.checked)
                    == [true, false, false, false], "a disabled dictionary is not offered, so not chosen")
    }

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
