import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **Settings in nine panes** (ADR-0012 d.1; the owner's audit of 2026-10-30 gave Lookup and Speech their own panes, the
/// answer pane to AI, and General back to the app around the reading): Dictionaries, Reading, Speech, Lookup, Learning,
/// AI, General, Setup, About, in that order. The scene's sidebar iterates `SettingsTab`, so the panes are the enum's
/// cases.
struct SettingsTabTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func settingsHasNinePanesInOrder() {
        #expect(SettingsTab.allCases == [.dictionaries, .reading, .speech, .lookup, .learning, .ai, .general, .setup, .about])
        #expect(SettingsTab.allCases.map { Self.text($0.title) }
            == ["Dictionaries", "Reading", "Speech", "Lookup", "Learning", "AI", "General", "Setup", "About"])
        #expect(SettingsTab.allCases.map { Self.text($0.title, "zh-Hans") }
            == ["词典", "阅读", "语音", "查词", "学习", "AI", "通用", "设置向导", "关于"])
    }

    /// One symbol each, none shared.
    @Test func eachPaneHasItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(symbols == ["books.vertical", "book", "speaker.wave.2", "magnifyingglass", "clock.arrow.circlepath",
                            "sparkles", "gearshape", "checkmark.seal", "info.circle"])
    }
}
