import ApplicationServices
import XDictBase
import os

/// How reading another app through the Accessibility API failed — each needs a different answer for the reader.
/// Metadata only: no case carries text read from the app (XDict ADR-0014 decision 9).
public enum CaptureError: Error, Hashable, Sendable {
    /// The app did not answer one request within the messaging timeout: busy or hung.
    case notResponding
    /// The whole read ran past its budget, one slow answer after another — the hit test included.
    case deadlineExceeded
    /// Accessibility is off for this process (the reader has not granted it).
    case accessibilityDisabled
    /// The app is gone.
    case appUnavailable
    /// The app's Accessibility refused outright (`kAXErrorFailure` on the app itself): what a locked screen answers.
    case accessibilityRefused
    /// The reader moved on.
    case cancelled
}

/// **The Accessibility requests a read makes, behind a seam** (moved from XDict's `XDictAnywhere` and XiaolaiDict's
/// `MacCapture`): the real session, or a test's scripted tree. Every read is typed: a value of the wrong type is an
/// absent one. Every helper below goes through the primitive requests, so a session's budget covers all of them.
public protocol AccessibilityReading {
    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef?
    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef?
    /// Asks Electron to build its tree (`AXManualAccessibility`). Every other app ignores it.
    func wake(_ application: AXUIElement) throws(CaptureError)
    /// Tells the app an assistive client is reading it (`AXEnhancedUserInterface`) — what Chrome needs before it builds a
    /// page tree. **Heavier than `wake`**: the app builds its whole tree, so it is asked only of an app that answered
    /// nothing (`PointerWordReader.read`).
    func enhance(_ application: AXUIElement) throws(CaptureError)
    /// The element at `point` (Accessibility's space, y down) under `root`: a hit test, **one request like any other**,
    /// inside the read's budget (XDict ADR-0014 decision 6). Nil where nothing is there.
    func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement?
    /// **What an element advertises** (`AXUIElementCopyAttributeNames`), or nil where the client cannot tell — the
    /// default below, for a test's client that scripts values and not capability. One selection read asks it to tell
    /// "this app shares no selection" apart from "nothing is selected" (owner, 2026-10-30: a selection in Ghostty was
    /// answered "no word selected"; upstream Ghostty exposes its screen but no selected text).
    func attributeNames(_ element: AXUIElement) throws(CaptureError) -> [String]?
}

extension AccessibilityReading {
    /// A test's client has no tree to build.
    public func wake(_ application: AXUIElement) throws(CaptureError) {}
    public func enhance(_ application: AXUIElement) throws(CaptureError) {}
    /// A test's client that scripts no hit test has nothing at any point.
    public func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? { nil }
    /// A test's client scripts values, not capability: unknown, which reads as "shared" — the old behaviour exactly.
    public func attributeNames(_ element: AXUIElement) throws(CaptureError) -> [String]? { nil }

    func element(_ element: AXUIElement, _ name: String, ofApplication: Bool = false) throws(CaptureError) -> AXUIElement? {
        cast(try attribute(element, name, ofApplication: ofApplication), AXUIElementGetTypeID(), as: AXUIElement.self)
    }

    func elements(_ element: AXUIElement, _ name: String) throws(CaptureError) -> [AXUIElement] {
        guard let list = try attribute(element, name, ofApplication: false) as? [CFTypeRef] else { return [] }
        return list.compactMap { cast($0, AXUIElementGetTypeID(), as: AXUIElement.self) }
    }

    func string(_ element: AXUIElement, _ name: String) throws(CaptureError) -> String? {
        try attribute(element, name, ofApplication: false) as? String
    }

