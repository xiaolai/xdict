import ApplicationServices
import XDictBase
import os

/// How reading another app through the Accessibility API failed — each needs a different answer for the reader.
public enum CaptureError: Error, Hashable, Sendable {
    /// The app did not answer within the messaging timeout.
    case notResponding
    /// The whole read ran past its budget.
    case deadlineExceeded
    /// Accessibility is off for this process (the reader has not granted it).
    case accessibilityDisabled
    /// The app is gone.
    case appUnavailable
    /// The app refused — a locked screen answers this way.
    case accessibilityRefused
    /// The reader moved on.
    case cancelled
}

/// **The Accessibility requests a read makes, behind a seam** (moved from XiaolaiDict): the real session, or a test's
/// scripted tree. Every helper below goes through the two primitive requests.
public protocol AccessibilityReading {
    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef?
    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef?
    /// Asks Chromium and Electron to build their tree (`AXManualAccessibility`).
    func wake(_ application: AXUIElement) throws(CaptureError)
}

extension AccessibilityReading {
    public func wake(_ application: AXUIElement) throws(CaptureError) {}

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

    func integer(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> Int? {
        try parameterized(element, name, argument) as? Int
    }

    func range(_ element: AXUIElement, _ name: String) throws(CaptureError) -> CFRange? {
        guard let value = cast(try attribute(element, name, ofApplication: false), AXValueGetTypeID(), as: AXValue.self)
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
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

    /// The web area an element is in, walking up at most 40 parents.
    func webArea(containing element: AXUIElement) throws(CaptureError) -> AXUIElement? {
        var current = element
        for _ in 0..<40 {
            switch try string(current, kAXRoleAttribute) {
            case "AXWebArea": return current
            case kAXApplicationRole: return nil
            default: break
            }
            guard let parent = try self.element(current, kAXParentAttribute), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private func cast<T>(_ value: CFTypeRef?, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard let value, CFGetTypeID(value) == typeID else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! T)
    }
}

/// **One read's requests, against a deadline**: each request checks the reader still wants it and the budget is not
/// spent, and its status is classified once — a failure of the app itself ends the read, an attribute it lacks is
/// absent.
public struct AccessibilitySession: AccessibilityReading {
    /// Per request: a hung app answers nothing for this long, then is "not responding".
    static let messagingTimeout: Float = 1.0

    let deadline: ContinuousClock.Instant
    private let log = Logger(subsystem: XDictIdentity.app, category: "accessibility")

    init(budget: Duration) {
        deadline = .now + budget
    }

    public func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return try settle(status, name, ofApplication: ofApplication) ? value : nil
    }

    public func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
        return try settle(status, name, ofApplication: false) ? value : nil
    }

    public func wake(_ application: AXUIElement) throws(CaptureError) {
        try checkStillWanted()
        let status = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = try settle(status, "AXManualAccessibility", ofApplication: true)
    }

    public static func rangeValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private func checkStillWanted() throws(CaptureError) {
        if Task.isCancelled { throw .cancelled }
        guard ContinuousClock.now < deadline else { throw .deadlineExceeded }
    }

    private func settle(_ status: AXError, _ name: String, ofApplication: Bool) throws(CaptureError) -> Bool {
        let failure: CaptureError? = switch status {
        case .success: nil
        case .cannotComplete: .notResponding
        case .apiDisabled: .accessibilityDisabled
        case .invalidUIElement: ofApplication ? .appUnavailable : nil
        case .failure: ofApplication ? .accessibilityRefused : nil
        default: nil
        }
        if let failure {
            log.error("\(name, privacy: .public): AXError \(status.rawValue) — \(String(describing: failure), privacy: .public)")
            throw failure
        }
        return status == .success
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
