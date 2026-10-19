import Foundation
import Testing
import XDictUI

/// **Closing the last window keeps XDict in the menu bar, unless the reader says otherwise** (XiaolaiDict's menu-bar
/// app kept running with every window closed; ported as a Settings ▸ General switch, on by default). The decision the app
/// delegate asks, through the injected suite.
struct MenuBarResidenceTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.residence.\(UUID().uuidString)"))
    }

    /// **On for a reader who never chose**: the last window closing does not quit, so the shortcut, the Service and hover
    /// keep working from the menu-bar item. Red if the unset value quits.
    @Test func aReaderWhoNeverChoseKeepsXDictRunning() throws {
        let residence = MenuBarResidence(defaults: try suite())
        #expect(residence.keepsRunning)
        #expect(!residence.terminatesAfterLastWindowClosed)
    }

    /// **The reader's choice is kept, and decides the delegate's answer**, both ways.
    @Test func theChoiceIsKeptAndDecidesTheAnswer() throws {
        let defaults = try suite()
        MenuBarResidence(defaults: defaults).keepsRunning = false
        #expect(MenuBarResidence(defaults: defaults).terminatesAfterLastWindowClosed)
        MenuBarResidence(defaults: defaults).keepsRunning = true
        #expect(!MenuBarResidence(defaults: defaults).terminatesAfterLastWindowClosed)
    }

    /// **A stored value of another type is not a choice**: it reads as the default, never as "quit".
    @Test func aStoredValueOfAnotherTypeIsTheDefault() throws {
        let defaults = try suite()
        defaults.set("no", forKey: MenuBarResidence.key)
        #expect(MenuBarResidence(defaults: defaults).keepsRunning)
    }
}
