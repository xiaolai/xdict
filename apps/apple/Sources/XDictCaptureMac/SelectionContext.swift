import ApplicationServices
import XDictCapture

extension SelectionReader {
    /// **The sentence around a selection already read** (owner, 2026-10-19: the sentence is always captured, the
    /// shortcut, the menu and the Service too), in the read's own lane job and budget, as an outcome:
    ///
    /// - **an excluded app or site reads nothing** — the app by its bundle identifier before any request; the site by
    ///   the hover path's fail-closed walk (`PointerWordReader.host`), asked only when a site is excluded, so a page whose
    ///   address cannot be read is refused whenever any exclusion exists (`HoverPolicy.refuses`);
    /// - **bounded**: the text-range dialect asks for a window of `CaptureLimits.readRadiusUTF16` each side, and reads a
    ///   view's whole value only when its reported length fits that window; WebKit is asked for the sentence's markers;
    ///   the sentence is then cut to `contextUTF16` around the term, on whole characters, its cut ends said;
    /// - **checked**: text, range and sentence are separate reads, and one that no longer holds the selection gives no
    ///   context, never a wrong one;
    /// - **worth having, not worth the selection**: a failure gives `.appExposedNone`; only the reader moving on (a
    ///   cancellation) ends the read.
    static func contextOutcome(
        of capture: Capture, term: SelectedTerm, app: FrontApp, exclusions: HoverPolicy, limits: CaptureLimits,
        _ ax: some AccessibilityReading
    ) throws(CaptureError) -> ContextOutcome {
        // XDict's own windows are never read around a selection (verifier's round, 2026-10-19). Hover has read them since
        // the owner's ruling of 2026-10-19; whether the selection's sentence follows is not decided here.
        if app.pid == getpid() { return .unavailable(.excluded) }
        if let bundleID = app.bundleID, exclusions.excludes(app: bundleID) { return .unavailable(.excluded) }
        // With no site excluded nothing can be refused, so the walk is not paid for.
        if !exclusions.excludedHosts.isEmpty {
            let target = PointerWordReader.Target(element: capture.host, appName: app.name, bundleID: app.bundleID)
            let site = PointerWordReader.host(of: target, isExcluded: { exclusions.refuses(.known($0)) }, with: ax)
            if exclusions.refuses(site) { return .unavailable(.excluded) }
        }
        let sentence: SentenceContext?
        do throws(CaptureError) {
            if let markers = capture.markers {
                sentence = try sentenceCovering(markers, selected: capture.text, in: capture.host,
                                                ceiling: limits.contextUTF16 * markerSentenceCeilingFactor, ax)
            } else if let range = capture.range {
                sentence = try sentenceAround(range, selected: capture.text, in: capture.host, radius: limits.readRadiusUTF16, ax)
            } else {
                sentence = nil
            }
        } catch {
            if error == .cancelled { throw error }
            return .unavailable(.appExposedNone)
        }
        guard let sentence, let selection = sentence.selection,
              let (text, range, cut) = cutToLimit(sentence, term: term, at: selection, limits: limits)
        else { return .unavailable(.appExposedNone) }
        return .available(sentence: text, term: range, cut: cut, gap: nil)
    }

