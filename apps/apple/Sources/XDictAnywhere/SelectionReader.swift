import AppKit
import ApplicationServices
import XDictBase
import os

/// The app a selection is read from, captured on the main actor before the Accessibility work moves off it.
public struct FrontApp: Hashable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?

    public init(pid: pid_t, name: String, bundleID: String?) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
    }

    /// The frontmost app, with a process ID Accessibility can use. **macOS 27 reports some apps — Safari, launched from
    /// a system cryptex — with process ID -1** (XiaolaiDict, measured); the window server knows the real one, and is
    /// asked only then: the owner of an on-screen ordinary window whose app has that bundle identifier.
    @MainActor
    public static func frontmost() -> FrontApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(resolving)
    }

    /// `app`, with a process ID Accessibility can use.
    @MainActor
    public static func resolving(_ app: NSRunningApplication) -> FrontApp? {
        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        if app.processIdentifier > 0 { return FrontApp(pid: app.processIdentifier, name: name, bundleID: app.bundleIdentifier) }
        guard let bundle = app.bundleIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let owner = windows.lazy
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
            .first { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == bundle }
        return owner.map { FrontApp(pid: $0, name: name, bundleID: bundle) }
    }
}

/// Where the selected term is on screen: **y down, from the primary screen's top-left**, as the Accessibility API
/// answers. `exact` is the term's own box; `containing` holds the punctuation trimmed from it too.
public struct SelectionBox: Hashable, Sendable {
    public enum Quality: Hashable, Sendable { case exact, containing }
    public let rect: CGRect
    public let quality: Quality

    public init(rect: CGRect, quality: Quality) {
        self.rect = rect
        self.quality = quality
    }

    /// A box worth trusting, or none: finite, with area.
    static func checked(_ box: CGRect, quality: Quality) -> SelectionBox? {
        guard !box.isNull, !box.isInfinite, box.minX.isFinite, box.minY.isFinite, box.width.isFinite,
              box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        return SelectionBox(rect: box, quality: quality)
    }
}

/// What the reader had selected, and in which app.
public struct SelectedText: Hashable, Sendable {
    /// The term looked up (`LookupText`): the selection less its wrapping punctuation.
    public let text: String
    public let app: FrontApp

    public init(text: String, app: FrontApp) {
        self.text = text
        self.app = app
    }
}

/// Why nothing could be looked up from the selection, **typed**: the view layer words it (`AnywhereSentences`).
public enum SelectionRefusal: Hashable, Sendable {
    /// Nothing is selected, or the app does not expose its selection.
    case nothingSelected(app: String)
    /// The focused element had nothing, and the window was too large to search for a page — not the same as knowing
    /// there is no selection.
    case searchLimitReached(app: String, limit: Int)
    /// Only whitespace and punctuation.
    case noWord(app: String)
    case tooLong(app: String, characters: Int)
    case failed(CaptureError, app: String)
    /// This process may not read other apps: Accessibility is not granted.
    case notTrusted
    /// No app is in front to read.
    case noApp
}

public enum SelectionOutcome: Hashable, Sendable {
    /// What was selected — and where it is on screen, where the app could say: what the panel is placed by.
    case selected(SelectedText, box: SelectionBox?)
    case nothing(SelectionRefusal)
}

/// **Reads the frontmost app's selection through the Accessibility API** (plan-macos-v1 WI-8, I2; moved from
/// XiaolaiDict's `SelectionReader`). Apps speak one of two dialects:
///
/// - **text range**: `AXSelectedText` and `AXSelectedTextRange` — Cocoa text views (TextEdit, Notes);
/// - **text markers**: `AXSelectedTextMarkerRange` — WebKit (Safari, Mail) and Chromium.
///
/// **Re-checked against the MDX-first model** (ADR-0001): XDict looks the term up in the reader's dictionaries and puts
/// the panel by the word, and keeps no reading history, so XiaolaiDict's sentence context, provenance and lemma stayed
/// behind with the study ledger they served. What came: the dialects, the page search, waking Chromium, the term's own
/// box read back before it is believed, and every number from another process checked before it is summed.
public enum SelectionReader {
    /// The whole read, however many requests it takes.
    public static let budget: Duration = .seconds(2)
    /// Nodes visited looking for a browser window's page. A tree this search cannot cross is reported, not treated as
    /// "no page".
    public static let webAreaSearchLimit = 400

