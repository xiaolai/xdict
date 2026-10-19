import ApplicationServices
import XDictBase
import XDictCapture
import os

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

    /// The box as capture hands it over (XDict ADR-0014 decision 2): measured, of its quality.
    var measured: WordBox {
        .measured(ReadBounds(rect: DownRect(rect), quality: quality == .exact ? .exact : .containing))
    }
}

/// What the reader had selected, and in which app.
public struct SelectedText: Hashable, Sendable {
    /// The term: the selection less its wrapping punctuation (`SelectedTerm`), admitted by the consumer's limit.
    public let text: String
    public let app: FrontApp
    /// The dialect that read it: the text range or the text markers.
    public let acquisition: CaptureAcquisition
    /// **The sentence around the term** (owner, 2026-10-19: the sentence is always captured, the selection path too),
    /// its range the term's — or why there is none. It travels only into the captured term and from there into the one
    /// ephemeral session (ADR-0014 decision 9); every description of it is metadata (`CaptureDescriptions`).
    public let context: ContextOutcome

    public init(text: String, app: FrontApp, acquisition: CaptureAcquisition,
                context: ContextOutcome = .unavailable(.notCaptured)) {
        self.text = text
        self.app = app
        self.acquisition = acquisition
        self.context = context
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
    /// Longer than the consumer admits (`TermAdmission`), in characters: refused whole, never cut.
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

    /// **The selection as capture hands it over** (XDict ADR-0014 decision 2): the term, `trigger` (the shortcut and the
    /// menu read the selection alike), the dialect that read it, the app, the measured box or none, and the sentence
    /// around it as read, or why there is none. Nil for a refusal; a term the validating constructor refuses throws.
    public func capturedTerm(trigger: CaptureTrigger) throws(CaptureValueError) -> CapturedTerm? {
        guard case .selected(let selected, let box) = self else { return nil }
        return try CapturedTerm.make(
            term: selected.text, trigger: trigger, acquisition: selected.acquisition, confidence: 1,
            source: SourceApp(bundleID: selected.app.bundleID), pointer: nil, box: box?.measured ?? .absent,
            context: selected.context)
    }
}

/// **Reads the frontmost app's selection through the Accessibility API** (plan-macos-v1 WI-8, I2; moved from
/// XiaolaiDict's `SelectionReader`, then down from `XDictAnywhere`, plan-capture WI-2). Apps speak one of two dialects:
///
/// - **text range**: `AXSelectedText` and `AXSelectedTextRange` — Cocoa text views (TextEdit, Notes);
/// - **text markers**: `AXSelectedTextMarkerRange` — WebKit (Safari, Mail) and Chromium.
///
/// **Re-checked against the MDX-first model** (ADR-0001): XDict looks the term up in the reader's dictionaries and puts
/// the panel by the word, and keeps no reading history, so XiaolaiDict's sentence context, provenance and lemma stayed
/// behind with the study ledger they served. What came: the dialects, the page search, waking Chromium, the term's own
/// box read back before it is believed, and every number from another process checked before it is summed. **The
/// admission limit is handed in** (XDict ADR-0014 decision 3): lookup's, never capture's, and never a cut.
public enum SelectionReader {
    /// The whole read, however many requests it takes — the hit test of the clicked position included.
    public static let budget: Duration = .seconds(2)
    /// Nodes visited looking for a browser window's page. A tree this search cannot cross is reported, not treated as
    /// "no page".
    public static let webAreaSearchLimit = 400
    /// The element under the click and its parents read for a selection: a text view's paragraph, line or run is a few
    /// levels under the view that holds the selection.
    static let underParents = 8

