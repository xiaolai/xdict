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
    /// The label slack the tokens hand in (verifier's oracle, 2026-10-19): 12 pt off centre, 2 pt smaller.
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
