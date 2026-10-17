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
    // MARK: - §1 narrow window

    @Test func belowEightHundredTwentyPointsTheScopeIsASymbol() {
        #expect(ToolbarLayout.isCompact(width: 640))
        #expect(ToolbarLayout.isCompact(width: 819))
        #expect(!ToolbarLayout.isCompact(width: 820))
        #expect(!ToolbarLayout.isCompact(width: 1_000))
        #expect(ToolbarLayout.searchWidth == (min: 200, ideal: 240, max: 280))
        #expect(ToolbarLayout.detailMinimum == 360)
    }

    // MARK: - §2 title

    @Test func theWindowTitleIsTheShownHeadwordOrLookUp() {
        #expect(ToolbarLayout.windowTitle(headword: nil) == String(localized: "Look Up"))
        #expect(ToolbarLayout.windowTitle(headword: "banana") == "banana")
    }

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

    // MARK: - §5 recent lookups

    @Test func recentLookupsAreEightNewestFirstWithoutRepeats() throws {
        let suite = "xdict.tests.recent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentLookups(defaults: defaults)
        for word in ["a", "b", "c", "d", "e", "f", "g", "h", "i"] { recent.add(word) }
        recent.add("c")
        #expect(recent.words == ["c", "i", "h", "g", "f", "e", "d", "b"])
        recent.add("  ")
        #expect(recent.words.count == 8)
        #expect(RecentLookups(defaults: defaults).words == recent.words, "kept across launches")
        recent.clear()
        #expect(recent.words.isEmpty && RecentLookups(defaults: defaults).words.isEmpty)
    }

    // MARK: - §3 panel

    @Test func thePanelFitsItsEntryBetweenOneFortyAndFiveSixty() {
        #expect(PanelPlacement.minimumHeight == 140 && PanelPlacement.maximumHeight == 560)
        #expect(PanelPlacement.initialHeight == 180)
        #expect(PanelPlacement.height(document: 60, chrome: 37) == 140)
        #expect(PanelPlacement.height(document: 200, chrome: 37) == 237)
        #expect(PanelPlacement.height(document: 900, chrome: 37) == 560)
        #expect(PanelPlacement.height(document: 900, chrome: 37, available: 300) == 300)
        #expect(PanelPlacement.widths == (min: 360, default: 460, max: 640))
    }

    @Test func aRefitIgnoresSmallChangesStaleEntriesAndTheReadersOwnSize() {
        var fit = PanelFit()
        fit.began(entry: 1)
        #expect(fit.accepts(height: 300, current: 180, entry: 1))
        #expect(!fit.accepts(height: 301, current: 300, entry: 1), "under 2 pt")
        #expect(!fit.accepts(height: 400, current: 300, entry: 0), "an earlier entry's measure")
        fit.readerResized()
        #expect(!fit.accepts(height: 500, current: 300, entry: 1), "the reader's size is kept")
        fit.began(entry: 2)
        #expect(!fit.accepts(height: 500, current: 300, entry: 2), "until the panel is dismissed")
        fit.dismissed()
        fit.began(entry: 3)
        #expect(fit.accepts(height: 500, current: 300, entry: 3))
    }
}
