import AppKit
import Foundation
import Testing
import XDictTokens
@testable import XDictUI

/// **The reader decides which panes the window shows** (HIG audit 2026-10-23, UI01, UI02, UI07, UI08): the answer pane
/// and the results list each have a command that hides and restores them, a search does not override a reader who hid
/// the results, the result list never scrolls its headwords' leading letters out of view, and a window is titled by
/// the word it shows.
@MainActor
struct SearchPanesTests {
    @Test func theAnswerPaneIsShownAndHiddenByTheReader() {
        var panes = SearchPanes()
        #expect(!panes.meaningShown)
        panes.toggleMeaning()
        #expect(panes.meaningShown)
        panes.toggleMeaning()
        #expect(!panes.meaningShown)
        // The inspector's own close (the system's binding) is the reader's too.
        panes.meaningAsked()
        panes.meaningClosed(by: .window, current: .window)
        #expect(!panes.meaningShown)
    }

    /// **The Examples section** (ADR-0031, plan-reverse-examples WI-5): a query's pairs open it, the reader's close
    /// holds for that query, and a later query asks again.
    @Test func theExamplesPaneOpensForAQueryAndHoldsTheReadersClose() {
        var panes = SearchPanes()
        #expect(!panes.examplesShown && !panes.examplesDismissed)
        panes.examplesSearched()
        panes.examplesAsked()
        #expect(panes.examplesShown)
        panes.examplesClosed()
        #expect(!panes.examplesShown && panes.examplesDismissed)
        panes.examplesAsked()
        #expect(!panes.examplesShown, "a build finishing does not reopen what the reader closed")
        panes.examplesSearched()
        panes.examplesAsked()
        #expect(panes.examplesShown, "a new query asks again")
        panes.examplesCleared()
        #expect(!panes.examplesShown && !panes.examplesDismissed)
    }

    @Test func hiddenResultsStayHiddenAcrossSearches() {
        var panes = SearchPanes()
        #expect(!panes.resultsVisible(listed: false), "no sidebar before a search (P9)")
        #expect(panes.resultsVisible(listed: true), "the first search brings it (P9)")
        panes.toggleResults()
        #expect(!panes.resultsVisible(listed: true), "a deliberate hide holds while the listing stays")
        // A new search's listing does not bring it back: the reader's choice stands.
        #expect(!panes.resultsVisible(listed: true))
        panes.toggleResults()
        #expect(panes.resultsVisible(listed: true))
        // Dragging the sidebar shut is the same choice as the command.
        panes.setResults(visible: false, listed: true)
        #expect(!panes.resultsVisible(listed: true))
        // While nothing is listed, the split view's own write is not a reader's choice.
        panes.setResults(visible: true, listed: false)
        #expect(!panes.resultsVisible(listed: true))
    }

    @Test func theResultListNeverScrollsItsLeadingEdgeOutOfView() {
        let clip = HeadwordClipView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
        let table = HeadwordTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        clip.documentView = table
        clip.scroll(to: NSPoint(x: 40, y: 30))
        #expect(clip.bounds.origin.x == 0, "the headwords' first letters were scrolled away")
        #expect(clip.bounds.origin.y == 30, "vertical scrolling is untouched")
    }

    @Test func aWindowIsTitledByTheWordItShows() {
        #expect(ToolbarLayout.windowTitle(word: "serendipity") == "serendipity")
        #expect(ToolbarLayout.windowTitle(word: "  ") == String(localized: ToolbarLayout.windowTitle))
        #expect(ToolbarLayout.windowTitle(word: nil) == String(localized: ToolbarLayout.windowTitle))
    }

    /// **Only the reader closes the answer** (root's policy, 2026-10-23): a resize that moves it between the sheet and
    /// the inspector dismisses the one it leaves, and that dismissal is not the reader's close; Done in the sheet or the
    /// inspector's own close is. The results list is never touched.
    @Test func aPresentationChangeIsNotTheReadersClose() {
        var panes = SearchPanes()
        panes.meaningAsked()
        panes.meaningClosed(by: .sheet, current: .window)
        #expect(panes.meaningShown, "the window widened: the sheet went, the inspector holds the same answer")
        panes.meaningClosed(by: .window, current: .sheet)
        #expect(panes.meaningShown, "the window narrowed: the inspector went, the sheet holds the same answer")
        panes.meaningClosed(by: .sheet, current: .hidden)
        #expect(panes.meaningShown, "the width is not known yet")
        panes.meaningClosed(by: .sheet, current: .sheet)
        #expect(!panes.meaningShown, "Done")
        panes.meaningAsked()
        panes.meaningClosed(by: .window, current: .window)
        #expect(!panes.meaningShown, "the inspector's own close")
        #expect(panes.resultsVisible(listed: true), "no presentation of the answer moves the results list")
    }
}
