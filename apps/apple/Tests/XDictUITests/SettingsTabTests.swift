import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **Settings in five panes** (ADR-0012 d.1, amended 2026-10-20; the AI pane after General is ADR-0021 d.12):
/// Dictionaries, Reading & Speech, General, AI, Setup, in that order. The scene's sidebar iterates `SettingsTab`, so the
/// panes are the enum's cases.
struct SettingsTabTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func settingsHasFivePanesInOrder() {
        #expect(SettingsTab.allCases == [.dictionaries, .readingAndSpeech, .general, .ai, .setup])
        #expect(SettingsTab.allCases.map { Self.text($0.title) }
            == ["Dictionaries", "Reading & Speech", "General", "AI", "Setup"])
        #expect(SettingsTab.allCases.map { Self.text($0.title, "zh-Hans") }
            == ["词典", "阅读与语音", "通用", "AI", "设置向导"])
    }

    /// One symbol each, none shared.
    @Test func eachPaneHasItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(symbols == ["books.vertical", "book", "gearshape", "sparkles", "checkmark.seal"])
    }
}
