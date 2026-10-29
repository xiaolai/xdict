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

/// **A dictionary window brings the Dock icon while it is open** (owner, 2026-10-29: "when dictionary main window is
/// opening, the dock icon should show up"), and the last one closing puts XDict back in the menu bar alone. The policy
/// reaches the running app through `setPolicy`, so a test records it instead of changing its own process's Dock.
///
/// **A stand-in, not an `NSWindow`**: this test process cannot make an `NSApplication` (`NSApplication.shared` alone
/// seizes it, measured 2026-10-29), and `DockPresence` keeps a window by identity and hears `NSWindow.willCloseNotification`
/// — neither needs a real window. The app's probe hands it the real one.
@MainActor
struct DockPresenceTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.presence.\(UUID().uuidString)"))
    }

    /// What a window is to the registry: an object it can key on and hear about.
    private func window() -> NSObject { NSObject() }

    private func close(_ window: NSObject) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    }

    @Test func aWindowBringsTheDockIconAndItsClosingTakesItAway() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = DockPresence(defaults: try suite(), setPolicy: { policies.append($0) })
        #expect(presence.policy == .accessory, "no window, and the reader never asked")
        let main = window()
        presence.opened(main)
        #expect(presence.hasWindow)
        #expect(presence.policy == .regular)
        #expect(policies.last == .regular)
        close(main)
        #expect(!presence.hasWindow)
        #expect(presence.policy == .accessory)
        #expect(policies.last == .accessory)
    }

    /// Opening the same window twice (SwiftUI moves a window's views about) counts it once, and one window closing among
    /// several leaves the icon up.
    @Test func oneWindowClosingLeavesTheOthers() throws {
        let presence = DockPresence(defaults: try suite(), setPolicy: { _ in })
        let first = window()
        let second = window()
        presence.opened(first)
        presence.opened(first)
        presence.opened(second)
        close(first)
        #expect(presence.hasWindow)
        #expect(presence.policy == .regular)
        close(second)
        #expect(!presence.hasWindow)
        #expect(presence.policy == .accessory)
    }

    /// The reader's own switch outlives the windows: on, the icon stays with none open.
    @Test func theReadersChoiceKeepsTheIconWithNoWindow() throws {
        let defaults = try suite()
        DockVisibility(defaults: defaults).showsInDock = true
        let presence = DockPresence(defaults: defaults, setPolicy: { _ in })
        #expect(presence.policy == .regular)
        let main = window()
        presence.opened(main)
        close(main)
        #expect(presence.policy == .regular)
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