    /// The sentence from a window of text around the selection. Nil unless the window holds the selected text exactly
    /// where the range says. **A view's whole value is read only when its reported length fits the window**: a value
    /// of unknown or greater length may be megabytes over IPC for one sentence.
    private static func sentenceAround(
        _ range: CFRange, selected: String, in host: AXUIElement, radius: Int, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> SentenceContext? {
        let count = try ax.integer(host, kAXNumberOfCharactersAttribute)
        guard let window = SelectionWindow(selection: range, documentLength: count, radius: radius) else { return nil }
        if let request = AccessibilitySession.rangeValue(window.cfRange),
           let text = try ax.string(host, kAXStringForRangeParameterizedAttribute, request) {
            // **An answer longer than was asked for is refused before it is searched** — its length read without
            // walking it (`NSString.length`), so a 50 MB answer costs no segmentation (verifier, 2026-10-19).
            guard (text as NSString).length <= window.length, window.holds(selected, in: text) else { return nil }
            return TextSegmenter.sentence(in: text, around: window.selection,
                                          clipped: window.clipping(returnedLength: text.utf16.count))
        }
        guard let count, window.location == 0, count <= window.length,
              let whole = try ax.string(host, kAXValueAttribute), whole.utf16.count == count,
              let all = SelectionWindow(selection: range, documentLength: count, radius: radius),
              all.holds(selected, in: whole)
        else { return nil }
        return TextSegmenter.sentence(in: whole, around: all.selection)
    }

    /// The sentences covering the whole selection, through WebKit's markers: from the one holding its first character to
    /// the one holding its last. The end marker sits after the last character, and at a sentence boundary it belongs to
    /// the next sentence — so the marker before it is asked for (moved from XiaolaiDict's `sentenceCovering`).
    /// How many times `contextUTF16` a sentence WebKit names may be before it is refused unsearched: a sentence is not
    /// asked for by length, so its answer is bounded here, before any search of it.
    static let markerSentenceCeilingFactor = 8

    private static func sentenceCovering(
        _ selection: AXTextMarkerRange, selected: String, in host: AXUIElement, ceiling: Int, _ ax: some AccessibilityReading
    ) throws(CaptureError) -> SentenceContext? {
        let start = AXTextMarkerRangeCopyStartMarker(selection)
        let end = AXTextMarkerRangeCopyEndMarker(selection)
        let last = try ax.marker(host, "AXPreviousTextMarkerForTextMarker", end) ?? end
        guard let first = try ax.markerRange(host, "AXSentenceTextMarkerRangeForTextMarker", start),
              let final = try ax.markerRange(host, "AXSentenceTextMarkerRangeForTextMarker", last)
        else { return nil }
        let sentenceStart = AXTextMarkerRangeCopyStartMarker(first)
        let covering = AXTextMarkerRangeCreate(nil, sentenceStart, AXTextMarkerRangeCopyEndMarker(final))
        guard let raw = try ax.string(host, "AXStringForTextMarkerRange", covering), (raw as NSString).length <= ceiling
        else { return nil }
        // Where the selection starts in the sentence, from the markers' indices when the app gives them; checked against
        // the text either way. Indices from another process: both non-negative, so the difference cannot overflow.
        var offset: Int?
        if let selectionIndex = try ax.integer(host, "AXIndexForTextMarker", start),
           let sentenceIndex = try ax.integer(host, "AXIndexForTextMarker", sentenceStart),
           selectionIndex >= 0, sentenceIndex >= 0 {
            offset = selectionIndex - sentenceIndex
        }
        return MarkerSentence.context(raw: raw, selected: selected, reportedOffset: offset)
    }

    /// The sentence with the **term's** range (the selection less its trimmed punctuation), cut to `contextUTF16` around
    /// it on whole characters, and which ends are cuts — the sentence's own, and the limit's. Nil where the term is not
    /// where the selection says.
    private static func cutToLimit(
        _ sentence: SentenceContext, term: SelectedTerm, at selection: NSRange, limits: CaptureLimits
    ) -> (String, NSRange, CutEnds)? {
        let (location, overflowed) = selection.location.addingReportingOverflow(term.range.location)
        guard !overflowed else { return nil }
        let termRange = NSRange(location: location, length: term.range.length)
        guard let (text, range) = limits.window(of: sentence.text, around: termRange) else { return nil }
        let start = termRange.location - range.location
        var cut: CutEnds = []
        if sentence.cut.contains(.start) || start > 0 { cut.insert(.start) }
        if sentence.cut.contains(.end) || start + text.utf16.count < sentence.text.utf16.count { cut.insert(.end) }
        return (text, range, cut)
    }
}

/// **The stretch of a document read to find a selection's sentence**: a window, not the whole document — a long document
/// is megabytes over IPC for one sentence (moved from XiaolaiDict's `SelectionText.swift`, plan-capture follow-ups,
/// 2026-10-19, with `SelectionWindowTests` by name; the radius is `CaptureLimits.readRadiusUTF16`, handed in).
struct SelectionWindow: Equatable {
    /// The window, in the document's UTF-16 units.
    let location: Int
    let length: Int
    /// The selection, relative to the window.
    let selection: NSRange
    /// The document's reported length, when the app reports one.
    private let documentLength: Int?

