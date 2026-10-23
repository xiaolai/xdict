import Foundation
import XDictTokens

/// **Which of the window's panes the reader chose to see** (HIG audit 2026-10-23, UI02, UI05, UI07): the answer pane and
/// the results list. Each has a command and a control that hide and restore it; an ask opens the answer pane; a search
/// brings the results list (P9) unless the reader hid it, and that choice holds across searches until they restore it.
struct SearchPanes: Equatable {
    /// The answer pane (plan-ai-meaning WI-6) is shown.
    private(set) var meaningShown = false
    /// The reader hid the results list while it had results: no search brings it back until they restore it.
    private(set) var resultsHidden = false

    /// View ▸ Show/Hide Meaning in Context, and the toolbar's toggle.
    mutating func toggleMeaning() { meaningShown.toggle() }

    /// An ask or a preview started: the reader's action opens the pane.
    mutating func meaningAsked() { meaningShown = true }

    /// The answer's presentation was dismissed (`MeaningPlacement`): the inspector's own close or the sheet's Done is
    /// the reader's, and closes the answer; a dismissal of the presentation the window just left, because a resize
    /// moved the answer to the other one, is not, and the answer stays asked for.
    mutating func meaningClosed(by presentation: MeaningPlacement, current: MeaningPlacement) {
        guard presentation == current else { return }
        meaningShown = false
    }

    /// Whether the results list shows: only once there is a listing (P9), and only if the reader has not hidden it.
    func resultsVisible(listed: Bool) -> Bool { listed && !resultsHidden }

    /// View ▸ Show/Hide Results.
    mutating func toggleResults() { resultsHidden.toggle() }

    /// The split view's binding (the sidebar dragged shut or open). While nothing is listed the split view's own write
    /// is layout, not the reader's choice, and is ignored.
    mutating func setResults(visible: Bool, listed: Bool) {
        guard listed else { return }
        resultsHidden = !visible
    }
}

/// **Where the answer the reader asked for is shown** (native capture, 2026-10-23: a 400 pt window opening the answer
/// pane aborted in a recursive constraint update; root's policy, 2026-10-23): beside the entry, as the inspector, where
/// the window holds the entry's room — half the least window (P1) — the pane at its ideal, and the results list at its
/// ideal when the reader shows it; narrower, in a sheet over the window. Neither changes the window's width or the
/// results list, which stay the reader's.
///
/// Nothing is presented before the window's width is known, so the first layout never opens the one it then leaves.
enum MeaningPlacement: Equatable {
    /// Not asked for, or the window's width not known yet.
    case hidden
    /// The trailing inspector beside the entry.
    case inspector
    /// A sheet over the window, with Done.
    case sheet

    static func at(width: CGFloat?, results: Bool, meaning: Bool) -> MeaningPlacement {
        guard meaning, let width else { return .hidden }
        return width >= beside(results: results) ? .inspector : .sheet
    }

    /// The least window that holds the inspector: the entry's room, the pane at its ideal, and the list at its ideal
    /// when shown. Ideals, not leasts: SwiftUI counts the list's ideal in the entry column's least (measured), so a
    /// window sized to the leasts was widened by AppKit when the pane opened.
    static func beside(results: Bool) -> CGFloat {
        ToolbarLayout.minimumWindow.width / 2 + Tokens.Window.meaningPaneIdeal + (results ? ToolbarLayout.sidebar.ideal : 0)
    }
}
