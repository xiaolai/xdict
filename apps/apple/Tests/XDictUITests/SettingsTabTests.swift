import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **Settings in four panes** (ADR-0012 d.1, amended 2026-10-20): Dictionaries, Reading & Speech, General, Setup, in that
/// order. The scene's sidebar iterates `SettingsTab`, so the panes are the enum's cases.
struct SettingsTabTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func settingsHasFourPanesInOrder() {
        #expect(SettingsTab.allCases == [.dictionaries, .readingAndSpeech, .general, .setup])
        #expect(SettingsTab.allCases.map { Self.text($0.title) } == ["Dictionaries", "Reading & Speech", "General", "Setup"])
        #expect(SettingsTab.allCases.map { Self.text($0.title, "zh-Hans") } == ["词典", "阅读与语音", "通用", "设置向导"])
    }

    /// One symbol each, none shared.
    @Test func eachPaneHasItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(symbols == ["books.vertical", "book", "gearshape", "checkmark.seal"])
    }
}