    /// **Another app's selection is read through the one lane** (XDict ADR-0014 decision 6), as an explicit request:
    /// ahead of every hover, under the explicit messaging timeout, its session — and so its hit test of `clicked` — made
    /// when its turn comes, so the budget is the read's and not the queue's. **This process's own windows are read on
    /// the main actor and never through the lane**: a request about this process is serviced in-process, on the calling
    /// thread, and SwiftUI must be asked from the main one (XiaolaiDict ADR-0042). `clicked` is where the reader
    /// Control-clicked the selection (Accessibility's coordinates, y down), for the Service: the element there is read
    /// when the focused one has nothing. `access` is asked first and never prompts; `client` makes the read's requests
    /// (the real session, or a test's tree). `exclusions` is the reader's hover policy, **with no default**: its excluded
    /// apps and sites decide whether the sentence around the selection is read (`contextOutcome`), in this same lane job.
    public static func read(
        from app: FrontApp, clicked: CGPoint? = nil, admitting admission: TermAdmission, excluding exclusions: HoverPolicy,
        limits: CaptureLimits = .shipped, access: AccessibilityAccess = .system,
        lane: AccessibilityLane = .system, budget: Duration = budget,
        client: @escaping @Sendable (Duration) -> any AccessibilityReading = { AccessibilitySession(budget: $0) }
    ) async -> SelectionOutcome {
        guard access.granted() else { return .nothing(.notTrusted) }
        let rules = Rules(admission: admission, exclusions: exclusions, limits: limits)
        if app.pid == getpid() {
            return await MainActor.run { readNow(app, clicked: clicked, rules, client(budget)) }
        }
        return await lane.run(.explicit, timeout: AccessibilitySession.messagingTimeout, budget: budget, {
            readNow(app, clicked: clicked, rules, client(budget))
        }, refused: { refusal in
            log.notice("selection read not run: \(String(describing: refusal), privacy: .public)")
            return .nothing(.failed(failure(for: refusal), app: app.name))
        })
    }

    /// What a lane's refusal means for the reader. **A stuck lane is an app that is not answering** — the read ahead is
    /// blocked inside another process — and the lane itself reports it as stuck (`AccessibilityLane.current()`); the
    /// reader's sentence for it is "did not answer", which is what happened.
    static func failure(for refusal: LaneRefusal) -> CaptureError {
        switch refusal {
        case .cancelled, .superseded: .cancelled
        case .overstayed: .deadlineExceeded
        case .stuck: .notResponding
        }
    }

    /// What one read admits and refuses: the consumer's admission, the reader's exclusions, capture's limits.
    struct Rules: Sendable {
        let admission: TermAdmission
        let exclusions: HoverPolicy
        let limits: CaptureLimits
    }

    private static func readNow(
        _ app: FrontApp, clicked: CGPoint?, _ rules: Rules, _ ax: some AccessibilityReading
    ) -> SelectionOutcome {
        read(application: AXUIElementCreateApplication(app.pid), of: app, with: ax, clicked: clicked,
             admitting: rules.admission, excluding: rules.exclusions, limits: rules.limits)
    }

    /// The read with the clicked position hit-tested **inside it**: one request of the read's own client, so the time
    /// it takes is the read's, and a hung or stalled hit test ends the read as any request does.
    public static func read(application: AXUIElement, of app: FrontApp, with ax: some AccessibilityReading,
                            clicked: CGPoint?, admitting admission: TermAdmission, excluding exclusions: HoverPolicy,
                            limits: CaptureLimits = .shipped) -> SelectionOutcome {
        let under: AXUIElement?
        do throws(CaptureError) {
            under = try clicked.flatMap { (point) throws(CaptureError) in try ax.hitTest(application, at: point) }
        } catch {
            return .nothing(.failed(error, app: app.name))
        }
        return read(application: application, of: app, with: ax, under: under, admitting: admission,
                    excluding: exclusions, limits: limits)
    }

