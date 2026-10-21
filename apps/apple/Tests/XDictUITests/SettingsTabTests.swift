import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **Settings in six panes** (ADR-0012 d.1, amended 2026-10-20; the AI pane after General is ADR-0021 d.12; the Learning
/// pane after Reading & Speech is ADR-0023): Dictionaries, Reading & Speech, Learning, General, AI, Setup, in that order.
/// The scene's sidebar iterates `SettingsTab`, so the panes are the enum's cases.
struct SettingsTabTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func settingsHasSixPanesInOrder() {
        #expect(SettingsTab.allCases == [.dictionaries, .readingAndSpeech, .learning, .general, .ai, .setup])
        #expect(SettingsTab.allCases.map { Self.text($0.title) }
            == ["Dictionaries", "Reading & Speech", "Learning", "General", "AI", "Setup"])
        #expect(SettingsTab.allCases.map { Self.text($0.title, "zh-Hans") }
            == ["词典", "阅读与语音", "学习", "通用", "AI", "设置向导"])
    }

    /// One symbol each, none shared.
    @Test func eachPaneHasItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(symbols == ["books.vertical", "book", "clock.arrow.circlepath", "gearshape", "sparkles", "checkmark.seal"])
    }
}
