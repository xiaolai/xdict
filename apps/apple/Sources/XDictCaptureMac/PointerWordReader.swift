import AppKit
import ApplicationServices
import Synchronization
import XDictCapture

/// **The word under a screen point, read through Accessibility** — the fast path, and the one that gets the whole
/// sentence because it reads text rather than pixels (ported from XiaolaiDict's `ScreenWordReader`, plan-capture WI-2).
///
/// Apps expose text in one of three dialects, and three is a floor rather than a ceiling: each new app family may add
/// one, and the recogniser (plan-capture WI-4) is what keeps that from being a correctness problem.
///
/// | Dialect | Where | Warm cost (XiaolaiDict, measured) |
/// |---|---|---|
/// | text range — `AXRangeForPosition` → `AXStringForRange` | Cocoa text views | 8.5 ms |
/// | text markers — `AXTextMarkerForPosition` and friends | WebKit | 3.2 ms |
/// | bounds scan — `AXBoundsForRange` per word | Chromium, Electron | 1.1 ms |
///
/// **Metadata only in every description** (XDict ADR-0014 decision 9): a hit carries the sentence, and none of its
/// descriptions, nor any miss's, contains it.
public enum PointerWordReader {
    /// A word a dialect read, its box where the dialect has one, and the dialect.
    public struct Hit: Sendable, Equatable {
        public let word: WordAtPoint
        public let acquisition: CaptureAcquisition
        public let appName: String
        public let bundleID: String?
        /// Where the word is on screen, y down, where the dialect can say it and the box is worth trusting.
        public let bounds: ReadBounds?

        /// **The word as capture hands it over** (XDict ADR-0014 decision 2): trigger `pointerGesture`, the dialect as the
        /// acquisition, the measured box or none, and the sentence as an available context — its range the word's, its cut
        /// ends where the text read was a window of a longer one.
        public func capturedTerm(pointer: PointerSample?) throws(CaptureValueError) -> CapturedTerm {
            let sentence = word.sentence
            var cut: CutEnds = []
            if sentence.cut.contains(.start) { cut.insert(.start) }
            if sentence.cut.contains(.end) { cut.insert(.end) }
            let context: ContextOutcome = sentence.selection.map {
                ContextOutcome.available(sentence: sentence.text, term: $0, cut: cut, gap: nil)
            } ?? .unavailable(.appExposedNone)
            return try CapturedTerm.make(
                term: word.word, trigger: .pointerGesture, acquisition: acquisition, confidence: 1,
                source: SourceApp(bundleID: bundleID), pointer: pointer, box: bounds.map(WordBox.measured) ?? .absent,
                context: context)
        }
    }

    /// Why a read found no word: typed, so a miss is diagnosable without the text it was about.
    public enum Miss: Sendable, Equatable {
        /// The element at the point exposes no text there; its role, where it said one.
        case noText(app: String, role: String?)
        /// A request failed and ended the read.
        case failed(CaptureError, app: String)
    }

    public enum Outcome: Sendable, Equatable {
        case hit(Hit)
        case miss(Miss)
        /// The reader moved on, and the read stopped between two requests.
        case cancelled
    }

    /// Who owns the pixel under the pointer, found **without reading any text**. `@unchecked`: `AXUIElement` is a CF type
    /// the SDK does not mark `Sendable`, and it is only ever used on the one read that found it, never mutated.
    public struct Target: @unchecked Sendable {
        public let element: AXUIElement
        public let appName: String
        public let bundleID: String?

        public init(element: AXUIElement, appName: String, bundleID: String?) {
            self.element = element
            self.appName = appName
            self.bundleID = bundleID
        }

        /// The process Accessibility found the element in.
        public var pid: pid_t {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return pid
        }
    }

    /// Why no target was found.
    public enum TargetMiss: Sendable, Equatable {
        /// Accessibility is not granted (or the probe could not tell): nothing was asked, and nothing prompted.
        case accessibilityOff
        /// The hit test found nothing at the point.
        case nothingAtPointer
        /// The hit test failed and ended the read.
        case failed(CaptureError)
    }

