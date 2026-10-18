import CoreGraphics
import XDictCapture

/// **The values XiaolaiDict measured, as the tests hand them in.** The target holds none of them (ADR-0014 decision
/// 11): the app composes its own from tokens, and the tests from these, which are the numbers the ported tests were
/// written against (ADR-0016 there: 3 pt across, 2 pt down; ADR-0045: 2 pt rest; the strip 300/150/600 pt; tiling 4 and
/// 16 band pixels).
enum Measured {
    static let hit: HitTolerance = {
        guard let tolerance = HitTolerance(horizontal: 3, vertical: 2) else { preconditionFailure("a valid tolerance") }
        return tolerance
    }()
    static let restTolerance: CGFloat = 2
    static let strip = StripMetrics(initialHeight: 300, growthStep: 150, maximumHeight: 600)
    static let tiling = TilingMetrics(edgeSlack: 4, holeSlack: 16)
    static let metrics = CaptureMetrics(hit: hit, restTolerance: restTolerance, strip: strip, tiling: tiling)
    /// XiaolaiDict's sentence bound, the context limit the ported paragraph tests were written against.
    static let contextUTF16 = 1000
}
