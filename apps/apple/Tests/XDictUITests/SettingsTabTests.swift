import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **Settings in three panes** (ADR-0012 d.1): Dictionaries, Reading & Speech, General, in that order. The scene's
/// `TabView` iterates `SettingsTab`, so the panes are the enum's cases.
struct SettingsTabTests {
    static func text(_ resource: LocalizedStringResource, _ language: String = "en") -> String {
        (try? CompiledCatalog.text(resource, in: language)) ?? "the catalog did not compile"
    }

    @Test func settingsHasThreePanesInOrder() {
        #expect(SettingsTab.allCases == [.dictionaries, .readingAndSpeech, .general])
        #expect(SettingsTab.allCases.map { Self.text($0.title) } == ["Dictionaries", "Reading & Speech", "General"])
        #expect(SettingsTab.allCases.map { Self.text($0.title, "zh-Hans") } == ["词典", "阅读与语音", "通用"])
    }

    /// One symbol each, none shared.
    @Test func eachPaneHasItsOwnSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(symbols == ["books.vertical", "book", "gearshape"])
    }
}