    public enum TargetOutcome: @unchecked Sendable {
        case found(Target)
        case none(TargetMiss)
        /// The pointer is over one of XDict's own windows. **Nothing else must be tried**: falling through to the
        /// recogniser would capture the window underneath XDict's panel.
        case ourOwnWindow
    }

    /// A hung app must not stall a hover. Per request; the whole read is bounded by `budget`.
    public static let messagingTimeout: Float = 0.25
    /// The whole hover read, however many requests it takes, the hit test included: where the recogniser is measured to
    /// be as fast (XiaolaiDict, 250–570 ms warm), so past it reading the pixels is the cheaper answer.
    public static let budget: Duration = .milliseconds(500)
    /// One request per word, hence the cap: past it, the recogniser is the cheaper answer. An acquisition bound, in words.
    public static let maximumScannedWords = 120
    /// The text read around the pointer's character in the text-range dialect, UTF-16 units each side (XiaolaiDict's).
    public static let textRangeRadiusUTF16 = 300

    /// **Who owns the pixel, asked in this order**: the grant (never prompting, decision 7), then **the compositor's
    /// window list, before Accessibility is asked anything** — where the window under the pointer is one of XDict's own,
    /// at any level (its panel floats), the hit test itself would be serviced in-process on this thread, off the main
    /// actor (XiaolaiDict ADR-0042) — then the system-wide hit test, a request of `ax` and so inside its budget, and the
    /// owner's process checked once more, for a window that arrived since the list was taken.
    public static func target(
        at point: CGPoint, access: AccessibilityAccess, windows: () -> [ListedWindow], ownProcess: pid_t,
        with ax: some AccessibilityReading
    ) -> TargetOutcome {
        guard access.granted() else { return .none(.accessibilityOff) }
        if PointerWindow.ours(at: point, in: windows(), ours: ownProcess) { return .ourOwnWindow }
        let element: AXUIElement
        do throws(CaptureError) {
            guard let found = try ax.hitTest(AXUIElementCreateSystemWide(), at: point) else { return .none(.nothingAtPointer) }
            element = found
        } catch {
            return .none(.failed(error))
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ownProcess else { return .ourOwnWindow }
        let running = NSRunningApplication(processIdentifier: pid)
        return .found(Target(element: element, appName: running?.localizedName ?? "pid \(pid)",
                             bundleID: running?.bundleIdentifier))
    }

    /// The three dialects in order, against any Accessibility client — the real one or a test's. `point` is global with
    /// a top-left origin, Accessibility's space. **A failure ends the read**: `.notResponding` means the app did not
    /// answer one request, and asking it the next hundred questions only multiplies that; the budget running out, or the
    /// reader moving on, ends it the same way. Only an absent value moves on to the next dialect.
    public static func read(
        at point: CGPoint, in target: Target, tolerance: HitTolerance, with ax: some AccessibilityReading
    ) -> Outcome {
        let element = target.element
        func hit(_ found: Located, _ acquisition: CaptureAcquisition) -> Outcome {
            .hit(Hit(word: found.word, acquisition: acquisition, appName: target.appName, bundleID: target.bundleID,
                     bounds: found.bounds))
        }
        do throws(CaptureError) {
            try awaken(target, ax)
            if let found = try textRange(element, at: point, tolerance, ax) { return hit(found, .textRange) }
            if let found = try textMarkers(element, at: point, tolerance, ax) { return hit(found, .textMarkers) }
            if let found = try boundsScan(element, at: point, tolerance, ax) { return hit(found, .boundsScan) }
            // **Nothing answered: ask the app, once, to build its tree for an assistive client.** Chrome exposes no page
            // until it is told one is reading it; this hover still misses — the tree arrives about two seconds later —
            // and the next one reads text. Asked only here, so an app that answers is never told.
            try escalate(target, ax)
            return .miss(.noText(app: target.appName, role: try ax.string(element, kAXRoleAttribute)))
        } catch {
            if error == .cancelled { return .cancelled }
            return .miss(.failed(error, app: target.appName))
        }
    }

    /// The site `target` shows: the host of its web area's address, from the same walk to the page the marker dialect
    /// makes. No web area is not web content; a web area whose address cannot be read, or a read that failed, is
    /// `unreadable` — never guessed to be harmless.
    public static func host(of target: Target, with ax: some AccessibilityReading) -> HostReading {
        do throws(CaptureError) {
            // Woken first: an unwoken Chromium tree has no web area yet, and "no page" read from it would let an
            // excluded site through.
            try awaken(target, ax)
            let area: AXUIElement
            switch try ax.walkToPage(from: target.element) {
            case .page(let found): area = found
            case .application: return .notWebContent
            case .stoppedShort: return .unreadable
            }
            let raw = try ax.attribute(area, kAXURLAttribute, ofApplication: false)
            guard let url = (raw as? URL) ?? (raw as? String).flatMap({ URL(string: $0) }) else { return .unreadable }
            if let host = url.host(percentEncoded: false), !host.isEmpty { return .known(host) }
            return url.isFileURL || url.scheme == "about" ? .notWebContent : .unreadable
        } catch {
            return .unreadable
        }
    }

    // MARK: - text range

    /// A word a dialect read, and its box where it has one.
    typealias Located = (word: WordAtPoint, bounds: ReadBounds?)

    private static func textRange(
        _ element: AXUIElement, at point: CGPoint, _ tolerance: HitTolerance, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> Located? {
        guard let index = try ax.range(element, kAXRangeForPositionParameterizedAttribute, value(point))?.location,
              let count = try ax.integer(element, kAXNumberOfCharactersAttribute),
              index >= 0, index < count
        else { return nil }
        // `index` and `count` are another process's: `index + radius` trapped for an index within the radius of
        // `Int.max` (XiaolaiDict, audit of 2026-10-10). `count - index` is positive here, so neither line can overflow.
        let start = max(0, index - textRangeRadiusUTF16)
        let end = index + min(textRangeRadiusUTF16, count - index)
        guard let text = try ax.string(
            element, kAXStringForRangeParameterizedAttribute, value(CFRange(location: start, length: end - start)))
        else { return nil }
        // The window is a radius each side, so a longer sentence is cut by this rather than by the app — and a cut
        // sentence must say so.
        var clipped = TextSegmenter.Clipping()
        if start > 0 { clipped.insert(.start) }
        if end < count { clipped.insert(.end) }
        // `AXRangeForPosition` answers with the nearest character even from a margin or a blank line, and just past a
        // word that character is the following space — so without a glyph check, blank space looks up the closest word.
        // Weigh it and its neighbours by their glyph boxes, under the tolerance every path shares.
        var best: (hit: WordAtPoint, offset: Int, distance: CGFloat)?
        for candidate in [index, index - 1, index + 1] where candidate >= start && candidate < end {
            guard let glyph = try ax.rect(
                    element, kAXBoundsForRangeParameterizedAttribute, value(CFRange(location: candidate, length: 1))),
                  let distance = tolerance.distance(from: point, to: glyph),
                  let hit = TextSegmenter.word(in: text, utf16Offset: candidate - start, clipped: clipped)
            else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (hit, candidate - start, distance) }
        }
        guard let best else { return nil }
        // **The token's own box: one more request, for the token's own range** — the glyph box above is one character's.
        var bounds: ReadBounds?
        if let token = TextSegmenter.wordRanges(in: text).first(where: { range in
            let lower = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.utf16.distance(from: text.startIndex, to: range.upperBound)
            return lower <= best.offset && best.offset < upper
        }), String(text[token]) == best.hit.word {
            // **The word is read; its box is worth having, not worth the word.** A failure here leaves the word with no
            // box; only the reader moving on still ends the read.
            do throws(CaptureError) {
                if let box = try ax.rect(element, kAXBoundsForRangeParameterizedAttribute, value(CFRange(
                    location: start + text.utf16.distance(from: text.startIndex, to: token.lowerBound),
                    length: text.utf16.distance(from: token.lowerBound, to: token.upperBound)))) {
                    bounds = ReadBounds.checked(box, quality: .exact, near: point, tolerance: tolerance)
                }
            } catch {
                if error == .cancelled { throw error }
            }
        }
        return (best.hit, bounds)
    }

    // MARK: - text markers

    /// The marker dialect: the word the pointer is over, then its sentence.
    private static func textMarkers(
        _ element: AXUIElement, at point: CGPoint, _ tolerance: HitTolerance, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> Located? {
        let host = try ax.webArea(containing: element) ?? element
        guard let marker = try ax.parameterized(host, "AXTextMarkerForPosition", value(point)),
              let best = try markedWord(at: point, marker: marker, in: host, tolerance, ax),
              let word = try context(of: best, at: point, marker: marker, in: host, ax)
        else { return nil }
        // WebKit's word, which holds the token — larger than the token where WebKit calls 看书 one word, so `containing`.
        return (word, ReadBounds.checked(best.box, quality: .containing, near: point, tolerance: tolerance))
    }

    /// A word under the pointer, as the markers give it: its text, its box, and how far the pointer is from that box.
    private typealias MarkedWord = (word: String, box: CGRect, distance: CGFloat)

    /// The nearer of the words either side of `marker`, or nil where neither is within the tolerance. A marker is a
    /// caret position, between characters: from the right half of a word's last letter it points past the word.
    private static func markedWord(
        at point: CGPoint, marker: CFTypeRef, in host: AXUIElement, _ tolerance: HitTolerance,
        _ ax: some AccessibilityReading
    ) throws(CaptureError) -> MarkedWord? {
        var best: MarkedWord?
        for attribute in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let wordRange = try ax.parameterized(host, attribute, marker),
                  let box = try ax.rect(host, "AXBoundsForTextMarkerRange", wordRange),
                  let distance = tolerance.distance(from: point, to: box),
                  let raw = try ax.string(host, "AXStringForTextMarkerRange", wordRange)
            else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !word.isEmpty else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (word, box, distance) }
        }
        return best
    }

