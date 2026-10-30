import Foundation
import Testing
import XDictTestSupport
@testable import XDictUI

/// **Settings search** (UI30) and **the selected pane's title** (UI31): a concept finds its pane and its row, by label or
/// by a common synonym, including rows inside a disclosure.
struct SettingsSearchTests {
    static func panes(_ query: String) -> [SettingsTab] {
        SettingsSearch.results(query).map(\.pane)
    }

    @Test func conceptsFindTheirPanes() {
        #expect(Self.panes("shortcut").contains(.lookup))
        #expect(Self.panes("hover").first == .lookup)
        #expect(Self.panes("voice").first == .speech)
        #expect(Self.panes("history").first == .learning)
        #expect(Self.panes("AI source").first == .ai)
        #expect(Self.panes("privacy").contains(.ai))
        #expect(Self.panes("privacy").contains(.learning))
        #expect(Self.panes("sync").first == .learning)
        #expect(Self.panes("accessibility").contains(.setup))
        #expect(Self.panes("import").first == .dictionaries)
    }

    /// A row inside the AI pane's advanced disclosure is found too, and says it is there.
    @Test func aRowInsideADisclosureIsFound() {
        let prompt = SettingsSearch.results("prompt")
        #expect(prompt.first?.pane == .ai)
        #expect(prompt.first?.anchor == SettingsSearch.Anchor.aiPrompt)
        #expect(prompt.first?.isAdvanced == true)
    }

    /// **The prompt's two newer kinds are searchable** (contract 6; audit rd 1): the editor lists translation and
    /// grammar templates, so a reader looking for either must find the same row.
    @Test func thePromptsNewerKindsAreSearchable() {
        for query in ["translation", "grammar", "翻译", "语法"] {
            #expect(SettingsSearch.results(query).contains { $0.anchor == SettingsSearch.Anchor.aiPrompt },
                    "\(query) does not find the prompt editor")
        }
    }

    @Test func caseAndOrderAreForgiven() {
        #expect(Self.panes("SHORTCUT") == Self.panes("shortcut"))
        #expect(Self.panes("source ai").first == .ai)
        #expect(SettingsSearch.results("").isEmpty)
        #expect(SettingsSearch.results("qqqq").isEmpty)
    }

    @Test func localizedConceptsMatchWithinCompoundLabels() {
        #expect(SettingsSearch.matches("快捷键", title: "查词快捷键", keywords: ["shortcut"]))
        #expect(SettingsSearch.matches("提示词", title: "自定义提示词", keywords: ["prompt"]))
        #expect(SettingsSearch.matches("历史", title: "阅读历史记录", keywords: ["history"]))
        #expect(SettingsSearch.matches("同步", title: "同步文件夹", keywords: ["sync"]))
        #expect(!SettingsSearch.matches("不存在", title: "查词快捷键", keywords: ["shortcut"]))
    }

    @Test func commonChineseConceptsAreSearchable() {
        #expect(Self.panes("隐私").contains(.learning))
        #expect(Self.panes("隐私").contains(.ai))
        #expect(Self.panes("语音").contains(.speech))
        #expect(Self.panes("快捷键").contains(.lookup))
        #expect(Self.panes("提示词").contains(.ai))
    }

    @Test func latinAliasesStillMatchAtWordBeginnings() {
        #expect(!SettingsSearch.matches("ai", title: "Dictionaries", keywords: ["details"]))
        #expect(Self.panes("ai").first == .ai)
    }

    /// **The answer pane's toggle is findable by what it does** (2026-10-24): the row's label is "Toggle the pane", and
    /// a reader searching "toggle" must land on it.
    @Test func theAnswerPanesToggleIsFound() {
        #expect(SettingsSearch.results("toggle").first?.anchor == SettingsSearch.Anchor.meaningPaneGap)
        #expect(SettingsSearch.results("animation").first?.anchor == SettingsSearch.Anchor.meaningPaneGap)
        #expect(SettingsSearch.results("width").contains { $0.anchor == SettingsSearch.Anchor.meaningPaneGap })
    }

    @MainActor @Test func aRevealIsConsumedWithoutEatingANewerRequest() throws {
        let route = SettingsRoute()
        let prompt = try #require(SettingsSearch.results("prompt").first)
        route.reveal(prompt)
        let old = route.revealSerial
        route.reveal(prompt)
        route.didReveal(serial: old)
        #expect(route.revealed == .aiPrompt)
        route.didReveal(serial: route.revealSerial)
        #expect(route.revealed == nil)
    }

    @Test func everySearchAnchorHasAViewTarget() throws {
        let source = try SourceScan.files(under: Manifest.package.appending(path: "Sources"))
            .map(\.text).joined(separator: "\n")
        for anchor in SettingsSearch.Anchor.allCases {
            let found = source.contains(".settingsAnchor(.\(anchor.rawValue))")
            #expect(found, "No view installs the Settings target \(anchor.rawValue)")
        }
    }

    /// Every result has its own anchor, so revealing it is unambiguous.
    @Test func everyItemHasItsOwnAnchor() {
        let anchors = SettingsSearch.items.map(\.anchor)
        #expect(Set(anchors).count == anchors.count)
        #expect(Set(SettingsSearch.items.map(\.pane)) == Set(SettingsTab.allCases))
    }

    /// The pane's title is its sidebar name, one source for both.
    @Test func thePaneTitleIsItsName() {
        for pane in SettingsTab.allCases {
            #expect(String(localized: pane.paneTitle) == String(localized: pane.title))
        }
    }

    @MainActor @Test func choosingTheSameResultRequestsAnotherReveal() throws {
        let route = SettingsRoute()
        let prompt = try #require(SettingsSearch.results("prompt").first)
        route.reveal(prompt)
        let first = route.revealSerial
        route.reveal(prompt)
        #expect(route.revealed == .aiPrompt)
        #expect(route.revealSerial > first)
    }

    /// A result opens its pane and marks its row; a cold Settings is opened.
    @MainActor @Test func revealingAResultOpensItsPane() throws {
        var opened = 0
        let route = SettingsRoute(open: { opened += 1 })
        let prompt = try #require(SettingsSearch.results("prompt").first)
        route.reveal(prompt)
        #expect(route.pane == .ai)
        #expect(route.revealed == .aiPrompt)
        #expect(opened == 1)
    }
}
