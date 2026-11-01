import AppKit
import XDictCapture
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
            },
            openMeaning: { result, reading in
                // **The card's own sentence, once, on the reader's tap** (ADR-0021 d.1, ADR-0037): the hand-off is
                // built here from the reading, never from a guess at the sentence, and the window asks at its draw.
                XDictApp.historyDrawer.hide()
                NSApp.activate()
                let handoff = MeaningHandoff(
                    term: reading.surface,
                    sentence: reading.sentence,
                    range: reading.span.map { NSRange(location: Int($0.start), length: Int($0.len)) },
                    cut: CutEnds(rawValue: Int(reading.cut)),
                    origin: MeaningOrigin(request: nextOrigin(), generation: 0))
                MainWindows.hand(HistoryEntryLink.visit(opening: result), meaning: handoff, asking: true)
                if !MainWindows.deliver() { MenuBarActions.openMain() }
            })
        XDictApp.history.entryLinks = links
        XDictApp.history.answers = XDictApp.meaningAnswers
        XDictApp.study.entryLinks = links
        // **The answer memory follows the history switch** (ADR-0037): nothing is stored while it is off, and turning
        // it off clears what is held — the answer and the glosses — at once rather than at the next drawer refresh.
        XDictApp.meaningAnswers.isHistoryEnabled = { LearningPreferences.shared.historyEnabled }
        LearningPreferences.shared.onHistoryChanged = { enabled in
            if !enabled { XDictApp.history.historySwitchedOff() }
        }
    }

    /// **A history hand-off's own origin**: the capture's request counter means nothing here, and a value another
    /// presentation already used would let it be mistaken for that one. A counter is enough for one launch.
    @MainActor private static var origin = 0

    @MainActor private static func nextOrigin() -> Int {
        origin += 1
        return origin
    }
}
