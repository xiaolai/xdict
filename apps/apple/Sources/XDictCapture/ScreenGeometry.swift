import CoreGraphics
import Foundation

/// How far from a word a resting pointer may be and still mean it — **one rule for every capture
/// path**, in screen points.
///
/// Pointers rest imprecisely, and word boxes from different sources — text layout, web layout,
/// OCR — disagree by a point or two at the edges. With a tolerance per path, the same pointer
/// position hit or missed depending on which path happened to answer, which the reader experiences
/// as the app being unreliable rather than as two paths disagreeing
/// (the screen-word spike, finding 7).
///
/// **A value handed in, never a literal here** (ADR-0014 decision 11): the composition layer builds it from its tokens
/// (XiaolaiDict measured 3 pt across and 2 pt down).
public struct HitTolerance: Sendable, Equatable {
    public let horizontal: CGFloat
    public let vertical: CGFloat

    /// Nil unless both are finite and not negative: a tolerance of NaN admits nothing and says nothing about why.
    public init?(horizontal: CGFloat, vertical: CGFloat) {
        guard horizontal.isFinite, vertical.isFinite, horizontal >= 0, vertical >= 0 else { return nil }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Distance from `point` to the nearest edge of `box`, zero inside it, or nil beyond the
    /// tolerance. Where two words qualify, the smaller distance wins — comparing *centres*
    /// instead lets a short neighbour steal the edge of a long word.
    public func distance(from point: CGPoint, to box: CGRect) -> CGFloat? {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        guard dx <= horizontal, dy <= vertical else { return nil }
        return hypot(dx, dy)
    }
}

/// Coordinate conversions for the screen-reading paths. Screen points are global with a top-left
/// origin — the CGEvent and Accessibility space. Vision reports boxes normalised with a
/// bottom-left origin.
public enum CaptureGeometry {
    /// A `size` rect centred on `cursor`, shifted — never shrunk — to stay inside `display`.
    public static func rect(around cursor: CGPoint, size: CGSize, within display: CGRect) -> CGRect {
        let width = min(size.width, display.width)
        let height = min(size.height, display.height)
        let x = min(max(cursor.x - width / 2, display.minX), display.maxX - width)
        let y = min(max(cursor.y - height / 2, display.minY), display.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `point` in `region`'s normalised space: 0...1, top-left origin.
    public static func normalized(_ point: CGPoint, in region: CGRect) -> CGPoint {
        CGPoint(x: (point.x - region.minX) / region.width, y: (point.y - region.minY) / region.height)
    }

    /// A box in `region`'s normalised space, back in the region's own points — `normalized`'s inverse, for a box the
    /// recogniser read in a capture of that region.
    public static func box(_ normalised: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + normalised.minX * region.width, y: region.minY + normalised.minY * region.height,
               width: normalised.width * region.width, height: normalised.height * region.height)
    }

    /// Which of `count` characters spread evenly across `span` lies under `x`, clamped to the span.
    ///
    /// An estimate, and exact for monospaced runs such as CJK — which is where it is needed. Word
    /// breaks differ between sources: WebKit calls 看书 one word and `NLTokenizer` splits it, so
    /// re-segmenting from the word's *start* returned 看 while the pointer was on 书 (finding 8).
    public static func characterIndex(at x: CGFloat, across span: ClosedRange<CGFloat>, count: Int) -> Int {
        let width = span.upperBound - span.lowerBound
        guard count > 0, width > 0, width.isFinite, x.isFinite else { return 0 }
        let fraction = (x - span.lowerBound) / width
        // Clamped **before** the conversion, not after: `Int(someHugeCGFloat)` traps rather than
        // saturating, and `x` comes from a pointer position the caller does not control. A span of
        // 1e-20 is enough to overflow an ordinary coordinate into it.
        guard fraction.isFinite else { return 0 }
        let scaled = (fraction * CGFloat(count)).rounded(.down)
        guard scaled > 0 else { return 0 }
        guard scaled < CGFloat(count) else { return count - 1 }
        return Int(scaled)
    }

    /// A Vision rect — normalised, bottom-left origin — in top-left-origin terms.
    /// The 1 is the height of the normalised space itself, not a length on screen.
    public static func flippedFromVision(_ rect: CGRect) -> CGRect {
        var flipped = rect
        flipped.origin.y = 1 - rect.maxY
        return flipped
    }
}
