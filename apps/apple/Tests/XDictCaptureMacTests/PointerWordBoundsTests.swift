import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// The tolerance the ported tests were written against (XiaolaiDict ADR-0016: 3 pt across, 2 pt down), handed in as the
/// app hands in its tokens' (XDict ADR-0014 decision 11).
enum Measured {
    static let hit: HitTolerance = {
        guard let tolerance = HitTolerance(horizontal: 3, vertical: 2) else { preconditionFailure("a valid tolerance") }
        return tolerance
    }()
    /// The recogniser's, since plan-capture WI-4: the strip 300/150/600 pt, tiling slacks of 4 and 16 band pixels, a
    /// window's frame the same within 1 pt — the numbers `XDictCaptureTests`' `Measured` hands in too.
    static let strip = StripMetrics(initialHeight: 300, growthStep: 150, maximumHeight: 600)
    static let tiling = TilingMetrics(edgeSlack: 4, holeSlack: 16)
    static let metrics = CaptureMetrics(hit: hit, restTolerance: 2, strip: strip, tiling: tiling, frameDrift: 1)
    /// The label slack the tokens hand in: 12 pt off centre, 2 pt smaller — a chosen margin, not a measurement.
    static let label = LabelSlack(shift: 12, smaller: 2)
}

/// A text view of fixed-width glyphs: character i spans x 100+10i … 110+10i, y 200 … 220 (y down) — one fake for two
/// dialects: the Cocoa text range, or (Chromium, Electron) only a value and per-range boxes.
final class Glyphs: AccessibilityReading {
    let text: String
    let speaksTextRange: Bool
    /// Answers the token's own box empty, as some views do — every one-character glyph box stays valid.
    let emptyTokenBox: Bool
    /// Fails the request for the token's own box with this — the one geometry request made after the word is read.
    let failingTokenBox: CaptureError?
    /// How many boxes were asked for.
    private(set) var boundsAsked = 0

    init(_ text: String, speaksTextRange: Bool, emptyTokenBox: Bool = false, failingTokenBox: CaptureError? = nil) {
        self.text = text
        self.speaksTextRange = speaksTextRange
        self.emptyTokenBox = emptyTokenBox
        self.failingTokenBox = failingTokenBox
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        switch name {
        case kAXNumberOfCharactersAttribute: speaksTextRange ? text.utf16.count as CFNumber : nil
        case kAXValueAttribute: text as CFString
        case kAXRoleAttribute: "AXTextArea" as CFString
        default: nil
        }
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        switch name {
        case kAXRangeForPositionParameterizedAttribute:
            guard speaksTextRange else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(unsafeDowncast(argument, to: AXValue.self), .cgPoint, &point)
            var range = CFRange(location: max(0, Int((point.x - 100) / 10)), length: 1)
            return AXValueCreate(.cfRange, &range)
        case kAXStringForRangeParameterizedAttribute:
            guard speaksTextRange else { return nil }
            let range = Self.range(argument)
            let units = Array(text.utf16)[range.location..<(range.location + range.length)]
            return String(decoding: units, as: UTF16.self) as CFString
        case kAXBoundsForRangeParameterizedAttribute:
            boundsAsked += 1
            let range = Self.range(argument)
            if range.length > 1, let failingTokenBox { throw failingTokenBox }
            var box = emptyTokenBox && range.length > 1 ? CGRect.zero
                : CGRect(x: 100 + 10 * CGFloat(range.location), y: 200, width: 10 * CGFloat(range.length), height: 20)
            return AXValueCreate(.cgRect, &box)
        default:
            return nil
        }
    }

    private static func range(_ argument: CFTypeRef) -> CFRange {
        var range = CFRange()
        AXValueGetValue(unsafeDowncast(argument, to: AXValue.self), .cfRange, &range)
        return range
    }
}

/// **Chromium answering one box for a whole paragraph says nothing about which word holds the pointer** (owner's
/// report, 2026-10-26: the pointer was over "militia" and the panel looked up "war"). The scan trusts a box only where
/// it tells words apart; when every word of the value shares one box, the element's own position answers, and where it
/// cannot, the read misses and the pixels answer — never the first word of the paragraph.
final class FlatBoxes: AccessibilityReading {
    let text: String
    init(_ text: String) { self.text = text }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        switch name {
        case kAXValueAttribute: text as CFString
        case kAXRoleAttribute: "AXStaticText" as CFString
        default: nil
        }
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        guard name == kAXBoundsForRangeParameterizedAttribute else { return nil }
        var box = CGRect(x: 100, y: 200, width: 300, height: 20)
        return AXValueCreate(.cgRect, &box)
    }
}

/// **Chrome's page as its Accessibility tree answers it** (owner's report, 2026-10-26: the pointer was over "militia"
/// and the panel looked up "war"): the hit test names the web area, which answers no text at a point; its one child is
/// a group whose frame is a one-pixel strip of the page, holding no pointer; under it the page's static text, whose
/// per-word boxes are exact. Nothing was descended into, so the pixels answered with a word the pointer was not on.
final class ChromePage: AccessibilityReading {
    static let sentence = "war or militia advanced"
    private let area = AXUIElementCreateApplication(pid_t(4_700_001))
    private let strip = AXUIElementCreateApplication(pid_t(4_700_002))
    private let text = AXUIElementCreateApplication(pid_t(4_700_003))
    var webArea: AXUIElement { area }