    func string(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> String? {
        try parameterized(element, name, argument) as? String
    }

    func integer(_ element: AXUIElement, _ name: String) throws(CaptureError) -> Int? {
        try attribute(element, name, ofApplication: false) as? Int
    }

    func integer(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> Int? {
        try parameterized(element, name, argument) as? Int
    }

    func range(_ element: AXUIElement, _ name: String) throws(CaptureError) -> CFRange? {
        decodedRange(try attribute(element, name, ofApplication: false))
    }

    func range(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFRange? {
        decodedRange(try parameterized(element, name, argument))
    }

    func marker(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> AXTextMarker? {
        cast(try parameterized(element, name, argument), AXTextMarkerGetTypeID(), as: AXTextMarker.self)
    }

    func markerRange(_ element: AXUIElement, _ name: String) throws(CaptureError) -> AXTextMarkerRange? {
        cast(try attribute(element, name, ofApplication: false), AXTextMarkerRangeGetTypeID(), as: AXTextMarkerRange.self)
    }

    func markerRange(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> AXTextMarkerRange? {
        cast(try parameterized(element, name, argument), AXTextMarkerRangeGetTypeID(), as: AXTextMarkerRange.self)
    }

    func rect(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CGRect? {
        guard let value = cast(try parameterized(element, name, argument), AXValueGetTypeID(), as: AXValue.self) else {
            return nil
        }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    /// An element's frame on screen (y down), from its position and size: nil where either is missing or of another type.
    func frame(_ element: AXUIElement) throws(CaptureError) -> CGRect? {
        guard let position = cast(try attribute(element, kAXPositionAttribute, ofApplication: false), AXValueGetTypeID(),
                                  as: AXValue.self),
              let size = cast(try attribute(element, kAXSizeAttribute, ofApplication: false), AXValueGetTypeID(),
                              as: AXValue.self)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// A range out of whatever came back: an `AXValue` of the range type, or nothing.
    private func decodedRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value = cast(value, AXValueGetTypeID(), as: AXValue.self) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    /// The web area containing `element`, walking up its parents — the page a word was read on.
    func webArea(containing element: AXUIElement) throws(CaptureError) -> AXUIElement? {
        guard case .page(let area) = try walkToPage(from: element) else { return nil }
        return area
    }

    /// The walk up to the page, **saying how it ended** (XiaolaiDict, audit round 3, #34): a walk that stopped short is
    /// not one that reached the application. At most `webAreaAncestorLimit` parents, and an element that names itself as
    /// its own parent ends it — the guard is what makes the bound the worst case rather than the usual one.
    func walkToPage(from element: AXUIElement) throws(CaptureError) -> PageWalk {
        var current = element
        for _ in 0..<webAreaAncestorLimit {
            switch try string(current, kAXRoleAttribute) {
            case "AXWebArea": return .page(current)
            case kAXApplicationRole: return .application
            default: break
            }
            guard let parent = try self.element(current, kAXParentAttribute), parent != current else { return .stoppedShort }
            current = parent
        }
        return .stoppedShort
    }

    /// A CF value as `type`, checked by type ID first: `as?` on a CF type always succeeds.
    private func cast<T>(_ value: CFTypeRef?, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard let value, CFGetTypeID(value) == typeID else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! T)
    }
}

/// Parents walked up from an element to the page containing it. A browser's web area sits a few levels under toolbars
/// and tab groups; a tree deeper than this is one with no page in it.
let webAreaAncestorLimit = 40

/// Where a walk up from an element towards its page ended.
enum PageWalk {
    case page(AXUIElement)
    /// Reached the application without passing a web area: there is no page.
    case application
    /// A parent could not be read, or the bound ran out — **not** "no page".
    case stoppedShort
}

/// The raw Accessibility requests — the seam that lets a test count them, stall them or fail them without the real API.
public struct AccessibilityRequests: Sendable {
    public var attribute: @Sendable (AXUIElement, String) -> (AXError, CFTypeRef?)
    public var parameterized: @Sendable (AXUIElement, String, CFTypeRef) -> (AXError, CFTypeRef?)
    /// The hit test: `AXUIElementCopyElementAtPosition`.
    public var elementAt: @Sendable (AXUIElement, CGPoint) -> (AXError, AXUIElement?)
    /// `AXManualAccessibility`, which wakes an Electron tree. **Not Chrome's**: measured 2026-10-03 (XiaolaiDict),
    /// Chrome refuses it as unsupported and builds no page tree for it.
    public var wake: @Sendable (AXUIElement) -> AXError
    /// `AXEnhancedUserInterface`, which Chrome does honour — answering "not implemented" while it builds the tree anyway,
    /// about two seconds later.
    public var enhance: @Sendable (AXUIElement) -> AXError

    public init(
        attribute: @escaping @Sendable (AXUIElement, String) -> (AXError, CFTypeRef?),
        parameterized: @escaping @Sendable (AXUIElement, String, CFTypeRef) -> (AXError, CFTypeRef?),
        elementAt: @escaping @Sendable (AXUIElement, CGPoint) -> (AXError, AXUIElement?) = { _, _ in (.noValue, nil) },
        wake: @escaping @Sendable (AXUIElement) -> AXError = { _ in .success },
        enhance: @escaping @Sendable (AXUIElement) -> AXError = { _ in .success }
    ) {
        self.attribute = attribute
        self.parameterized = parameterized
        self.elementAt = elementAt
        self.wake = wake
        self.enhance = enhance
    }

    public static let system = AccessibilityRequests(
        attribute: { element, name in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status, value)
        },
        parameterized: { element, name, argument in
            var value: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
            return (status, value)
        },
        elementAt: { root, point in
            var found: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &found)
            return (status, found)
        },
        wake: { AXUIElementSetAttributeValue($0, "AXManualAccessibility" as CFString, kCFBooleanTrue) },
        enhance: { AXUIElementSetAttributeValue($0, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) })
}

/// **One read of another app's Accessibility tree, against a deadline**: every request — the hit test included —
/// checks first that the reader still wants it and that the budget is not spent, so the read overruns by at most the one
/// request in flight, and its status is classified once: a failure of the app itself ends the read, an attribute it
/// lacks is absent.
///
/// The messaging timeout is not set here. It is process-wide, so `AccessibilityLane` sets it on entry, for the one read
/// it lets run (XiaolaiDict ADR-0046; XDict set it per read, beside other reads, until this target).
public struct AccessibilitySession: AccessibilityReading {
    /// Per request, for an explicit read: long enough for a busy app — Safari repainting a fresh selection missed half a
    /// second — short enough that a hung one cannot hold the lookup.
    public static let messagingTimeout: Float = 1.0

    /// What an Accessibility status means for the read.
    enum Answer: Equatable {
        case value
        /// The element has no such value: normal, and the read goes on.
        case absent
        case failed(CaptureError)
    }

    let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let requests: AccessibilityRequests
    private let log = Logger(subsystem: XDictIdentity.app, category: "accessibility")

    /// The read ends at `budget` from now.
    public init(
        budget: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        requests: AccessibilityRequests = .system
    ) {
        self.now = now
        self.requests = requests
        deadline = now() + budget
    }

    /// `ofApplication`: asked of the app itself, an invalid element means the app is gone and a plain failure means
    /// Accessibility refused it outright — a locked screen. Deeper in the tree both only mean that one element had
    /// nothing: a closed popover, an unsupported attribute.
    static func answer(for status: AXError, ofApplication: Bool = false) -> Answer {
        switch status {
        case .success: .value
        case .cannotComplete: .failed(.notResponding)
        case .apiDisabled: .failed(.accessibilityDisabled)
        case .invalidUIElement: ofApplication ? .failed(.appUnavailable) : .absent
        case .failure: ofApplication ? .failed(.accessibilityRefused) : .absent
        default: .absent
        }
    }

    /// **The element's own attribute list**, inside the budget and classified like any request: it answers what the
    /// element advertises, and an element that has no list is simply absent.
    public func attributeNames(_ element: AXUIElement) throws(CaptureError) -> [String]? {
        try checkStillWanted()
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        return try settle(status, "attributes", ofApplication: false) ? (names as? [String] ?? []) : nil
    }

    public func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        let (status, value) = requests.attribute(element, name)
        return try settle(status, name, ofApplication: ofApplication) ? value : nil
    }

    public func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        let (status, value) = requests.parameterized(element, name, argument)
        return try settle(status, name, ofApplication: false) ? value : nil
    }

    /// **Inside the budget, and classified like any request**: a hung app ends the read here, and the
    /// time the hit test took is the read's. Before this target XDict hit-tested the clicked position before its session
    /// existed, with no deadline over it (XDict ADR-0014 decision 6). And a test after it: a hit test that ran past the
    /// deadline is not believed, so a stalled one ends the read rather than spending the next request's time.
    public func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
        try checkStillWanted()
        let (status, found) = requests.elementAt(root, point)
        try checkStillWanted()
        return try settle(status, "hit test", ofApplication: false) ? found : nil
    }

    /// Inside the budget, classified like any request to the app: an app that does not know the attribute answers, and
    /// that is fine; one that does not answer at all ends the read.
    public func wake(_ application: AXUIElement) throws(CaptureError) {
        try checkStillWanted()
        _ = try settle(requests.wake(application), "AXManualAccessibility", ofApplication: true)
    }

    /// Classified like `wake`. Chrome's "not implemented" is an answer, not a failure.
    public func enhance(_ application: AXUIElement) throws(CaptureError) {
        try checkStillWanted()
        _ = try settle(requests.enhance(application), "AXEnhancedUserInterface", ofApplication: true)
    }

    public static func rangeValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private func checkStillWanted() throws(CaptureError) {
        if Task.isCancelled { throw .cancelled }
        guard now() < deadline else { throw .deadlineExceeded }
    }

    /// Absent values pass quietly; statuses that are neither success nor the usual "no such attribute" are logged by
    /// name and number, never by value, so an app that answers oddly can be diagnosed.
    private func settle(_ status: AXError, _ name: String, ofApplication: Bool) throws(CaptureError) -> Bool {
        switch Self.answer(for: status, ofApplication: ofApplication) {
        case .value: return true
        case .failed(let error):
            log.error("\(name, privacy: .public): AXError \(status.rawValue) — \(String(describing: error), privacy: .public)")
            throw error
        case .absent:
            if ![.noValue, .attributeUnsupported, .parameterizedAttributeUnsupported].contains(status) {
                log.debug("\(name, privacy: .public): AXError \(status.rawValue), read as absent")
            }
            return false
        }
    }
}

/// What a bounded breadth-first search found: a node, none in the whole tree, or not known — the limit ran out.
enum SearchResult<Node> {
    case found(Node)
    case absent
    case limitReached
}

/// Breadth first, each node visited once however many parents list it, and at most `limit` nodes.
func breadthFirst<Node: Hashable, Failure: Error>(
    from root: Node, limit: Int,
    children: (Node) throws(Failure) -> [Node],
    matches: (Node) throws(Failure) -> Bool
) throws(Failure) -> SearchResult<Node> {
    var queue = [root]
    var seen: Set<Node> = [root]
    var head = 0
    while head < queue.count {
        guard head < limit else { return .limitReached }
        let node = queue[head]
        head += 1
        if try matches(node) { return .found(node) }
        for child in try children(node) where seen.insert(child).inserted { queue.append(child) }
    }
    return .absent
}
