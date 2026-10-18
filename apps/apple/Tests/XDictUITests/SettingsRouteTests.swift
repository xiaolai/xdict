import Foundation
import Testing
import XDictUI

/// **Opening Settings on a dictionary is routed, not hoped for** (ADR-0012 d.4), and **one presentation at a time**
/// (d.3): the route's decisions, without a window.
@MainActor
struct SettingsRouteTests {
    static let alpha = UUID()
    static let beta = UUID()

    /// Settings not yet open: the request waits for the pane, which takes it when it appears.
    @Test func coldOpenSelectsWhenThePaneAppears() {
        var opened = 0
        let route = SettingsRoute(open: { opened += 1 })
        route.show(Self.alpha)
        #expect(opened == 1)
        #expect(route.pane == .dictionaries)
        #expect(route.resolveSelection(among: [Self.beta, Self.alpha]) == .select(Self.alpha))
        // Taken once: a later appearance leaves the reader's own selection alone.
        #expect(route.resolveSelection(among: [Self.beta, Self.alpha]) == .unchanged)
    }

    /// Settings open on another pane: it switches to Dictionaries.
    @Test func anotherPaneSwitchesToDictionaries() {
        let route = SettingsRoute(open: {})
        route.pane = .general
        route.show(Self.beta)
        #expect(route.pane == .dictionaries)
        #expect(route.resolveSelection(among: [Self.alpha, Self.beta]) == .select(Self.beta))
    }

    /// Details shown: the sheet closes, the selection moves.
    @Test func detailsCloseAndTheSelectionMoves() {
        let route = SettingsRoute(open: {})
        #expect(route.request(.details(Self.alpha)))
        route.show(Self.beta)
        #expect(route.presentation == .none)
        #expect(route.resolveSelection(among: [Self.alpha, Self.beta]) == .select(Self.beta))
    }

    /// A dictionary removed meanwhile: the selection falls back, and the pane says why.
    @Test func aRemovedDictionaryFallsBackAndIsSaid() {
        let route = SettingsRoute(open: {})
        route.show(Self.alpha)
        #expect(route.resolveSelection(among: [Self.beta]) == .removed)
        #expect(route.removedNotice)
        route.show(nil)
        #expect(!route.removedNotice)
    }

    /// From the menu bar with no window open: the route opens Settings itself, and nothing is pending but the pane.
    @Test func theMenuBarAloneOpensSettings() {
        var opened = 0
        let route = SettingsRoute(open: { opened += 1 })
        route.show(nil)
        #expect(opened == 1)
        #expect(route.pane == .dictionaries)
        #expect(route.resolveSelection(among: []) == .unchanged)
    }

    /// Add Dictionaries… from anywhere: Settings on Dictionaries with the file importer up.
    @Test func anImportRequestOpensTheImporter() {
        var opened = 0
        let route = SettingsRoute(open: { opened += 1 })
        route.pane = .readingAndSpeech
        route.requestImport()
        #expect(opened == 1)
        #expect(route.pane == .dictionaries)
        #expect(route.presentation == .importer)
    }

    /// A request while another is shown is queued, never shown over it nor dropped; the same one again is a no-op.
    @Test func aRequestWhilePresentedIsQueued() {
        let route = SettingsRoute(open: {})
        #expect(route.request(.details(Self.alpha)))
        #expect(!route.request(.importer))
        #expect(route.presentation == .details(Self.alpha))
        #expect(route.request(.details(Self.alpha)))
        route.dismiss()
        #expect(route.presentation == .importer)
        route.dismiss()
        #expect(route.presentation == .none)
    }

    /// Locate… from Details: the sheet gives way to the importer, in that order.
    @Test func locateFromDetailsOpensTheImporter() {
        let route = SettingsRoute(open: {})
        _ = route.request(.details(Self.alpha))
        route.locate()
        #expect(route.presentation == .importer)
    }

    /// Dismissing what is no longer shown changes nothing (a stale binding's write).
    @Test func dismissingSomethingElseIsIgnored() {
        let route = SettingsRoute(open: {})
        _ = route.request(.importer)
        route.dismiss(.details(Self.alpha))
        #expect(route.presentation == .importer)
        route.dismiss(.importer)
        #expect(route.presentation == .none)
    }
}
