import Foundation
import Observation
import Testing
@testable import XDictUI

/// **A value kept in step with what it reads** (L14): the menu bar's tooltip was set once at launch and kept that
/// shortcut through every change. `Observed.follow` applies the value now and again after each change.
@MainActor
struct ObservedTests {
    @Observable @MainActor final class Source {
        var name = "⌘⇧D"
    }

    @MainActor final class Seen {
        var values: [String] = []
    }

    @Test func eachChangeIsAppliedNotOnlyTheFirstValue() async {
        let source = Source()
        let seen = Seen()
        Observed.follow({ "press \(source.name)" }, apply: { seen.values.append($0) })
        #expect(seen.values == ["press ⌘⇧D"])
        source.name = "⌥Space"
        await Self.settle { seen.values.count == 2 }
        source.name = "none"
        await Self.settle { seen.values.count == 3 }
        #expect(seen.values == ["press ⌘⇧D", "press ⌥Space", "press none"], "every change, not only the first")
    }

    static func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            await Task.yield()
        }
    }
}

/// **A conflict row names its device so a reader can tell two apart** (L14): the ledger has no device names, and the row
/// showed the whole UUID. This Mac is named; another device is the UUID's first four characters.
struct ConflictDeviceNameTests {
    @Test func thisMacIsNamedAndAnotherIsShort() {
        let mine = "6F1C2A9E-0000-4000-8000-000000000001"
        let other = "b7d3e1f0-1111-4111-8111-111111111111"
        #expect(ReviewView.deviceName(mine, thisDevice: mine) == String(localized: "This Mac"))
        let named = ReviewView.deviceName(other, thisDevice: mine)
        #expect(named.contains("B7D3"), "the short form: \(named)")
        #expect(!named.contains(other) && !named.contains("1111"), "never the whole identifier: \(named)")
    }
}
