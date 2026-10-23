import AppKit
import XDictContract
import XDictLibrary
import XDictSearch
import XDictUI

/// **Where a history card or a review card opens its entry** (UI46, UI48): the reading's own edition, resolved against
/// the library as it is now, and the exact record handed to a main window the way the popover's expansion hands one —
/// the most recent window, or a new one that takes the place when it is made. Anything the library cannot open is
/// explained by the card, never guessed.
@MainActor
enum HistoryRoutes {
    static func install() {
        let links = HistoryEntryLinks(
            resolve: { HistoryEntryLink.resolve($0, in: XDictApp.library.entries) },
            open: { visit in
                XDictApp.historyDrawer.hide()
                NSApp.activate()
                MainWindows.hand(visit)
                if !MainWindows.deliver() { MenuBarActions.openMain() }
            })
        XDictApp.history.entryLinks = links
        XDictApp.study.entryLinks = links
    }
}