    private func pid(_ e: AXUIElement) -> pid_t {
        var value: pid_t = 0
        AXUIElementGetPid(e, &value)
        return value
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        switch pid(element) {
        case 4_700_001:
            switch name {
            case kAXRoleAttribute: return "AXWebArea" as CFString
            case kAXChildrenAttribute: return [strip] as CFArray
            default: return nil
            }
        case 4_700_002:
            switch name {
            case kAXRoleAttribute: return "AXGroup" as CFString
            case kAXChildrenAttribute: return [text] as CFArray
            case kAXPositionAttribute:
                var origin = CGPoint(x: 91, y: 118)
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute:
                var size = CGSize(width: 1_200, height: 1)
                return AXValueCreate(.cgSize, &size)
            default: return nil
            }
        case 4_700_003:
            switch name {
            case kAXRoleAttribute: return "AXStaticText" as CFString
            case kAXValueAttribute: return Self.sentence as CFString
            case kAXPositionAttribute:
                var origin = CGPoint(x: 100, y: 200)
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute:
                var size = CGSize(width: 10 * CGFloat(Self.sentence.utf16.count), height: 20)
                return AXValueCreate(.cgSize, &size)
            default: return nil
            }
        default:
            return nil
        }
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        guard pid(element) == 4_700_003, name == kAXBoundsForRangeParameterizedAttribute else { return nil }
        var range = CFRange()
        AXValueGetValue(unsafeDowncast(argument, to: AXValue.self), .cfRange, &range)
        var box = CGRect(x: 100 + 10 * CGFloat(range.location), y: 200, width: 10 * CGFloat(range.length), height: 20)
        return AXValueCreate(.cgRect, &box)
    }
}

/// **A hover hands the panel the word's box where the dialect has one** (moved by name from XiaolaiDict's
/// `ScreenWordBoundsTests`): the text-range dialect asks for the token's own range, the bounds scan keeps the box it
/// already asked for. A box the app answers empty is no box.
struct PointerWordBoundsTests {
    /// An app that says its text is `Int.max` long, and that the pointer is at its last character.
    private final class Endless: AccessibilityReading {
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXNumberOfCharactersAttribute: Int.max as CFNumber
            case kAXRoleAttribute: "AXTextArea" as CFString
            default: nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            guard name == kAXRangeForPositionParameterizedAttribute else { return nil }
            var range = CFRange(location: .max - 1, length: 1)
            return AXValueCreate(.cfRange, &range)
        }
    }

    private let target = PointerWordReader.Target(
        element: AXUIElementCreateApplication(pid_t(4_100_000)), appName: "Glyphs", bundleID: "glyphs")
    /// Over "cat" in "The cat sat." — characters 4…6, x 140…170.
    private let point = CGPoint(x: 155, y: 210)

    /// The paragraph's box is every word's box: the pointer over the fourth word must not be answered with the first.
    /// The pointer over the fourth word of the page's line reads that word, through the web area's lying wrapper.
    @Test func theWebAreasPageIsReadThroughItsWrapper() {
        let page = ChromePage()
        let webTarget = PointerWordReader.Target(element: page.webArea, appName: "Chrome", bundleID: "com.google.Chrome")
        // "militia" spans UTF-16 7…13, x 170…240 in the line at y 200…220.
        let outcome = PointerWordReader.readUnlessRefused(
            at: CGPoint(x: 175, y: 210), in: webTarget, tolerance: Measured.hit, labels: Measured.label,
            limits: .shipped, refuses: { _ in false }, with: page)
        guard case .read(.hit(let hit)) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(hit.word.word == "militia")
    }

    @Test func oneBoxForEveryWordIsNotAWord() {
        let flat = FlatBoxes("war or militia advanced")
        let outcome = PointerWordReader.read(at: CGPoint(x: 320, y: 210), in: target, tolerance: Measured.hit, with: flat)
        if case .hit(let hit) = outcome {
            Issue.record("a shared box answered \(hit.word.word) as if it were under the pointer")
        }
    }

    private func hit(_ ax: some AccessibilityReading) -> PointerWordReader.Hit? {
        guard case .hit(let hit) = PointerWordReader.read(at: point, in: target, tolerance: Measured.hit, with: ax) else {
            return nil
        }
        return hit
    }

    @Test func theTextRangeDialectAsksForTheTokensOwnBox() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: true)))
        #expect(hit.word.word == "cat")
        #expect(hit.acquisition == .textRange)
        #expect(hit.bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
    }

    @Test func theBoundsScanKeepsTheBoxItAlreadyAskedFor() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: false)))
        #expect(hit.acquisition == .boundsScan)
        #expect(hit.bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
    }

    /// **The word is read; its box is worth having, not worth the word**: the word stands with no box.
    @Test func aTokenBoxThatFailsKeepsTheWordWithNoBox() throws {
        for failure in [CaptureError.notResponding, .deadlineExceeded, .appUnavailable] {
            let found = try #require(hit(Glyphs("The cat sat.", speaksTextRange: true, failingTokenBox: failure)),
                                     "\(failure) after the word was read lost the word")
            #expect(found.word.word == "cat")
            #expect(found.acquisition == .textRange)
            #expect(found.bounds == nil)
        }
    }

    /// **And the reader moving on still ends the read**: a cancellation at that request is a cancellation, not a word.
    @Test func aTokenBoxCancelledCancelsTheRead() {
        let outcome = PointerWordReader.read(
            at: point, in: target, tolerance: Measured.hit,
            with: Glyphs("The cat sat.", speaksTextRange: true, failingTokenBox: .cancelled))
        #expect(outcome == .cancelled)
    }

    /// **An index from another process is summed without trapping**: it reads nothing there, and returns.
    @Test func anIndexAtTheLargestLengthReadsNothingAndNeverTraps() {
        #expect(hit(Endless()) == nil)
    }

    /// An app answering the token's box empty reads its word and locates nothing. **The word must be read**.
    @Test func anEmptyBoxLocatesNothing() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: true, emptyTokenBox: true)),
                               "the word was not read, so its missing box says nothing")
        #expect(hit.word.word == "cat")
        #expect(hit.bounds == nil)
    }
}
