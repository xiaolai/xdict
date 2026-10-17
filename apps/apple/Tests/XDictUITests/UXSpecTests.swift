import Foundation
import Testing
import XDictAnywhere
import XDictContract
import XDictLibrary
import XDictSearch
@testable import XDictUI

/// **Codex's UX decisions of 2026-10-17** (the owner delegated them): the narrow window, the title, the panel's fit,
/// incomplete searches, recent lookups. Each a decision a view makes, without a window.
@MainActor
struct UXSpecTests {
    // §1 (the 640 pt window, the scope as a symbol) and §2 (the headword as the title) were replaced by the owner's
    // Apple parity decisions of 2026-10-17 (P1, P2, P6): `ParityWindowTests` holds the window now. §5's recent lookups
    // went with the sidebar that showed them (P9: Apple's has none).

    // MARK: - §5 incomplete searches

    @Test func noResultsIsQualifiedOnlyWhenSomeDictionaryCouldNotSearch() {
        let complete = EntryPlaceholder.of(noDictionaries: false, query: "zz", selection: nil, searching: false,
                                           unsearched: 0)
        let partial = EntryPlaceholder.of(noDictionaries: false, query: "zz", selection: nil, searching: false,
                                          unsearched: 2)
        #expect(complete == .noResults("zz"))
        #expect(partial == .noResultsIncomplete("zz", unsearched: 2))
        #expect(partial.clearsEntry)
        #expect(String(localized: SearchSentences.unsearched(2)) == "2 dictionaries couldn’t be searched")
    }

    // MARK: - §3 panel

    @Test func thePanelFitsItsEntryBetweenOneFortyAndFiveSixty() {
        #expect(PanelPlacement.minimumHeight == 140 && PanelPlacement.maximumHeight == 560)
        #expect(PanelPlacement.initialHeight == 180)
        #expect(PanelPlacement.height(document: 60, chrome: 37) == 140)
        #expect(PanelPlacement.height(document: 200, chrome: 37) == 237)
        #expect(PanelPlacement.height(document: 900, chrome: 37) == 560)
        #expect(PanelPlacement.height(document: 900, chrome: 37, available: 300) == 300)
        // Opening at the Look Up popover's 390 pt body (P41, 2026-10-17; §3 had 460).
        #expect(PanelPlacement.widths == (min: 360, default: 390, max: 640))
    }

    @Test func aRefitIgnoresSmallChangesAndStaleEntries() {
        var fit = PanelFit()
        fit.began(entry: 1)
        #expect(fit.accepts(height: 300, current: 180, entry: 1))
        #expect(!fit.accepts(height: 301, current: 300, entry: 1), "under 2 pt")
        #expect(!fit.accepts(height: 400, current: 300, entry: 0), "an earlier entry's measure")
        fit.began(entry: 3)
        #expect(fit.accepts(height: 500, current: 300, entry: 3))
    }
}
