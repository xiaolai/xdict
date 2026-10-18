import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization
@preconcurrency import Vision
import XDictBase
import XDictCapture
import os

/// **What the recogniser saw**: the word and its sentence, how far to trust them, and where to look for more.
///
/// **Metadata only in every description** (XDict ADR-0014 decision 9): it carries the sentence, and none of its
/// descriptions does.
public struct Recognition: Sendable {
    public let word: WordAtPoint
    /// Vision's lowest confidence among the observations that make up **the sentence in `word`**, 0...1 — not the line
    /// the pointer landed on, and not the whole block the sentence was cut out of.
    public let confidence: Double
    /// The **sentence** may be cut, or spliced from two cut lines into one that was never on screen. Scoped as
    /// `confidence` is, and the same fact as `word.sentence.mayBeCut` by construction.
    public let mayBeCut: Bool
    public let appName: String?
    public let bundleID: String?
    /// Text is missing from inside the sentence, not at its ends: where a line was cut inside (a token every tile cut,
    /// `joinedAcrossTiles`) or the sentence crosses a junction a capture edge cut (`unreadSpan`).
    public let gap: InternalGap?
    /// The sides on which the sentence ran into the strip's edge with no boundary in sight — where a taller strip could
    /// finish it.
    public var wantsMore: StripSides = []
    /// **Where the word is on screen**, y down: the box of the run it was read from (`containing`), checked under the
    /// pointer. Nil where it is not one worth trusting.
    public var bounds: ReadBounds?
    /// **The rest of the sentence, still to be read**: a taller strip toward `wantsMore`, answering the reading it settled
    /// on, or nil where nothing grew. Nil where there is nothing to grow, or no budget to grow it in. Whoever runs it holds
    /// the one capture until it ends.
    public var growth: (@Sendable () async -> Recognition?)?

    /// The sentence as capture's context: its range the word's, its cut ends, and the internal gap kept apart from them.
    public var context: ContextOutcome {
        let sentence = word.sentence
        guard let range = sentence.selection else { return .unavailable(.notCaptured) }
        var cut: CutEnds = []
        if sentence.cut.contains(.start) { cut.insert(.start) }
        if sentence.cut.contains(.end) { cut.insert(.end) }
        return .available(sentence: sentence.text, term: range, cut: cut, gap: gap)
    }

    /// **The word as capture hands it over** (decision 2): trigger `pointerGesture`, acquisition `recognition`, Vision's
    /// own confidence, the run's box measured as `containing` or none, and `context` — the sentence, or `.pending` where
    /// the rest is still being read.
    public func capturedTerm(pointer: PointerSample?, context: ContextOutcome? = nil) throws(CaptureValueError) -> CapturedTerm {
        try CapturedTerm.make(
            term: word.word, trigger: .pointerGesture, acquisition: .recognition, confidence: min(max(confidence, 0), 1),
            source: SourceApp(bundleID: bundleID), pointer: pointer, box: bounds.map(WordBox.measured) ?? .absent,
            context: context ?? self.context)
    }
}

extension Recognition: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "Recognition(\(word.word.count) characters, confidence \(confidence), mayBeCut \(mayBeCut), "
            + "app \(bundleID ?? "unknown"), grows \(growth != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Why the recogniser read nothing. Kinds, never sentences: the consumer words what the reader is told.
public enum RecognitionError: Error, Sendable, Equatable {
    /// The window chosen is no longer offered for capture — it closed, moved, or the screen locked.
    case windowNotCapturable
    case nothingUnderPointer
    /// The window's owner is an app hover never reads.
    case excludedApp
    /// No owner could be named, and a region nobody owns cannot be checked against the exclusions.
    case unattributable
    /// Screen Recording is not set up, or is off: nothing was asked of the system.
    case screenRecordingNeeded
    /// The grant could not be read — which is not its being absent.
    case screenRecordingUnreadable
}