    /// `selection` and `documentLength` come from another process and are validated, not trusted: nil for a negative
    /// range, one whose end overflows, or one past the reported length.
    init?(selection: CFRange, documentLength: Int?, radius: Int) {
        guard selection.location >= 0, selection.length >= 0, radius >= 0 else { return nil }
        let (selectionEnd, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow else { return nil }
        if let documentLength { guard documentLength >= 0, selectionEnd <= documentLength else { return nil } }
        let start = selection.location - min(selection.location, radius)
        let (wanted, beyond) = selectionEnd.addingReportingOverflow(radius)
        let end = min(beyond ? Int.max : wanted, documentLength ?? Int.max)
        location = start
        length = end - start
        self.selection = NSRange(location: selection.location - start, length: selection.length)
        self.documentLength = documentLength
    }

    var cfRange: CFRange { CFRange(location: location, length: length) }

    /// Which ends of the text read are cuts in the document. The end is the document's own only when the text read
    /// reaches the reported length: a short answer is not taken for the end — with a length reported it is a truncation,
    /// and without one it cannot be told from one.
    func clipping(returnedLength: Int) -> TextSegmenter.Clipping {
        var clipped: TextSegmenter.Clipping = []
        if location > 0 { clipped.insert(.start) }
        // Summed with a check: an answer longer than asked for, near `Int.max`, trapped (audit of 2026-10-10). Past the
        // largest index is past the document's end too.
        let reachesEnd = documentLength.map { length in
            let (end, overflowed) = location.addingReportingOverflow(returnedLength)
            return overflowed || end >= length
        } ?? false
        if !reachesEnd { clipped.insert(.end) }
        return clipped
    }

    /// Whether `text`, read for this window, holds `selected` exactly where the selection range says. Text, range and
    /// window are separate reads; if the selection changed between them, or the app's ranges disagree with its text,
    /// this is where it shows.
    func holds(_ selected: String, in text: String) -> Bool {
        let units = text.utf16
        guard selection.location <= units.count, selection.length <= units.count - selection.location,
              let range = Range(selection, in: text)
        else { return false }
        return text[range] == selected
    }
}

/// **The marker dialect's sentence, checked against the selection it is meant to contain** (moved from XiaolaiDict's
/// `SelectionReader.swift`, with `MarkerSentenceTests` by name).
enum MarkerSentence {
    /// Trimmed, with the selection located in it: at `reportedOffset` (UTF-16, in `raw`) if the text there is the
    /// selection, else at its one occurrence. Nil when the sentence does not contain the selection at all — they were
    /// separate reads, and the selection may have moved between.
    static func context(raw: String, selected: String, reportedOffset: Int?) -> SentenceContext? {
        guard let first = raw.firstIndex(where: { !$0.isWhitespace }),
              let last = raw.lastIndex(where: { !$0.isWhitespace })
        else { return nil }
        let text = String(raw[first...last])
        let leading = raw.utf16.distance(from: raw.startIndex, to: first)

        let source = raw as NSString
        let length = (selected as NSString).length
        func holds(_ offset: Int) -> Bool {
            offset >= 0 && offset <= source.length - length
                && source.substring(with: NSRange(location: offset, length: length)) == selected
        }
        var offset = reportedOffset.flatMap { holds($0) ? $0 : nil }
        if offset == nil {
            var occurrences: [Int] = []
            var searched = NSRange(location: 0, length: source.length)
            while occurrences.count < 2 {
                let found = source.range(of: selected, options: .literal, range: searched)
                guard found.location != NSNotFound else { break }
                occurrences.append(found.location)
                searched = NSRange(location: found.location + 1, length: source.length - found.location - 1)
            }
            guard !occurrences.isEmpty else { return nil }
            // A repeated selection is not placed: which occurrence was selected is not guessed.
            if occurrences.count == 1 { offset = occurrences[0] }
        }
        let selection = offset.map { NSRange(location: $0 - leading, length: length) }
            .flatMap { $0.location >= 0 && $0.length <= text.utf16.count - $0.location ? $0 : nil }
        return SentenceContext(text: text, mayBeCut: false, selection: selection)
    }
}
