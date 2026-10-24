/// **Which of the window's panes the reader chose to see** (HIG audit 2026-10-23, UI02, UI05, UI07): the answer pane and
/// the results list. Each has a command and a control that hide and restore it; an ask opens the answer pane; a search
/// brings the results list (P9) unless the reader hid it, and that choice holds across searches until they restore it.
struct SearchPanes: Equatable {
    /// The answer pane (plan-ai-meaning WI-6) is shown.
    private(set) var meaningShown = false
    /// **The examples section** (ADR-0031, plan-reverse-examples WI-5): opened by a Chinese query that found pairs, or
    /// by dictionaries still preparing them; closed by the reader.
    private(set) var examplesShown = false
    /// The reader closed the examples for the lookup shown: a build finishing does not reopen them. A new query does.
    private(set) var examplesDismissed = false
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

    /// A lookup started: the examples belong to the last query until this one's answer comes; a reader's close of the
    /// previous query's examples does not carry over.
    mutating func examplesSearched() {
        examplesShown = false
        examplesDismissed = false
    }

    /// The query's examples arrived: the pane opens unless the reader closed it for this query.
    mutating func examplesAsked() {
        guard !examplesDismissed else { return }
        examplesShown = true
    }

    /// The reader closed the examples section.
    mutating func examplesClosed() {
        examplesShown = false
        examplesDismissed = true
    }

    /// The lookup is not Chinese, or it changed: there is no examples section to show.
    mutating func examplesCleared() {
        examplesShown = false
        examplesDismissed = false
    }

    /// View ▸ Show/Hide Results.
    mutating func toggleResults() { resultsHidden.toggle() }

    /// The split view's binding (the sidebar dragged shut or open). While nothing is listed the split view's own write
    /// is layout, not the reader's choice, and is ignored.
    mutating func setResults(visible: Bool, listed: Bool) {
        guard listed else { return }
        resultsHidden = !visible
    }
}

/// Where the answer is shown (ADR-0030 as revised 2026-10-24: the pane is its own window beside the main one, so the
/// main window keeps its search at the trailing edge and its reading width). Without screen room beside the main
/// window, or in full screen, the same answer uses a sheet. The results list remains the reader's choice.
enum MeaningPlacement: Equatable {
    /// Not asked for, or the native window is not attached yet.
    case hidden
    /// The pane window beside the reading area: full height, its toggle at its top-left.
    case window
    /// A sheet over the window, with Done.
    case sheet
}