/// **The last path: the window under the pointer, captured and read by Vision, on-device** (ported from XiaolaiDict's
/// `ScreenTextRecogniser`, plan-capture WI-4). It is the slow one — 250–570 ms warm, 0.8–1.8 s cold in XiaolaiDict,
/// against 1–9 ms for Accessibility — and the only one that can be *wrong* rather than absent, so what it returns carries
/// its own confidence. It exists because some surfaces expose no text: a terminal, a canvas, an image.
///
/// **A strip the window's full width, centred on the pointer's row** (`ContextStrip`; never a box around the pointer,
/// which fabricated sentences from two fragments), read in tiles no wider than `CaptureLimits.tilePixels` (XiaolaiDict
/// ADR-0016 addendum: the 5120 px band in one call read 47% of small words, 2000 px tiles 100%), and at most
/// `CaptureLimits.observations` observations taken from one capture, applied before any line is joined.
///
/// ScreenCaptureKit is reached only through `ScreenRecordingAccess`'s state: nothing here runs before the setup row was
/// used or a standing grant is reported (decision 7).
public final class ScreenTextRecogniser: Sendable {
    /// How many times a band is read again for tokens every tile cut. A count: each round is one Vision call per such
    /// token, and two rounds read whole every path XiaolaiDict's 2026-10-11 sweep cut but one.
    static let maximumRereadRounds = 2

    /// **Every capture is bounded, and only one runs at a time**: two simultaneous `SCScreenshotManager` captures deadlock
    /// each other (6 trials of 6, XiaolaiDict ADR-0016), so any other screen-recording app can stall this one. A duration;
    /// the reader holds the one capture past it rather than start a second (`CaptureGuard`).
    public static let captureDeadline: Duration = .seconds(5)

    private let metrics: CaptureMetrics
    private let limits: CaptureLimits
    private let access: ScreenRecordingAccess
    private let capturer: any ScreenCapturing

    /// `metrics` from the composition layer's tokens (decision 11).
    public convenience init(metrics: CaptureMetrics, limits: CaptureLimits = .shipped, access: ScreenRecordingAccess = .system) {
        self.init(metrics: metrics, limits: limits, access: access,
                  capturer: SystemScreenCapturer(frameDrift: metrics.frameDrift))
    }

    /// `capturer` is the screen: the real one above, a stand-in in the tests that count captures.
    init(metrics: CaptureMetrics, limits: CaptureLimits, access: ScreenRecordingAccess, capturer: any ScreenCapturing) {
        self.metrics = metrics
        self.limits = limits
        self.access = access
        self.capturer = capturer
    }

    /// Reads `window` — **the one the caller chose** — in a strip around `point`. Consent first, then the window's owner
    /// against `policy` **before any pixel is captured**: the Accessibility path cannot vet an app that exposes no element,
    /// and that is exactly the case this path serves.
    public func read(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        try Task.checkCancellation()
        let target = try await authorisedTarget(at: point, window: window, policy: policy)
        let started = ContinuousClock.now
        var first = try await read(target, at: point, of: window)
        let lastRead = ContinuousClock.now - started
        // **The word now, the rest of the sentence after**: offered only where a taller strip could be read inside the
        // budget, so a sentence nothing can finish is never drawn as still being read.
        if taller(than: target, toward: first.wantsMore, elapsed: lastRead, lastRead: lastRead) != nil {
            first.growth = { [self, first] in
                await self.grow(first, strip: target, at: point, of: window, started: started, lastRead: lastRead)
            }
        }
        return first
    }

    private func taller(
        than strip: CaptureTarget, toward sides: StripSides, elapsed: Duration, lastRead: Duration
    ) -> CaptureTarget? {
        guard !sides.isEmpty,
              let taller = ContextStrip.grown(
                strip.region.minY...strip.region.maxY, toward: sides, within: strip.frame.minY...strip.frame.maxY,
                metrics: metrics.strip),
              ContextStrip.affordable(elapsed: elapsed, lastRead: lastRead)
        else { return nil }
        return strip.vertically(taller)
    }

    /// **Grown only where the sentence ran into the strip's edge**, while a further read can finish inside the budget
    /// counted from the first read's start. Answers the last reading made, or nil where none was made beyond `first`.
    private func grow(
        _ first: Recognition, strip from: CaptureTarget, at point: CGPoint, of window: ListedWindow,
        started: ContinuousClock.Instant, lastRead firstRead: Duration
    ) async -> Recognition? {
        var strip = from
        var reading = first
        var grown: Recognition?
        var lastRead = firstRead
        while let next = taller(than: strip, toward: reading.wantsMore, elapsed: ContinuousClock.now - started,
                                lastRead: lastRead) {
            guard !Task.isCancelled else { return nil }
            let begun = ContinuousClock.now
            do {
                reading = try await read(next, at: point, of: window)
            } catch {
                // **What was read stands**: the reading already made carries its own `mayBeCut`.
                Self.log.notice("capture: a taller strip was not read (\(String(describing: error), privacy: .public))")
                break
            }
            strip = next
            grown = reading
            lastRead = ContinuousClock.now - begun
        }
        return Task.isCancelled ? nil : grown
    }

