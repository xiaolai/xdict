import CoreGraphics
import Foundation

// **What capture hands over, and nothing about lookup** (ADR-0014 decision 2). The trigger (how the reader asked) and
// the acquisition (how the text was read) are two fields, never one `method`. The source app may be unknown, the pointer
// and time may be absent, the word box is absent, measured (exact or containing) or a click-based placement fallback —
// true only at capture time — and the context is an outcome: available (the sentence, the term's range in it in UTF-16,
// which outer ends are cut, and an internal gap kept apart from the ends), pending (a handle that travels beside the
// value and can be cancelled), or unavailable with its reason. Captured text is untrusted data for every consumer.

public enum CaptureTrigger: String, Sendable, Equatable, CaseIterable { case selection, service, pointerGesture, menu }
public enum CaptureAcquisition: String, Sendable, Equatable, CaseIterable {
    case textRange, textMarkers, boundsScan, recognition, serviceText
}
public struct SourceApp: Sendable, Equatable {
    public let bundleID: String?
    public init(bundleID: String?) { self.bundleID = bundleID }
}
public struct PointerSample: Sendable, Equatable {
    public let point: DownPoint
    public let at: ContinuousClock.Instant?
    public init(point: DownPoint, at: ContinuousClock.Instant?) { self.point = point; self.at = at }
}
public enum WordBox: Sendable, Equatable { case absent, measured(ReadBounds), clickPlacement(DownPoint) }
public struct CutEnds: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let start = CutEnds(rawValue: 1 << 0)
    public static let end = CutEnds(rawValue: 1 << 1)
}
public enum InternalGap: String, Sendable, Equatable { case unreadSpan, joinedAcrossTiles }
public struct PendingContextHandle: Sendable, Hashable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}
public enum ContextUnavailable: String, Sendable, Equatable {
    case appExposedNone, disagreesWithServiceText, notCaptured
    /// The app or the site is one capture never reads (`HoverPolicy.excludes(app:)`, `refuses`): nothing around the
    /// term was read.
    case excluded
}
public enum ContextOutcome: Sendable, Hashable {
    case available(sentence: String, term: NSRange, cut: CutEnds, gap: InternalGap?)
    case pending(PendingContextHandle)
    case unavailable(ContextUnavailable)
}
public enum CaptureValueError: Error, Sendable, Equatable {
    case term, range, rangeSplitsCharacter, geometry, confidence
    /// A sentence longer than `CaptureLimits.contextCeilingUTF16`: a reader that did not cut before segmenting.
    case contextTooLong
}

public struct CapturedTerm: Sendable, Equatable {
    public let term: String
    public let trigger: CaptureTrigger
    public let acquisition: CaptureAcquisition
    public let confidence: Double
    public let source: SourceApp
    public let pointer: PointerSample?
    public let box: WordBox
    public let context: ContextOutcome

    /// **The only way to make one, and it validates rather than trims** (ADR-0014 decision 3):
    ///
    /// - the term is not empty and holds no control character (Unicode `Cc`: NUL, the C0 and C1 sets) — a term with one
    ///   is refused, never cleaned, since a cleaned key is a key nobody captured; it is never truncated, whatever its
    ///   length (the consumer's admission limit is not capture's);
    /// - confidence is finite and in 0...1;
    /// - every coordinate is finite;
    /// - an available context's range lies inside its sentence (no `NSNotFound`, no overflow), starts and ends on whole
    ///   characters (no split surrogate pair) and holds exactly the term. In the sentence, tab and line breaks become a
    ///   space and every other control character is removed, **and the range moves with the text**. Format characters
    ///   (`Cf`: joiners, direction marks) and combining marks are meaningful and kept.
    public static func make(
        term: String, trigger: CaptureTrigger, acquisition: CaptureAcquisition, confidence: Double, source: SourceApp,
        pointer: PointerSample?, box: WordBox, context: ContextOutcome
    ) throws(CaptureValueError) -> CapturedTerm {
        guard !term.isEmpty, !term.unicodeScalars.contains(where: isControl) else { throw .term }
        guard confidence.isFinite, (0...1).contains(confidence) else { throw .confidence }
        if let pointer, !finite(pointer.point.cg) { throw .geometry }
        switch box {
        case .absent: break
        case .measured(let bounds):
            let rect = bounds.rect.cg
            guard finite(rect.origin), rect.width.isFinite, rect.height.isFinite else { throw .geometry }
        case .clickPlacement(let point):
            guard finite(point.cg) else { throw .geometry }
        }
        let checked: ContextOutcome
        if case .available(let sentence, _, _, _) = context, sentence.utf16.count > CaptureLimits.contextCeilingUTF16 {
            throw .contextTooLong
        }
        if case .available(let sentence, let range, let cut, let gap) = context {
            let (text, moved) = try cleaned(sentence, keeping: range, term: term)
            checked = .available(sentence: text, term: moved, cut: cut, gap: gap)
        } else {
            checked = context
        }
        return CapturedTerm(term: term, trigger: trigger, acquisition: acquisition, confidence: confidence,
                            source: source, pointer: pointer, box: box, context: checked)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .control }

    private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    /// Breaks that become a space rather than vanish: the words either side stay apart.
    private static let breaks: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}"]

    /// The sentence with control characters handled and `range` moved to match, or `.range` where the range is not a
    /// whole-character span of the sentence holding `term`.
    private static func cleaned(
        _ sentence: String, keeping range: NSRange, term: String
    ) throws(CaptureValueError) -> (String, NSRange) {
        let units = Array(sentence.utf16)
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location
        else { throw .range }
        // A boundary inside a surrogate pair: the unit at either edge is a pair's second half.
        let end = range.location + range.length
        if range.location < units.count, UTF16.isTrailSurrogate(units[range.location]) { throw .rangeSplitsCharacter }
        if end < units.count, UTF16.isTrailSurrogate(units[end]) { throw .rangeSplitsCharacter }
        guard range.length == term.utf16.count, let span = Range(range, in: sentence), sentence[span] == term
        else { throw .range }
        var out = String.UnicodeScalarView()
        var location = range.location
        var offset = 0
        for scalar in sentence.unicodeScalars {
            let width = scalar.utf16.count
            defer { offset += width }
            guard isControl(scalar) else {
                out.append(scalar)
                continue
            }
            if breaks.contains(scalar) {
                out.append(" ")
                continue
            }
            // Removed: one before the term moves it left. The term holds none, so none falls inside it.
            if offset < range.location { location -= width }
        }
        return (String(out), NSRange(location: location, length: range.length))
    }
}
