import AppKit
import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **XDict has no Dock icon unless the reader asks for one, and its windows never quit it** (owner, 2026-10-27): off for
/// a reader who never chose, an accessory app with the menu-bar icon as its only residence and its only Quit.
struct DockVisibilityTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.dock.\(UUID().uuidString)"))
    }

    /// **No Dock icon for a reader who never chose**, and therefore no application menu until a window is active.
    @Test func aReaderWhoNeverChoseHasNoDockIcon() throws {
        let dock = DockVisibility(defaults: try suite())
        #expect(!dock.showsInDock)
        #expect(dock.policy == .accessory)
    }

    /// The reader's choice is kept and decides the policy, both ways.
    @Test func theChoiceIsKeptAndDecidesThePolicy() throws {
        let defaults = try suite()
        DockVisibility(defaults: defaults).showsInDock = true
        #expect(DockVisibility(defaults: defaults).policy == .regular)
        DockVisibility(defaults: defaults).showsInDock = false
        #expect(DockVisibility(defaults: defaults).policy == .accessory)
    }

    /// A stored value of another type is not a choice: it reads as the default, never as "show the icon".
    @Test func aStoredValueOfAnotherTypeIsTheDefault() throws {
        let defaults = try suite()
        defaults.set("yes", forKey: DockVisibility.key)
        #expect(!DockVisibility(defaults: defaults).showsInDock)
    }
}

/// **An answer's token budget leaves room for reasoning** (owner, 2026-10-27; sayso 0.5.3's `answerTokens`): sayso's
/// default 1,024 was measured cutting `deepseek-flash` off mid-answer, because a reasoning model spends the budget before
/// it writes anything. XDict asks for 4,096 and the request carries it.
@MainActor
struct AnswerBudgetTests {
    @Test func theRequestCarriesRoomForReasoning() throws {
        let endpoint = try #require(URL(string: "https://example.com/v1"))
        let settings = MeaningSettings(source: .http, endpoint: endpoint, model: "deepseek-flash")
        let configuration = MeaningProviders.httpConfiguration(settings, endpoint: endpoint)
        #expect(configuration.answerTokens == 8_192)
        #expect(MeaningProviders.answerTokens > HTTPProvider.answerTokens,
                "a budget no larger than sayso's default changes nothing")
    }
}