    /// One capture of `target` and its reading.
    private func read(_ target: CaptureTarget, at point: CGPoint, of window: ListedWindow) async throws -> Recognition {
        try Task.checkCancellation()
        let image = try await capturer.capture(target, of: window)
        try Task.checkCancellation()
        let lines = try Self.recognise(image, limits: limits, slack: metrics.tiling) { tile in
            try Self.recogniseWhole(tile)
        }
        return try hit(in: lines, at: point, target: target)
    }

    private static let log = Logger(subsystem: XDictIdentity.app, category: "recognition")

    /// Consent, then the window's capture target, then its owner against `policy` — all before a pixel.
    private func authorisedTarget(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> CaptureTarget {
        switch await access.captureState() {
        case .granted: break
        case .notSetUp, .declined: throw RecognitionError.screenRecordingNeeded
        case .couldNotTell: throw RecognitionError.screenRecordingUnreadable
        }
        try Task.checkCancellation()
        let target = try await capturer.target(at: point, window: window, stripHeight: metrics.strip.initialHeight)
        guard let bundleID = target.bundleID else { throw RecognitionError.unattributable }
        if CaptureAuthorization.refusal(bundleID: bundleID, policy: policy) != nil { throw RecognitionError.excludedApp }
        return target
    }

    /// The recognised word under `point`, or `.nothingUnderPointer`.
    private func hit(in lines: [RecognisedLine], at point: CGPoint, target: CaptureTarget) throws -> Recognition {
        let cursor = CaptureGeometry.normalized(point, in: target.region)
        // The shared tolerance, in the capture's normalised units.
        let slack = CGSize(width: metrics.hit.horizontal / target.region.width,
                           height: metrics.hit.vertical / target.region.height)
        guard let pick = RecognisedTextPicker.pick(at: cursor, in: lines, slack: slack, region: target.region.size),
              var read = Self.reading(lines, pick: pick, at: cursor, region: target.region.size, appName: target.appName,
                                      bundleID: target.bundleID, limits: limits)
        else { throw RecognitionError.nothingUnderPointer }
        read.bounds = ReadBounds.checked(
            CaptureGeometry.box(lines[pick.line].runs[pick.run].box, in: target.region), quality: .containing, near: point,
            tolerance: metrics.hit)
        return read
    }

    /// **The deterministic half of `read`**: recognised lines and a pointer in, the word, its sentence and their quality
    /// out — a pure function, exercised without a screen. Both quality signals are scoped to the sentence returned, never
    /// to the line the pointer landed on or the block it was cut from (XiaolaiDict ADR-0016).
    static func reading(
        _ lines: [RecognisedLine], pick: RecognisedPick, at cursor: CGPoint, region: CGSize,
        appName: String?, bundleID: String?, limits: CaptureLimits
    ) -> Recognition? {
        // **The paragraph around the pointer, in its own column**, and the sides on which the strip ran out before it;
        // the context limit applied before it is assembled (ADR-0014 decision 3).
        let paragraph = ParagraphFinder.paragraph(around: pick.line, in: lines, region: region,
                                                  maximumUTF16: limits.contextUTF16)
        let block = paragraph.block
        let blockClipped = clipping(paragraph.open, across: block.lineIndices.map { lines[$0].box })
        // **Which token of the run, decided by the pointer**: a run is all Vision can box.
        let run = lines[pick.line].runs[pick.run]
        let within = CaptureGeometry.characterIndex(at: cursor.x, across: run.box.minX...run.box.maxX,
                                                    count: run.text.utf16.count)
        let start = TextSegmenter.wordStart(nearest: within, in: run.text) ?? 0
        let offset = block.offsetShift + run.utf16Offset + start
        guard let word = TextSegmenter.word(in: block.text, utf16Offset: offset, clipped: blockClipped) else { return nil }

        let span = Self.span(of: word.sentence, containing: offset, in: block.text)
        let covering = block.lines(covering: span, in: lines)
        let clipped = clipping(paragraph.open, across: covering.map { lines[$0].box })
        // **One clipping answer**: the geometric one is an input to the segmenter, and the segmenter's the only output.
        let settled = clipped == blockClipped ? word : TextSegmenter.word(in: block.text, utf16Offset: offset,
                                                                          clipped: clipped)
        guard let settled else { return nil }
        // **And the junction, which neither answer sees**: a sentence across two observations cut where they meet.
        let junction = zip(covering, covering.dropFirst()).contains { CaptureEdge.cutsBetween(lines[$0].box, lines[$1].box) }
        let cutInside = covering.contains { lines[$0].cutInside }
        let cut = settled.sentence.mayBeCut || junction || cutInside
        guard let sentence = SentenceContext(
            text: settled.sentence.text, mayBeCut: cut, selection: settled.sentence.selection, cut: settled.sentence.cut)
        else { return nil }
        // **What a taller strip could finish**: an open side the sentence reaches, unless the length cap closed it.
        var wantsMore: StripSides = []
        if paragraph.growable.contains(.above), span.location == 0 { wantsMore.insert(.above) }
        if paragraph.growable.contains(.below), NSMaxRange(span) >= (block.text as NSString).length { wantsMore.insert(.below) }
        let gap: InternalGap? = cutInside ? .joinedAcrossTiles : junction ? .unreadSpan : nil
        return Recognition(
            word: WordAtPoint(word: settled.word, sentence: sentence), confidence: block.confidence(over: span, in: lines),
            mayBeCut: cut, appName: appName, bundleID: bundleID, gap: gap, wantsMore: wantsMore)
    }

    /// Which ends of the text read may be cuts: both, where a line runs into the window's left or right edge; otherwise
    /// the start where the strip's top was open and the end where its bottom was.
    static func clipping(_ open: StripSides, across boxes: [CGRect]) -> TextSegmenter.Clipping {
        if CaptureEdge.clipsAcross(boxes) { return [.start, .end] }
        var clipping: TextSegmenter.Clipping = []
        if open.contains(.above) { clipping.insert(.start) }
        if open.contains(.below) { clipping.insert(.end) }
        return clipping
    }

    /// Where the returned sentence sits inside the block, UTF-16: **the occurrence that covers the pointer**, half-open,
    /// found by searching (arithmetic failed on Chinese, XiaolaiDict ADR-0016). Falls back to the whole block, which can
    /// only over-state how much text the quality signals cover — the safe direction.
    static func span(of sentence: SentenceContext, containing offset: Int, in block: String) -> NSRange {
        let text = block as NSString
        let whole = NSRange(location: 0, length: text.length)
        let needle = sentence.text
        guard !needle.isEmpty else { return whole }
        var searched = whole
        while searched.length > 0 {
            let found = text.range(of: needle, options: [], range: searched)
            guard found.location != NSNotFound else { break }
            if NSLocationInRange(offset, found) { return found }
            let next = found.location + 1
            guard next < text.length else { break }
            searched = NSRange(location: next, length: text.length - next)
        }
        return whole
    }

    /// The maximal runs of non-whitespace in `text` — the unit Vision boxes, and nothing finer.
    static func runs(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            found.append(index..<end)
            index = end
        }
        return found
    }

