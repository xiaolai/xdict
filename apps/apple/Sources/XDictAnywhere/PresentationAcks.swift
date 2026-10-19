import CoreGraphics
import XDictCapture
import XDictTokens

/// One terminal acknowledgement for a presented request: its number, the generation it was delivered under, and how it
/// ended — what the consumer hands back to `CaptureRequests.acknowledge`.
public struct PresentationAck: Sendable, Equatable {
    public let request: CaptureRequest
    public let generation: Int
    public let outcome: CaptureOutcome

    public init(request: CaptureRequest, generation: Int, outcome: CaptureOutcome) {
        self.request = request
        self.generation = generation
        self.outcome = outcome
    }
}

/// **What the popover did with the request it presents, as the acknowledgement it owes** (ADR-0014 decision 4: "seen" is
/// the consumer's). The invisible anchor window never counts, and `popover.isShown` alone is not a draw of the new
/// content, so:
///
/// - **shown** is the popover up *and* the presented term's own lookup drawn — its entry finished loading, or its lookup
///   settled with nothing to show (the panel's "No entries found.") — told by `drew(query:popoverVisible:)` with the
///   query the panel is showing, so another lookup's late document never acknowledges this one;
/// - **not shown** is a popover that did not come up for it;
/// - **cancelled** is the request's book's (`CaptureRequests.close`, or a later claim), not this value's.
///
/// One request presented at a time; a newer delivery — another request, or the same one under a newer generation —
/// replaces it, and each acknowledgement is given once. A value, so the rule is tested without a window.
public struct PresentationAcks: Sendable, Equatable {
    public struct Presenting: Sendable, Equatable {
        public let request: CaptureRequest
        public let generation: Int
        public let term: String
    }

    public private(set) var presenting: Presenting?

    public init() {}

    /// `request`'s term was handed to the popover under `generation`.
    public mutating func delivered(_ request: CaptureRequest, generation: Int, term: String) {
        presenting = Presenting(request: request, generation: generation, term: term)
    }

    /// The popover was asked to show it: not coming up is the end, not shown; coming up is not yet a draw.
    public mutating func shown(popoverVisible: Bool) -> PresentationAck? {
        guard !popoverVisible, let current = presenting else { return nil }
        presenting = nil
        return PresentationAck(request: current.request, generation: current.generation, outcome: .notShown)
    }

    /// The panel drew a lookup of `query` — an entry finished, or a settled lookup with nothing to show.
    public mutating func drew(query: String?, popoverVisible: Bool) -> PresentationAck? {
        guard popoverVisible, let current = presenting, query == current.term else { return nil }
        presenting = nil
        return PresentationAck(request: current.request, generation: current.generation, outcome: .shown)
    }

    /// The popover closed: nothing is presented any more.
    public mutating func closed() {
        presenting = nil
    }
}

/// **Where the popover points, from the box capture handed over** (plan-capture WI-3): capture speaks y down; the popover's
/// anchor is in AppKit's space, y up, flipped once here about the primary display's height.
public enum PanelAnchor {
    /// A measured box, flipped; a click-based placement as a word of no width on one reading line — its point the middle
    /// of the line, so the arrow lands at the line's edge (the Service's fallback since plan-macos-v1 WI-8); no box, nil.
    public static func rect(for box: WordBox, primaryHeight: CGFloat) -> CGRect? {
        switch box {
        case .absent:
            return nil
        case .measured(let bounds):
            return bounds.rect.flipped(aboutPrimaryHeight: primaryHeight).cg
        case .clickPlacement(let point):
            let clicked = point.flipped(aboutPrimaryHeight: primaryHeight).cg
            return CGRect(x: clicked.x, y: clicked.y - Tokens.Inset.clickedWordRise, width: Tokens.Size.pointAnchor.width,
                          height: Tokens.Row.clickedWord)
        }
    }
}