    /// `best` in its sentence, segmented at the pointer — or the word alone, marked cut at both ends, where the sentence
    /// cannot be read or the word cannot be placed in it.
    private static func context(
        of best: MarkedWord, at point: CGPoint, marker: CFTypeRef, in host: AXUIElement, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> WordAtPoint? {
        guard let range = try ax.parameterized(host, "AXSentenceTextMarkerRangeForTextMarker", marker),
              let sentence = try ax.string(host, "AXStringForTextMarkerRange", range)
        else { return TextSegmenter.word(in: best.word, utf16Offset: 0, clipped: [.start, .end]) }
        // Whole words only: a plain substring search found "he" inside "there". A substring match is accepted only for
        // CJK, where the app's word breaks and the tokeniser's are expected to disagree.
        var wholeWord = wholeWordRange(of: best.word, in: sentence)
        if wholeWord == nil, LineJoiner.isCJKText(best.word) {
            let found = (sentence as NSString).range(of: best.word, options: [.literal])
            if found.location != NSNotFound { wholeWord = found }
        }
        guard let wholeWord else { return TextSegmenter.word(in: best.word, utf16Offset: 0, clipped: [.start, .end]) }
        // Re-segment at the pointer's position within WebKit's word, not at its first character.
        let within = CaptureGeometry.characterIndex(
            at: point.x, across: best.box.minX...best.box.maxX, count: best.word.utf16.count)
        return TextSegmenter.word(in: sentence, utf16Offset: wholeWord.location + within)
    }

    /// Where `word` appears in `sentence` as a whole word, by the same tokeniser — so "he" does not match inside
    /// "there". Still the first whole-word occurrence: a word twice in one sentence is a known limit.
    static func wholeWordRange(of word: String, in sentence: String) -> NSRange? {
        for range in TextSegmenter.wordRanges(in: sentence) where String(sentence[range]) == word {
            return NSRange(
                location: sentence.utf16.distance(from: sentence.startIndex, to: range.lowerBound),
                length: sentence.utf16.distance(from: range.lowerBound, to: range.upperBound))
        }
        return nil
    }

    // MARK: - bounds scan

    private static func boundsScan(
        _ element: AXUIElement, at point: CGPoint, _ tolerance: HitTolerance, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> Located? {
        guard let text = try ax.string(element, kAXValueAttribute), !text.isEmpty else { return nil }
        let words = TextSegmenter.wordRanges(in: text)
        guard words.count <= maximumScannedWords else { return nil }
        var best: (offset: Int, distance: CGFloat, box: CGRect, word: String)?
        for word in words {
            let location = text.utf16.distance(from: text.startIndex, to: word.lowerBound)
            let length = text.utf16.distance(from: word.lowerBound, to: word.upperBound)
            guard let box = try ax.rect(
                    element, kAXBoundsForRangeParameterizedAttribute, value(CFRange(location: location, length: length))),
                  !box.isEmpty,
                  let distance = tolerance.distance(from: point, to: box)
            else { continue }
            // Follow the pointer inside the word, so CJK re-segmentation lands on the right character.
            let within = CaptureGeometry.characterIndex(at: point.x, across: box.minX...box.maxX, count: length)
            if best.map({ distance < $0.distance }) ?? true {
                best = (location + within, distance, box, String(text[word]))
            }
        }
        guard let best, let found = TextSegmenter.word(in: text, utf16Offset: best.offset) else { return nil }
        // The scanned word's own box: exact where the delivered token is that word, containing where re-segmentation
        // took a part of it.
        let quality: WordBounds.Quality = found.word == best.word ? .exact : .containing
        return (found, ReadBounds.checked(best.box, quality: quality, near: point, tolerance: tolerance))
    }

    // MARK: - Waking an app's tree

    /// Chromium and Electron build their tree only when asked; whom we asked is remembered so the write happens once per
    /// process, **keyed by process and its launch** — a process ID is reused, and a new app under an old app's ID would
    /// otherwise never be woken. Remembered only after the request went through, so a transient failure is tried again.
    private static let awakened = Mutex<Set<String>>([])
    /// The launches asked for their whole tree, by the same key — see `escalate`.
    private static let escalated = Mutex<Set<String>>([])

    private static func launchKey(_ pid: pid_t) -> String {
        "\(pid)@\(NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0)"
    }

    private static func awaken(_ target: Target, _ ax: some AccessibilityReading) throws(CaptureError) {
        let pid = target.pid
        let key = launchKey(pid)
        guard !awakened.withLock({ $0.contains(key) }) else { return }
        try ax.wake(AXUIElementCreateApplication(pid))
        awakened.withLock { _ = $0.insert(key) }
    }

    /// `AXEnhancedUserInterface`, at most once per launch of an app. **It makes the app build its whole tree** — work,
    /// memory, and in some apps slower window moves for a window manager — which is why it waits for an app that answered
    /// nothing, rather than going out with `awaken`.
    private static func escalate(_ target: Target, _ ax: some AccessibilityReading) throws(CaptureError) {
        let pid = target.pid
        let key = launchKey(pid)
        guard !escalated.withLock({ $0.contains(key) }) else { return }
        try ax.enhance(AXUIElementCreateApplication(pid))
        escalated.withLock { _ = $0.insert(key) }
    }

    private static func value(_ point: CGPoint) -> AXValue {
        var point = point
        // Nil only when the type and the pointer disagree, and they are written together here.
        // swiftlint:disable:next force_unwrapping
        return AXValueCreate(.cgPoint, &point)!
    }

    private static func value(_ range: CFRange) -> AXValue {
        var range = range
        // Nil only when the type and the pointer disagree, and they are written together here.
        // swiftlint:disable:next force_unwrapping
        return AXValueCreate(.cfRange, &range)!
    }
}

// MARK: - Metadata-only descriptions (XDict ADR-0014 decision 9)

extension PointerWordReader.Hit: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The dialect, the app and whether a box came: never the word's sentence, which is the reader's text.
    public var description: String {
        "Hit(\(acquisition.rawValue), app: \(bundleID ?? "unknown"), box: \(bounds == nil ? "none" : "measured"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension PointerWordReader.Outcome: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .hit(let hit): "hit(\(hit))"
        case .miss(let miss): "miss(\(miss))"
        case .cancelled: "cancelled"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