    /// **The band as the tiles it is read in, and no more observations than the limit** (`CaptureLimits`, applied before
    /// any line is joined): one call where the band fits a tile, otherwise overlapping tiles of `limits.tilePixels`
    /// overlapping by `limits.tileOverlapPixels`, each read on its own and put back together (`BandTiling`), tokens every
    /// tile cut read again from a tile of their own. Every read counts against `limits.observations`; once it is spent no
    /// further tile is read, and what was kept is said to be so in the log. `readTile` is the seam to Vision.
    static func recognise(
        _ image: CGImage, limits: CaptureLimits, slack: TilingMetrics, reading readTile: (CGImage) throws -> [RecognisedLine]
    ) throws -> [RecognisedLine] {
        var budget = limits.observations
        func taken(_ lines: [RecognisedLine]) -> [RecognisedLine] {
            guard lines.count > budget else {
                budget -= lines.count
                return lines
            }
            log.notice("capture: \(lines.count, privacy: .public) observations where \(budget, privacy: .public) remained; the rest are not read")
            defer { budget = 0 }
            return Array(lines.prefix(budget))
        }
        let tiles = BandTiling.tiles(forWidth: image.width, maximum: limits.tilePixels, overlap: limits.tileOverlapPixels)
        guard tiles.count > 1 else { return taken(try readTile(image)) }
        var read: [(tile: BandTile, lines: [RecognisedLine])] = []
        func readAll(_ tiles: [BandTile]) throws {
            for tile in tiles {
                guard budget > 0 else { return }
                try Task.checkCancellation()
                guard let part = image.cropping(to: CGRect(x: tile.x, y: 0, width: tile.width, height: image.height)) else {
                    throw RecognitionError.windowNotCapturable
                }
                read.append((tile, taken(try readTile(part))))
            }
        }
        try readAll(tiles)
        var rounds = 0
        var again = BandTiling.rereads(read, bandWidth: image.width, maximum: limits.tilePixels, slack: slack)
        while !again.isEmpty, rounds < maximumRereadRounds, budget > 0 {
            try readAll(again)
            rounds += 1
            again = BandTiling.rereads(read, bandWidth: image.width, maximum: limits.tilePixels, slack: slack)
        }
        return BandTiling.merged(read, bandWidth: image.width, slack: slack)
    }

