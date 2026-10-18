import SwiftUI
import Testing
@testable import XDictUI

/// **One set of placement rules for every button of the shell** (owner, 2026-10-18): what the shared blocks decide is
/// tested here; where they put things on screen is layout, which no unit test can see (the guard,
/// `ButtonPlacementTests`, keeps every site on the blocks).
struct ActionLayoutTests {
    /// R1, R2, R3, R4: a pane's actions, a sheet's footer and an empty state's are regular; a strip's or a list row's
    /// are small.
    @Test func eachSurfaceHasOneSize() {
        #expect(ActionSurface.pane.controlSize == .regular)
        #expect(ActionSurface.footer.controlSize == .regular)
        #expect(ActionSurface.emptyState.controlSize == .regular)
        #expect(ActionSurface.strip.controlSize == .small)
    }

    /// R3: the destructive action first, apart at the leading edge; Cancel left of the default action, which is last.
    /// `SheetFooter`'s body lays out exactly this list.
    @Test func aFooterReadsDestructiveThenCancelThenTheDefault() {
        #expect(FooterItem.arrangement(closesOnEscape: false) == [.destructive, .gap, .cancel, .primary])
        #expect(FooterItem.arrangement(closesOnEscape: true) == [.destructive, .gap, .closeOnEscape, .primary])
        for closes in [false, true] {
            let items = FooterItem.arrangement(closesOnEscape: closes)
            let escape = items.firstIndex { $0.keyEquivalent == .cancelAction }
            let primary = items.firstIndex(of: .primary)
            #expect(items.first == .destructive)
            #expect(items.last == .primary)
            #expect(escape.map { index in primary.map { index < $0 } ?? false } ?? false)
        }
    }

    /// R3: Escape and Return are each bound once — Escape to Cancel (or, with no Cancel, to closing the sheet), Return
    /// to the default action — and a destructive action is never the default.
    @Test func escapeAndReturnAreEachBoundOnce() {
        for closes in [false, true] {
            let keys = FooterItem.arrangement(closesOnEscape: closes).map(\.keyEquivalent)
            #expect(keys.filter { $0 == .cancelAction }.count == 1)
            #expect(keys.filter { $0 == .defaultAction }.count == 1)
        }
        #expect(FooterItem.primary.keyEquivalent == .defaultAction)
        #expect(FooterItem.destructive.keyEquivalent == nil)
        #expect(FooterItem.gap.keyEquivalent == nil)
    }

    /// The details sheet has no Cancel (what it changes applies at once), so Escape closes it and Done stays the
    /// default (verifier, 2026-10-18: on main, Escape did nothing there).
    @MainActor @Test func theDetailsSheetClosesOnEscape() {
        let footer = SettingsDictionaries.detailsFooter(remove: {}, close: {})
        #expect(Self.triples(footer.placements) == [
            Triple(.destructive, nil, .destructive), Triple(.gap, nil, .gap),
            Triple(.closeOnEscape, .cancelAction, .hidden), Triple(.primary, .defaultAction, .standard),
        ])
        #expect(footer.placements.map(\.action?.title) == [Text("Remove from Library"), nil, Text(verbatim: ""), Text("Done")])
    }

    // MARK: - What SheetFooter's body places in each slot

    /// One placement as the body draws it: which slot, the key it binds, how it looks.
    struct Triple: Equatable {
        let item: FooterItem
        let key: KeyboardShortcut?
        let style: FooterStyle
        init(_ item: FooterItem, _ key: KeyboardShortcut?, _ style: FooterStyle) {
            self.item = item
            self.key = key
            self.style = style
        }
    }

    static func triples(_ placements: [FooterPlacement]) -> [Triple] {
        placements.map { Triple($0.item, $0.key, $0.style) }
    }

    static var remove: FooterAction { FooterAction(.destructive, title: Text("Remove from Library")) {} }
    static var cancel: FooterAction { FooterAction(.cancel, title: Text("Cancel")) {} }
    static var done: FooterAction { FooterAction(.primary, title: Text("Done")) {} }

    /// R3, as the body draws it (`SheetFooter.body` draws `placements` and nothing else): each action in its own slot,
    /// whatever order it was given in, with its key and its look. Swapping Cancel and the default action fails here.
    @MainActor @Test func eachActionLandsInItsOwnSlotWithItsKey() {
        let placements = FooterPlacement.placements([Self.done, Self.cancel, Self.remove], closeOnEscape: nil)
        #expect(Self.triples(placements) == [
            Triple(.destructive, nil, .destructive), Triple(.gap, nil, .gap),
            Triple(.cancel, .cancelAction, .standard), Triple(.primary, .defaultAction, .standard),
        ])
        #expect(placements.map(\.action?.title) == [Text("Remove from Library"), nil, Text("Cancel"), Text("Done")])
        #expect(placements.allSatisfy { $0.action?.role == $0.item.role })
    }

    /// A slot with no action takes no room; Escape's hidden button binds Escape, and only it.
    @MainActor @Test func anEmptySlotTakesNoRoomAndTheHiddenButtonBindsEscape() {
        #expect(Self.triples(FooterPlacement.placements([Self.done], closeOnEscape: nil)) == [
            Triple(.gap, nil, .gap), Triple(.primary, .defaultAction, .standard),
        ])
        let closing = FooterPlacement.placements([Self.done], closeOnEscape: {})
        #expect(Self.triples(closing) == [
            Triple(.gap, nil, .gap), Triple(.closeOnEscape, .cancelAction, .hidden),
            Triple(.primary, .defaultAction, .standard),
        ])
    }

    /// An empty state's ways on: the first one, prominent only when a second sits under it.
    @Test func anEmptyStateLeadsWithItsFirstWayOn() {
        #expect(EmptyStateItem.arrangement(hasSecondary: true) == [.primary, .secondary])
        #expect(EmptyStateItem.arrangement(hasSecondary: false) == [.primary])
        #expect(EmptyStateItem.primary.isProminent(hasSecondary: true))
        #expect(!EmptyStateItem.primary.isProminent(hasSecondary: false))
        #expect(!EmptyStateItem.secondary.isProminent(hasSecondary: true))
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