    /// Synchronous IPC into another app, so it runs detached — never on the main actor, whose panel must appear within
    /// its budget whatever the app does. This process's own windows are read on the main actor instead: a request
    /// about this process is serviced in-process, and SwiftUI must be asked from the main thread.
    public static func read(from app: FrontApp) async -> SelectionOutcome {
        guard AXIsProcessTrusted() else { return .nothing(.notTrusted) }
        if app.pid == getpid() { return await MainActor.run { readNow(app) } }
        let work = Task.detached(priority: .userInitiated) { () -> SelectionOutcome in
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AccessibilitySession.messagingTimeout)
            return readNow(app)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func readNow(_ app: FrontApp) -> SelectionOutcome {
        read(application: AXUIElementCreateApplication(app.pid), of: app, with: AccessibilitySession(budget: budget))
    }

    /// The whole read, against any Accessibility client — the real one, or a test's.
    public static func read(application: AXUIElement, of app: FrontApp, with ax: some AccessibilityReading) -> SelectionOutcome {
        do {
            try ax.wake(application)
            switch try find(in: application, ax) {
            case .found(let capture):
                switch LookupText.term(capture.text) {
                case .empty: return .nothing(.nothingSelected(app: app.name))
                case .noWord: return .nothing(.noWord(app: app.name))
                case .tooLong(let characters): return .nothing(.tooLong(app: app.name, characters: characters))
                case .term(let text):
                    // Where it is: worth having, not worth the selection — but a cancellation is the reader moving on.
                    let box = try SelectedTerm(from: capture.text).flatMap { (term) throws(CaptureError) in
                        try orNone { () throws(CaptureError) in try bounds(of: capture, term: term, ax) }
                    }
                    return .selected(SelectedText(text: text, app: app), box: box)
                }
            case .nothing:
                return .nothing(.nothingSelected(app: app.name))
            case .searchLimitReached:
                return .nothing(.searchLimitReached(app: app.name, limit: webAreaSearchLimit))
            }
        } catch {
            return .nothing(.failed(error, app: app.name))
        }
    }

    // MARK: - Finding the selection

    struct Capture {
        let text: String
        let host: AXUIElement
        var markers: AXTextMarkerRange?
        /// The selected range **as it was when `text` was read**: its box is asked for by it, never by one read again.
        var range: CFRange?
    }

    private enum Search {
        case found(Capture)
        case nothing
        case searchLimitReached
    }

    /// The focused element first, then — only if that has nothing — the focused window's page. Safari reports no focused
    /// element when it is not frontmost, and focus can sit in its address bar, yet a selection in the page is there.
    private static func find(in application: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Search {
        let focused = try ax.element(application, kAXFocusedUIElementAttribute, ofApplication: true)
        if let focused, let found = try capture(from: focused, ax) { return .found(found) }
        var window = try ax.element(application, kAXFocusedWindowAttribute, ofApplication: true)
        if window == nil { window = try ax.element(application, kAXMainWindowAttribute, ofApplication: true) }
        guard let window else { return .nothing }
        switch try breadthFirst(
            from: window, limit: webAreaSearchLimit,
            children: { (node) throws(CaptureError) in try ax.elements(node, kAXChildrenAttribute) },
            matches: { (node) throws(CaptureError) in try ax.string(node, kAXRoleAttribute) == "AXWebArea" })
        {
        case .found(let page) where page != focused: return try capture(from: page, ax).map(Search.found) ?? .nothing
        case .found, .absent: return .nothing
        case .limitReached:
            log.notice("no web area within \(webAreaSearchLimit) elements of the focused window")
            return .searchLimitReached
        }
    }

    /// One element's selection. **A text range that agrees with its own text is used; one that does not gives way to
    /// the markers**: Chrome answers both dialects, its range need not describe its text, and a dialect's answer is used
    /// whole, never text from one and range from the other. A selection already in hand survives the second dialect
    /// failing, unless the reader moved on.
    private static func capture(from element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        let byRange = try rangeCapture(element, ax)
        if let byRange, let range = byRange.range, range.length == (byRange.text as NSString).length { return byRange }
        let byMarkers: Capture?
        do throws(CaptureError) { byMarkers = try markerCapture(element, ax) } catch {
            guard let byRange, error != .cancelled else { throw error }
            return byRange
        }
        return byMarkers ?? byRange
    }

    private static func rangeCapture(_ element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        guard let selected = try ax.string(element, kAXSelectedTextAttribute),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let range = try orNone { () throws(CaptureError) in try ax.range(element, kAXSelectedTextRangeAttribute) }
        return Capture(text: selected, host: element, range: range)
    }

    private static func markerCapture(_ element: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> Capture? {
        let host = try ax.webArea(containing: element) ?? element
        guard let selection = try ax.markerRange(host, "AXSelectedTextMarkerRange"),
              let text = try ax.string(host, "AXStringForTextMarkerRange", selection),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Capture(text: text, host: host, markers: selection)
    }

    /// Something read around a selection already read, **or none, if reading it failed**; only the reader moving on
    /// ends the read.
    private static func orNone<Value>(_ read: () throws(CaptureError) -> Value?) throws(CaptureError) -> Value? {
        do throws(CaptureError) { return try read() } catch {
            if error == .cancelled { throw error }
            return nil
        }
    }

    // MARK: - Where it is

    /// **Where the term is on screen**, or nil where the app cannot say. The text-range dialect is asked for the term's
    /// own range, so its box is exact; WebKit for the term's own markers where punctuation was trimmed, else the
    /// selection's, `containing`. **The box is the captured text's, or there is none**: the range or markers captured
    /// are read back and the selection asked again before a box is believed — an edit or a moved selection between the
    /// reads locates nothing, and the panel falls back to the pointer.
    static func bounds(of capture: Capture, term: SelectedTerm, _ ax: some AccessibilityReading) throws(CaptureError) -> SelectionBox? {
        let whole = term.range.location == 0 && term.range.length == (capture.text as NSString).length
        if let captured = capture.range, capture.markers == nil {
            guard captured.length == (capture.text as NSString).length,
                  let range = termRange(term.range, within: captured),
                  try text(at: captured, in: capture.host, ax) == capture.text,
                  let now = try ax.range(capture.host, kAXSelectedTextRangeAttribute),
                  now.location == captured.location, now.length == captured.length,
                  let request = AccessibilitySession.rangeValue(range),
                  let box = try ax.rect(capture.host, kAXBoundsForRangeParameterizedAttribute, request)
            else { return nil }
            return SelectionBox.checked(box, quality: .exact)
        }
        guard let markers = capture.markers,
              try ax.string(capture.host, "AXStringForTextMarkerRange", markers) == capture.text,
              let now = try ax.markerRange(capture.host, "AXSelectedTextMarkerRange"),
              try sameEnds(now, markers, in: capture.host, ax)
        else { return nil }
        if !whole,
           let box = try orNone({ () throws(CaptureError) in try termBox(in: markers, term: term, host: capture.host, ax) }),
           let exact = SelectionBox.checked(box, quality: .exact) {
            return exact
        }
        guard let box = try ax.rect(capture.host, "AXBoundsForTextMarkerRange", markers) else { return nil }
        return SelectionBox.checked(box, quality: whole ? .exact : .containing)
    }

    /// Whether two marker ranges have the same two ends: the same bytes, or WebKit's same index for each.
    private static func sameEnds(
        _ now: AXTextMarkerRange, _ captured: AXTextMarkerRange, in host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> Bool {
        let ends = [(AXTextMarkerRangeCopyStartMarker(now), AXTextMarkerRangeCopyStartMarker(captured)),
                    (AXTextMarkerRangeCopyEndMarker(now), AXTextMarkerRangeCopyEndMarker(captured))]
        for (current, kept) in ends where !CFEqual(current, kept) {
            guard let at = try ax.integer(host, "AXIndexForTextMarker", current),
                  let was = try ax.integer(host, "AXIndexForTextMarker", kept), at == was
            else { return false }
        }
        return true
    }

    /// The text at `range` now: asked for that range, or cut from a view that answers only with its whole value.
    private static func text(at range: CFRange, in host: AXUIElement, _ ax: some AccessibilityReading) throws(CaptureError) -> String? {
        if let request = AccessibilitySession.rangeValue(range),
           let text = try ax.string(host, kAXStringForRangeParameterizedAttribute, request) {
            return text
        }
        guard let value = try ax.string(host, kAXValueAttribute),
              let inside = Range(NSRange(location: range.location, length: range.length), in: value)
        else { return nil }
        return String(value[inside])
    }

    /// Where the term is in the document. **The range comes from another process**, so it is checked before it is
    /// summed: `+` on it trapped at `Int.max` in XiaolaiDict, which ends the app.
    static func termRange(_ term: NSRange, within selected: CFRange) -> CFRange? {
        guard selected.location >= 0, selected.length >= 0, term.location >= 0, term.length >= 0,
              !selected.location.addingReportingOverflow(selected.length).overflow,
              term.location <= selected.length, term.length <= selected.length - term.location
        else { return nil }
        return CFRange(location: selected.location + term.location, length: term.length)
    }

    /// The term's own box inside a selection it was trimmed from: WebKit counts a page's text in UTF-16 from its start,
    /// so the term's markers are the selection's first index plus where the term sits in it, read back and held to the
    /// term before the box is believed.
    static func termBox(
        in selection: AXTextMarkerRange, term: SelectedTerm, host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> CGRect? {
        let start = AXTextMarkerRangeCopyStartMarker(selection)
        guard let index = try ax.integer(host, "AXIndexForTextMarker", start), index >= 0 else { return nil }
        let (first, overflowed) = index.addingReportingOverflow(term.range.location)
        let (last, overflowedAgain) = first.addingReportingOverflow(term.range.length)
        guard !overflowed, !overflowedAgain,
              let from = try ax.marker(host, "AXTextMarkerForIndex", first as CFNumber),
              let to = try ax.marker(host, "AXTextMarkerForIndex", last as CFNumber),
              let range = try ax.markerRange(host, "AXTextMarkerRangeForUnorderedTextMarkers", [from, to] as CFArray),
              try ax.string(host, "AXStringForTextMarkerRange", range) == term.text
        else { return nil }
        return try ax.rect(host, "AXBoundsForTextMarkerRange", range)
    }

    private static let log = Logger(subsystem: XDictIdentity.app, category: "selection")
}