    /// One Vision call on `image`: accurate, no language correction (it "fixes" rare words into common ones), and the
    /// language detected, never pinned (pinned `en-US` read Chinese as Latin garbage; pinned `zh-Hans` misread 今天 as
    /// 念天 — XiaolaiDict ADR-0016).
    static func recogniseWhole(_ image: CGImage) throws -> [RecognisedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            // **Runs, not tokeniser words**: asked for part of a run, Vision returns the whole run's box.
            let runs = Self.runs(in: text).compactMap { range -> RecognisedRun? in
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                return RecognisedRun(text: String(text[range]),
                                     utf16Offset: text.utf16.distance(from: text.startIndex, to: range.lowerBound),
                                     box: CaptureGeometry.flippedFromVision(box))
            }
            return RecognisedLine(text: text, box: CaptureGeometry.flippedFromVision(observation.boundingBox), runs: runs,
                                  confidence: Double(candidate.confidence))
        }
    }

}

// MARK: - The window

/// What capturing one window needs again, opaque to the recogniser: ScreenCaptureKit's content filter on the real screen,
/// a stand-in in the tests.
protocol CaptureFilter {
    var pointPixelScale: Float { get }
}

extension SCContentFilter: CaptureFilter {}

/// One window's strip, set up for a capture: its owner and frame are known **before any pixel is taken**.
struct CaptureTarget: @unchecked Sendable {
    // `@unchecked`: the filter is made once per target and only read afterwards; ScreenCaptureKit does not mark it.
    let filter: any CaptureFilter
    /// In global screen points.
    let region: CGRect
    /// The same region in the window's own coordinates.
    let sourceRect: CGRect
    let appName: String?
    let bundleID: String?
    /// The window's frame when the capture was set up, in global screen points.
    let frame: CGRect

    /// The same window and width, over `rows` — a vertical range in global screen points.
    func vertically(_ rows: ClosedRange<CGFloat>) -> CaptureTarget {
        let region = CGRect(x: region.minX, y: rows.lowerBound, width: region.width,
                            height: rows.upperBound - rows.lowerBound)
        return CaptureTarget(filter: filter, region: region,
                             sourceRect: CGRect(origin: CGPoint(x: region.minX - frame.minX, y: region.minY - frame.minY),
                                                size: region.size),
                             appName: appName, bundleID: bundleID, frame: frame)
    }
}

/// **The screen side of the recogniser** — who owns a window and where it is, then its pixels — and the seam its tests
/// replace, so the owner checks are observed to come before any capture call.
protocol ScreenCapturing: Sendable {
    /// `window`'s strip, `stripHeight` tall around `point`, with its owner and frame. No pixel is captured.
    func target(at point: CGPoint, window: ListedWindow, stripHeight: CGFloat) async throws -> CaptureTarget
    /// The target's pixels — refused if the window moved while they were taken.
    func capture(_ target: CaptureTarget, of window: ListedWindow) async throws -> CGImage
}

