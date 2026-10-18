import AppKit
import Foundation
import Testing
@testable import XDictUI

struct PanelAppearanceTests {
    private func defaults() throws -> UserDefaults {
        let suite = "PanelAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func nothingSetIsTheSystemGlassAsItWas() throws {
        let appearance = PanelAppearance.current(in: try defaults())
        #expect(appearance == PanelAppearance(shade: .system, solidity: 0))
        #expect(appearance.appearance == nil)
    }

    @Test func whatTheReaderSetIsRead() throws {
        let store = try defaults()
        store.set("dark", forKey: PanelAppearance.shadeKey)
        store.set(0.4, forKey: PanelAppearance.solidityKey)
        let appearance = PanelAppearance.current(in: store)
        #expect(appearance.shade == .dark)
        #expect(appearance.solidity == 0.4)
        #expect(appearance.appearance?.name == .darkAqua)
        #expect(PanelAppearance(shade: .light).appearance?.name == .aqua)
    }

    @Test func nonsenseIsTheDefaultNotACrash() throws {
        let store = try defaults()
        store.set("purple", forKey: PanelAppearance.shadeKey)
        store.set(7.5, forKey: PanelAppearance.solidityKey)
        let appearance = PanelAppearance.current(in: store)
        #expect(appearance.shade == .system)
        #expect(appearance.solidity == 1)
        #expect(PanelAppearance(solidity: -3).solidity == 0)
        #expect(PanelAppearance(solidity: .nan).solidity == 0)
    }
}
