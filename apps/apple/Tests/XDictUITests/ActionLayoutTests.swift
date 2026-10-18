import SwiftUI
import Testing
@testable import XDictUI

/// **One set of placement rules for every button of the shell** (owner, 2026-10-18): what the shared blocks decide is
/// tested here; where they put things on screen is layout, which no unit test can see (the guard,
/// `ButtonPlacementTests`, keeps every site on the blocks).
struct ActionLayoutTests {
    /// R1, R2, R3, R4: a pane's actions and a sheet's footer are regular; a strip's or a list row's are small.
    @Test func eachSurfaceHasOneSize() {
        #expect(ActionSurface.pane.controlSize == .regular)
        #expect(ActionSurface.footer.controlSize == .regular)
        #expect(ActionSurface.strip.controlSize == .small)
    }

    /// R3: the destructive action first, apart at the leading edge; Cancel left of the default action, which is last.
    @Test func aFooterReadsDestructiveThenCancelThenTheDefault() {
        #expect(FooterSlot.allCases == [.destructive, .cancel, .primary])
        #expect(FooterSlot.allCases.filter(\.standsApart) == [.destructive])
    }

    /// R3: Escape is Cancel, Return the default action, and a destructive action is never the default.
    @Test func onlyTheDefaultActionTakesReturn() {
        #expect(FooterSlot.cancel.keyEquivalent == .cancelAction)
        #expect(FooterSlot.primary.keyEquivalent == .defaultAction)
        #expect(FooterSlot.destructive.keyEquivalent == nil)
        #expect(FooterSlot.allCases.filter { $0.keyEquivalent == .defaultAction } == [.primary])
    }

    /// R2: a count draws a bar of how far it is, never past full; no count or an empty total draws none.
    @Test func aCountDrawsABarOfHowFarItIs() {
        #expect(ProgressBar.of(done: 3, total: 4) == .fraction(0.75))
        #expect(ProgressBar.of(done: 9, total: 4) == .fraction(1))
        #expect(ProgressBar.of(done: -1, total: 4) == .fraction(0))
        #expect(ProgressBar.of(done: 0, total: 0) == ProgressBar.none)
    }

    /// R2: a fraction not yet known draws a bar that moves without one.
    @Test func anUnknownFractionDrawsAMovingBar() {
        #expect(ProgressBar.of(fraction: nil) == .indeterminate)
        #expect(ProgressBar.of(fraction: 0.5) == .fraction(0.5))
        #expect(ProgressBar.of(fraction: 2) == .fraction(1))
    }
}