/// **The real screen**: ScreenCaptureKit's window list, cached, and its screenshot, checked against the compositor's live
/// frame before and after.
struct SystemScreenCapturer: ScreenCapturing {
    /// How far two readings of a window's frame may disagree (`CaptureMetrics.frameDrift`, from the tokens).
    let frameDrift: CGFloat
    private let cache = ShareableContentCache()

    func target(at point: CGPoint, window listed: ListedWindow, stripHeight: CGFloat) async throws -> CaptureTarget {
        guard let live = Self.liveBounds(of: listed.windowID) else { throw RecognitionError.windowNotCapturable }
        guard live.contains(point) else { throw RecognitionError.nothingUnderPointer }
        var found = try await shareableContent().windows.first { $0.windowID == listed.windowID }
        if found.map({ !sameGeometry($0.frame, live) }) ?? true {
            try Task.checkCancellation()
            found = try await shareableContent(refresh: true).windows.first { $0.windowID == listed.windowID }
        }
        guard let window = found, sameGeometry(window.frame, live) else { throw RecognitionError.windowNotCapturable }
        let frame = window.frame
        let region = CaptureGeometry.rect(around: point, size: CGSize(width: frame.width, height: stripHeight), within: frame)
        return CaptureTarget(
            filter: SCContentFilter(desktopIndependentWindow: window), region: region,
            sourceRect: CGRect(origin: CGPoint(x: region.minX - frame.minX, y: region.minY - frame.minY), size: region.size),
            appName: window.owningApplication?.applicationName, bundleID: window.owningApplication?.bundleIdentifier,
            frame: frame)
    }

    func capture(_ target: CaptureTarget, of window: ListedWindow) async throws -> CGImage {
        // Only this capturer makes targets with a real filter; any other is refused, never captured.
        guard let filter = target.filter as? SCContentFilter else { throw RecognitionError.windowNotCapturable }
        let config = SCStreamConfiguration()
        config.sourceRect = target.sourceRect
        config.width = Int((target.region.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((target.region.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let after = Self.liveBounds(of: window.windowID), sameGeometry(after, target.frame) else {
            throw RecognitionError.windowNotCapturable
        }
        return image
    }

    /// The window's bounds as the compositor has them now, or nil where it is no longer on screen.
    private static func liveBounds(of windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = info.first,
              first[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = first[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// Two readings of one frame, the same within `frameDrift` on every edge.
    func sameGeometry(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameDrift && abs(a.minY - b.minY) <= frameDrift
            && abs(a.width - b.width) <= frameDrift && abs(a.height - b.height) <= frameDrift
    }

    /// The on-screen window list, cached for `contentLifetime`: fetching it is the path's dominant cost (60–85 ms for
    /// on-screen windows only, XiaolaiDict), and it never gets cheaper with use.
    private func shareableContent(refresh: Bool = false) async throws -> SCShareableContent {
        if !refresh, let cached = cache.current(newerThan: Self.contentLifetime) { return cached }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cache.store(fresh)
        return fresh
    }

    /// How long a fetched window list is trusted. A duration: a window moved inside it is caught by the live frame check.
    static let contentLifetime: Duration = .seconds(3)
}

/// A short-lived cache of ScreenCaptureKit's window list, **never locked across an `await`**: one wedged capture inside
/// an actor would serialise every later read behind it.
private final class ShareableContentCache: Sendable {
    private struct Entry: @unchecked Sendable {
        // `SCShareableContent` is not marked `Sendable`; it is only ever read after being stored, never mutated.
        let content: SCShareableContent
        let fetched: ContinuousClock.Instant
    }

    private let entry = Mutex<Entry?>(nil)

    func current(newerThan age: Duration) -> SCShareableContent? {
        entry.withLock { entry in
            guard let entry, ContinuousClock.now - entry.fetched < age else { return nil }
            return entry.content
        }
    }

    func store(_ content: SCShareableContent) {
        entry.withLock { $0 = Entry(content: content, fetched: .now) }
    }
}