    /// The whole read, against any Accessibility client — the real one, or a test's. `under` is the element under the
    /// reader's Control-click, where there was one.
    public static func read(application: AXUIElement, of app: FrontApp, with ax: some AccessibilityReading,
                            under: AXUIElement? = nil, admitting admission: TermAdmission,
                            excluding exclusions: HoverPolicy, limits: CaptureLimits = .shipped) -> SelectionOutcome {
        do {
            try ax.wake(application)
            switch try find(in: application, under: under, ax) {
            case .found(let capture):
                guard !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .nothing(.nothingSelected(app: app.name))
                }
                guard let term = SelectedTerm(from: capture.text) else { return .nothing(.noWord(app: app.name)) }
                guard admission.admits(term.text) else {
                    return .nothing(.tooLong(app: app.name, characters: term.text.count))
                }
                // Where it is: worth having, not worth the selection — but a cancellation is the reader moving on.
                let box = try orNone { () throws(CaptureError) in try bounds(of: capture, term: term, ax) }
                let acquisition: CaptureAcquisition = capture.markers == nil ? .textRange : .textMarkers
                let context = try contextOutcome(of: capture, term: term, app: app, exclusions: exclusions,
                                                 limits: limits, ax)
                return .selected(SelectedText(text: term.text, app: app, acquisition: acquisition, context: context),
                                 box: box)
            case .nothing:
                return .nothing(.nothingSelected(app: app.name))
            case .searchLimitReached:
                return .nothing(.searchLimitReached(app: app.name, limit: webAreaSearchLimit))
            }
        } catch {
            return .nothing(.failed(error, app: app.name))
        }
    }

    /// **The Service's text is the query, whatever the selection now says** (XDict ADR-0014 decision 2, carried from
    /// plan-capture WI-1's verification). macOS hands the Service its text; the selection is read afterwards, from an
    /// app that may have changed it, quit, or lost it to the Services submenu the pointer moved into. So the term is
    /// always `serviceText`, the acquisition always `.serviceText`, and the read supplies **geometry only where it
    /// agrees**: a selection that reads back as other text supplies neither context nor a box, and the placement falls
    /// back to where the reader Control-clicked (`clicked`), valid only now. One that agrees lends its box and the
    /// sentence read around it (owner, 2026-10-19: the sentence is always captured, the Service too).
    public static func serviceTerm(
        _ serviceText: String, read outcome: SelectionOutcome?, source: SourceApp, clicked: DownPoint?
    ) throws(CaptureValueError) -> CapturedTerm {
        let fallback: WordBox = clicked.map(WordBox.clickPlacement) ?? .absent
        let box: WordBox
        let context: ContextOutcome
        switch outcome {
        case .selected(let selected, let measured)? where selected.text == serviceText:
            box = measured?.measured ?? fallback
            context = selected.context
        case .selected?:
            box = fallback
            context = .unavailable(.disagreesWithServiceText)
        case .nothing?, nil:
            box = fallback
            context = .unavailable(.notCaptured)
        }
        return try CapturedTerm.make(term: serviceText, trigger: .service, acquisition: .serviceText, confidence: 1,
                                     source: source, pointer: nil, box: box, context: context)
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

    /// The focused element first, then the element under the reader's click and its parents, then — only if those
    /// have nothing — the focused window's page. Safari reports no focused element when it is not frontmost, and focus
    /// can sit in its address bar, yet a selection in the page is there. Once the Services menu has closed, Notes and
    /// TextEdit answer with no focused selection while the text view under the click holds it (E2E, 2026-10-18).
    private static func find(in application: AXUIElement, under: AXUIElement?,
                             _ ax: some AccessibilityReading) throws(CaptureError) -> Search {
        let focused = try ax.element(application, kAXFocusedUIElementAttribute, ofApplication: true)
        if let focused, let found = try capture(from: focused, ax) { return .found(found) }
        var current = under
        for _ in 0..<underParents {
            guard let element = current else { break }
            if let found = try capture(from: element, ax) { return .found(found) }
            guard let parent = try ax.element(element, kAXParentAttribute), parent != element else { break }
            current = parent
        }
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
