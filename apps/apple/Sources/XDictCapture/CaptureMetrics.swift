import CoreGraphics

/// **Every distance capture measures with, handed in by whoever composes it** (ADR-0014 decisions 5 and 11).
///
/// This target may not import `XDictTokens` (it binds AppKit and SwiftUI), and a literal tolerance here would be a
/// design value no token holds. So no value of this type is written in this target: the composition layer builds one
/// from its tokens, and the tests from the values XiaolaiDict measured. Each field names its unit.
public struct CaptureMetrics: Sendable, Equatable {
    /// How far from a word a resting pointer may be and still mean it — one rule for every capture path.
    public let hit: HitTolerance
    /// How far a resting pointer may drift and still be resting, in screen points (XiaolaiDict ADR-0045).
    public let restTolerance: CGFloat
    /// The strip the pixel path reads, in screen points.
    public let strip: StripMetrics
    /// The band's tiling slacks, in band **pixels**.
    public let tiling: TilingMetrics

    public init(hit: HitTolerance, restTolerance: CGFloat, strip: StripMetrics, tiling: TilingMetrics) {
        self.hit = hit
        self.restTolerance = restTolerance
        self.strip = strip
        self.tiling = tiling
    }
}

/// **The strip the pixel path reads, and how it grows**, in screen points (`ContextStrip`).
public struct StripMetrics: Sendable, Equatable {
    /// Where reading starts.
    public let initialHeight: CGFloat
    /// How far an open side grows per read.
    public let growthStep: CGFloat
    /// The tallest strip read.
    public let maximumHeight: CGFloat

    public init(initialHeight: CGFloat, growthStep: CGFloat, maximumHeight: CGFloat) {
        self.initialHeight = initialHeight
        self.growthStep = growthStep
        self.maximumHeight = maximumHeight
    }
}

/// **The band's tiling slacks**, in band pixels (`BandTiling`).
public struct TilingMetrics: Sendable, Equatable {
    /// How close to a tile's inner edge a box may end and still be called cut by it.
    public let edgeSlack: CGFloat
    /// How much ink a dropped run may have seen that no kept run covers before the kept reading is missing text.
    public let holeSlack: CGFloat

    public init(edgeSlack: CGFloat, holeSlack: CGFloat) {
        self.edgeSlack = edgeSlack
        self.holeSlack = holeSlack
    }
}
