import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

// **The sentence around a selection** (owner, 2026-10-19: "sentence always captured" covers the shortcut, the menu and the
// Service). Moved by name from XiaolaiDict at 044dac6 where the code now exists again (`SelectionWindowTests`,
// `MarkerSentenceTests`, three of `CaptureTests`, four of `SelectionReaderTests`), and new for what XDict adds: the
// exclusions, the bounds, the cut to `CaptureLimits.contextUTF16`, and metadata-only descriptions.

/// A Cocoa text view holding `document`, with `selected` selected at `range` (UTF-16), answering its length and the
/// window a selection read asks for (`CaptureLimits.shipped.readRadiusUTF16` each side), as TextEdit does.
@discardableResult
func scriptDocument(_ tree: FakeAccessibility, _ number: Int32 = 1, document: String, selected: String, at range: NSRange,
                    answersLength: Bool = true, answersWindow: Bool = true) -> AXUIElement {
    let field = tree.element(number)
    let count = document.utf16.count
    let radius = CaptureLimits.shipped.readRadiusUTF16
    tree.set(tree.application, kAXFocusedUIElementAttribute, field)
    tree.set(field, kAXSelectedTextAttribute, selected as CFString)
    tree.set(field, kAXSelectedTextRangeAttribute, FakeAccessibility.rangeValue(range.location, range.length))
    // The selection's own range read back, as the box is found by it.
    tree.set(field, kAXStringForRangeParameterizedAttribute, argument: FakeAccessibility.rangeValue(range.location, range.length),
             selected as CFString)
    if answersLength { tree.set(field, kAXNumberOfCharactersAttribute, count as CFNumber) }
    if answersWindow {
        let start = max(0, range.location - radius)
        let end = answersLength ? min(count, range.location + range.length + radius) : range.location + range.length + radius
        let text = (document as NSString).substring(with: NSRange(location: start, length: min(end, count) - start))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: FakeAccessibility.rangeValue(start, end - start),
                 text as CFString)
    }
    return field
}

private let reader = FrontApp(pid: 1, name: "Reader", bundleID: "com.example.reader")

private func read(_ tree: FakeAccessibility, excluding exclusions: HoverPolicy = .shipped) -> SelectionOutcome {
    SelectionReader.read(application: tree.application, of: reader, with: tree, admitting: SelectionReaderTests.admission,
                         excluding: exclusions)
}

private func context(_ outcome: SelectionOutcome) -> ContextOutcome? {
    guard case .selected(let selected, _) = outcome else { return nil }
    return selected.context
}

/// The sentence and the term's range in it, read back as text: what the range holds.
private func placed(_ outcome: SelectionOutcome) -> (sentence: String, term: String, cut: CutEnds)? {
    guard case .available(let sentence, let range, let cut, _)? = context(outcome) else { return nil }
    return (sentence, (sentence as NSString).substring(with: range), cut)
}

// MARK: - Moved from XiaolaiDict's `Tests/MacCaptureTests/SelectionTests.swift`

struct SelectionWindowTests {
    @Test func aWindowAroundASelection() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: 5_000, radius: 400))
        #expect(window.location == 600)
        #expect(window.length == 805)
        #expect(window.selection == NSRange(location: 400, length: 5))
    }

    @Test func aWindowStopsAtTheDocumentsEdges() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 10, length: 5), documentLength: 100, radius: 400))
        #expect(window.location == 0)
        #expect(window.length == 100)
        #expect(window.clipping(returnedLength: 100) == [])
    }

    /// Ranges come from another process. Negative, overflowing or past-the-end ones are refused, never used in
    /// arithmetic that traps.
    @Test(arguments: [
        CFRange(location: -1, length: 5), CFRange(location: 5, length: -1), CFRange(location: .max, length: 1),
        CFRange(location: 1, length: .max), CFRange(location: 90, length: 20),
    ])
    func anImpossibleRangeIsRefused(range: CFRange) {
        #expect(SelectionWindow(selection: range, documentLength: 100, radius: 400) == nil)
    }

    /// **An answer longer than was asked for, near the end of an enormous document, is summed without trapping** (audit
    /// of 2026-10-10).
    @Test func anAnswerPastTheLargestIndexReachesTheEndWithoutTrapping() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: .max - 10, length: 0), documentLength: .max, radius: 400))
        #expect(window.clipping(returnedLength: 1_000) == [.start])
    }

    /// Without a reported length, a short answer cannot be told from a truncated one, so the end is never taken for the
    /// document's.
    @Test func anUnknownDocumentLengthStillMakesAWindow() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: nil, radius: 400))
        #expect(window.length == 805)
        #expect(window.clipping(returnedLength: 500) == [.start, .end])
        #expect(window.clipping(returnedLength: 805) == [.start, .end])
    }

    /// An app answering with less than was asked for, when the document is known to go on, is a cut sentence, not a
    /// complete one.
    @Test func aShortAnswerFromALongerDocumentIsCut() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 1_000, length: 5), documentLength: 5_000, radius: 400))
        #expect(window.clipping(returnedLength: 300) == [.start, .end])
        #expect(window.clipping(returnedLength: 805) == [.start, .end])
        let atEnd = try #require(SelectionWindow(selection: CFRange(location: 4_900, length: 5), documentLength: 5_000, radius: 400))
        #expect(atEnd.clipping(returnedLength: atEnd.length) == [.start])
    }

    /// The text read for the window must hold the selection where the range says, or the text, the range and the window
    /// describe different selections.
    @Test func theWindowMustHoldTheSelectedText() throws {
        let window = try #require(SelectionWindow(selection: CFRange(location: 4, length: 5), documentLength: 20, radius: 400))
        #expect(window.holds("quick", in: "The quick brown fox."))
        #expect(!window.holds("brown", in: "The quick brown fox."))
        #expect(!window.holds("quick", in: "The"))
    }
}

struct MarkerSentenceTests {
    @Test func theSelectionIsLocatedAtTheReportedOffset() throws {
        // "meeting" starts 16 units into the raw text; 14 into the trimmed sentence.
        let context = try #require(MarkerSentence.context(raw: "  We met at the meeting.  ", selected: "meeting", reportedOffset: 16))
        #expect(context.text == "We met at the meeting.")
        #expect(context.selection == NSRange(location: 14, length: 7))
        #expect(!context.mayBeCut)
    }

    /// Without a usable offset, a word that occurs once is placed; a repeated one is not guessed.
    @Test func withoutAnOffsetOnlyAUniqueOccurrenceIsPlaced() throws {
        let unique = try #require(MarkerSentence.context(raw: "A quick fox.", selected: "quick", reportedOffset: nil))
        #expect(unique.selection == NSRange(location: 2, length: 5))
        let repeated = try #require(MarkerSentence.context(raw: "The meeting ended after meeting.", selected: "meeting", reportedOffset: 99))
        #expect(repeated.selection == nil)
    }

    /// A sentence that does not contain the selection describes something else: the selection changed between the two
    /// reads.
    @Test func aSentenceWithoutTheSelectionIsDiscarded() {
        #expect(MarkerSentence.context(raw: "Another sentence entirely.", selected: "ephemeral", reportedOffset: 0) == nil)
    }
}

/// Three of XiaolaiDict's `CaptureTests`, read through the whole selection read (XDict has no separate `selection(from:)`
/// step; the context is a `ContextOutcome`, not a quality mark). `aPassageIsRefused` is not moved: XDict's
/// `SelectionReaderTests.nothingNoWordAndTooLongAreToldApart` holds it under the consumer's admission.
struct CaptureTests {
    @Test func aCompleteSentenceIsReportedAsComplete() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral", at: NSRange(location: 3, length: 9))
        let found = try #require(placed(read(tree)))
        #expect(found.sentence == "An ephemeral beauty.")
        #expect(found.term == "ephemeral")
        #expect(found.cut == [])
    }

    /// Every capture says what its context amounts to: cut by the window, or missing altogether.
    @Test func aDegradedContextSaysSo() throws {
        let radius = CaptureLimits.shipped.readRadiusUTF16
        let long = String(repeating: "word ", count: radius) + "long " + String(repeating: "word ", count: radius)
        let at = (long as NSString).range(of: "long")
        let tree = FakeAccessibility()
        scriptDocument(tree, document: long, selected: "long", at: at)
        let cut = try #require(placed(read(tree)))
        #expect(cut.term == "long")
        #expect(cut.cut == [.start, .end])

        let bare = FakeAccessibility()
        scriptDocument(bare, document: "A word.", selected: "word", at: NSRange(location: 2, length: 4), answersWindow: false)
        #expect(context(read(bare)) == .unavailable(.appExposedNone))
    }

    /// The term's range in the sentence accounts for punctuation trimmed off the selection.
    @Test func theRangeFollowsTheTrimmedTerm() throws {
        let tree = FakeAccessibility()
        let document = "He said “ephemeral,” twice."
        scriptDocument(tree, document: document, selected: "“ephemeral,”", at: (document as NSString).range(of: "“ephemeral,”"))
        let found = try #require(placed(read(tree)))
        #expect(found.sentence == document)
        #expect(found.term == "ephemeral")
    }
}

// MARK: - Moved from XiaolaiDict's `SelectionReaderTests`

extension SelectionReaderTests {
    /// **Cocoa text views: text, range and window agree, so the exact range is carried** — the second "meeting", not the
    /// first. Renamed from `theRangeDialectCarriesTheExactRangeAndItsWindowsDocument`: XDict reads no document or
    /// provenance (ADR-0014 d.10).
    @Test func theRangeDialectCarriesTheExactRange() throws {
        let tree = FakeAccessibility()
        let document = "Intro line.\nThe meeting ended after we stopped meeting at noon. After."
        let second = (document as NSString).range(of: "meeting", options: .backwards)
        scriptDocument(tree, document: document, selected: "meeting", at: second)
        guard case .available(let sentence, let range, _, _)? = context(read(tree)) else {
            Issue.record("no sentence"); return
        }
        #expect(sentence == "The meeting ended after we stopped meeting at noon.")
        #expect(range == (sentence as NSString).range(of: "meeting", options: .backwards))
    }

    /// Chrome answers both dialects: the range's text with no usable context, and the sentence only through markers. The
    /// markers' answer is used whole — never the range's text with the markers' sentence.
    @Test func aDialectWithContextIsUsedWholeNotMixed() throws {
        let tree = FakeAccessibility()
        let text = tree.element(1)
        let page = tree.element(2)
        tree.set(tree.application, kAXFocusedUIElementAttribute, text)
        tree.set(text, kAXSelectedTextAttribute, "word" as CFString)
        tree.set(text, kAXSelectedTextRangeAttribute, FakeAccessibility.rangeValue(5, 0))
        tree.set(text, kAXNumberOfCharactersAttribute, 0 as CFNumber)
        tree.set(text, kAXParentAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        let outcome = read(tree)
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.acquisition == .textMarkers)
        #expect(selected.context == .available(sentence: "A word here.", term: NSRange(location: 2, length: 4), cut: [], gap: nil))
    }

    /// A sentence that does not contain the selection describes something else — the selection moved between the reads.
    /// No context is better than a wrong one, and the capture says it has none.
    @Test func anIncoherentSentenceIsDroppedAndSaidToBeMissing() throws {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "Something else entirely.")
        guard case .selected(let selected, _) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selected.text == "word")
        #expect(selected.context == .unavailable(.appExposedNone))
    }

    /// **A selection is kept when reading its sentence fails** — the reader asked about the selection, and a spent budget
    /// while reading the context used to throw it away with it. Red if a context failure fails the whole read.
    @Test func aSelectionSurvivesAFailedContextRead() throws {
        let tree = FakeAccessibility()
        let field = scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral",
                                   at: NSRange(location: 3, length: 9))
        tree.fail(field, kAXNumberOfCharactersAttribute, with: .deadlineExceeded)
        guard case .selected(let selected, _) = read(tree) else {
            Issue.record("a failed context read lost the selection"); return
        }
        #expect(selected.text == "ephemeral")
        #expect(selected.context == .unavailable(.appExposedNone))
    }
}

// MARK: - New in XDict

/// **What XDict adds around the moved code** (plan-capture follow-ups, 2026-10-19): an excluded app or site reads
/// nothing around the selection, an unreadable site is refused once any site is excluded (fail-closed), the read is
/// bounded by `CaptureLimits`, a long sentence is cut to `contextUTF16` around the term, a cancellation still cancels,
/// and no description of an outcome holds a word of the sentence.
struct SelectionContextReadTests {
    /// The requests a context read makes, beyond the selection's own: none of these may be asked where it is refused.
    static let contextRequests = [kAXNumberOfCharactersAttribute, kAXValueAttribute, "AXSentenceTextMarkerRangeForTextMarker",
                                  kAXStringForRangeParameterizedAttribute + " range 0"]

    private func excludingApp() -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("com.example.reader")
        return policy
    }

    private func excludingSite(_ host: String) -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.excludedHosts = [host]
        return policy
    }

    /// A web page holding a selection, its address `url` (none for an unreadable one), under the application.
    private func page(_ tree: FakeAccessibility, url: String?) {
        let page = tree.element(1)
        tree.set(tree.application, kAXRoleAttribute, kAXApplicationRole as CFString)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.set(page, kAXParentAttribute, tree.application)
        if let url, let address = URL(string: url) { tree.set(page, kAXURLAttribute, address as CFURL) }
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
    }

    /// **An excluded app reads nothing around the selection**: the term is still looked up — the reader asked — and the
    /// context says why it is missing. Red while the selection path ignores the exclusions.
    @Test func anExcludedAppReadsNothingAroundTheSelection() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral", at: NSRange(location: 3, length: 9))
        let outcome = read(tree, excluding: excludingApp())
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral")
        #expect(selected.context == .unavailable(.excluded))
        #expect(!tree.asked.contains { asked in Self.contextRequests.contains { asked.hasPrefix($0) } }, "\(tree.asked)")
        // The control: the same document in an app not excluded is read.
        #expect(placed(read(tree))?.sentence == "An ephemeral beauty.")
    }

    /// **An excluded site reads nothing around the selection**, a subdomain of it too; another site's page is read.
    @Test func anExcludedSiteReadsNothingAroundTheSelection() throws {
        for url in ["https://example.com/a", "https://docs.example.com/b"] {
            let tree = FakeAccessibility()
            page(tree, url: url)
            #expect(context(read(tree, excluding: excludingSite("example.com"))) == .unavailable(.excluded), "\(url)")
            #expect(!tree.asked.contains("AXSentenceTextMarkerRangeForTextMarker"), "\(url): \(tree.asked)")
        }
        let other = FakeAccessibility()
        page(other, url: "https://example.org/a")
        #expect(placed(read(other, excluding: excludingSite("example.com")))?.sentence == "A word here.")
    }

    /// **Fail-closed**: a page whose address cannot be read is refused once any site is excluded, and read when none is.
    @Test func anUnreadableSiteIsRefusedOnceAnySiteIsExcluded() throws {
        let tree = FakeAccessibility()
        page(tree, url: nil)
        #expect(context(read(tree, excluding: excludingSite("example.com"))) == .unavailable(.excluded))
        #expect(placed(read(tree))?.sentence == "A word here.", "with no site excluded, nothing is refused")
    }

    /// **The read is bounded**: in a long document only the window around the selection is asked for, never the whole
    /// value, and the sentence handed over is never longer than `contextUTF16`.
    @Test func aLongDocumentIsReadOnlyAroundTheSelection() throws {
        let limits = CaptureLimits.shipped
        let filler = String(repeating: "Words fill the page. ", count: limits.readRadiusUTF16 / 4)
        let document = filler + "The rare word sits here. " + filler
        let at = (document as NSString).range(of: "rare")
        let tree = FakeAccessibility()
        scriptDocument(tree, document: document, selected: "rare", at: at)
        tree.set(tree.element(1), kAXValueAttribute, document as CFString)
        let found = try #require(placed(read(tree)))
        #expect(found.sentence == "The rare word sits here.")
        #expect(!tree.asked.contains(kAXValueAttribute), "the whole document was read")
        let window = "\(kAXStringForRangeParameterizedAttribute) range \(at.location - limits.readRadiusUTF16) "
            + "\(at.length + 2 * limits.readRadiusUTF16)"
        let selection = "\(kAXStringForRangeParameterizedAttribute) range \(at.location) \(at.length)"
        let reads = Set(tree.asked.filter { $0.hasPrefix(kAXStringForRangeParameterizedAttribute) })
        #expect(reads == [window, selection], "\(reads)")
    }

    /// **A view that answers only with its whole value is read through it only when the value is no longer than the
    /// window** — its reported length says so — and not at all when it is longer or unknown.
    @Test func aWholeValueIsReadOnlyWhenItFitsTheWindow() throws {
        let short = FakeAccessibility()
        let field = scriptDocument(short, document: "An ephemeral beauty.", selected: "ephemeral",
                                   at: NSRange(location: 3, length: 9), answersWindow: false)
        short.set(field, kAXValueAttribute, "An ephemeral beauty." as CFString)
        #expect(placed(read(short))?.sentence == "An ephemeral beauty.")

        let filler = String(repeating: "x", count: CaptureLimits.shipped.readRadiusUTF16 * 3)
        let document = "An ephemeral beauty. " + filler
        let long = FakeAccessibility()
        let view = scriptDocument(long, document: document, selected: "ephemeral", at: NSRange(location: 3, length: 9),
                                  answersWindow: false)
        long.set(view, kAXValueAttribute, document as CFString)
        #expect(context(read(long)) == .unavailable(.appExposedNone))
        #expect(!long.asked.contains(kAXValueAttribute), "a value longer than the window was read")
    }

    /// **A sentence longer than `contextUTF16` is cut around the term, on whole characters, and says which ends were
    /// cut** — never refused whole by the captured term's ceiling, which would lose the term with it.
    @Test func aSentenceLongerThanTheLimitIsCutAroundTheTerm() throws {
        let limits = CaptureLimits.shipped
        let half = String(repeating: "word ", count: limits.contextUTF16 / 4)
        let document = half + "rare " + half + "end."
        let at = (document as NSString).range(of: "rare")
        let tree = FakeAccessibility()
        scriptDocument(tree, document: document, selected: "rare", at: at)
        let found = try #require(placed(read(tree)))
        #expect(found.term == "rare")
        #expect(found.sentence.utf16.count <= limits.contextUTF16)
        #expect(found.cut == [.start, .end])
        let term = try #require(try read(tree).capturedTerm(trigger: .selection))
        #expect(term.term == "rare")
    }

    /// **XDict's own native controls are read around the selection like any app's** (owner, 2026-10-20: the shortcut,
    /// the menu and the Service capture the sentence in XDict's own windows too; ADR-0014 d.6). Red while the own process
    /// is refused outright (it had been, since the verifier's round of 2026-10-19).
    @Test func ourOwnControlsAreReadAroundTheSelection() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral", at: NSRange(location: 3, length: 9))
        let ours = FrontApp(pid: getpid(), name: "XDict", bundleID: "ai.xdict.app")
        let outcome = SelectionReader.read(application: tree.application, of: ours, with: tree,
                                           admitting: SelectionReaderTests.admission, excluding: .shipped)
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral")
        #expect(placed(outcome)?.sentence == "An ephemeral beauty.")
    }

    /// **XDict listed under Never look up in reads nothing around its own selection**, as any app listed there: the term
    /// is looked up, nothing around it is asked. The control for the test above.
    @Test func anExcludedXDictReadsNothingAroundItsOwnSelection() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral", at: NSRange(location: 3, length: 9))
        let ours = FrontApp(pid: getpid(), name: "XDict", bundleID: "ai.xdict.app")
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("ai.xdict.app")
        let outcome = SelectionReader.read(application: tree.application, of: ours, with: tree,
                                           admitting: SelectionReaderTests.admission, excluding: policy)
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral")
        #expect(selected.context == .unavailable(.excluded))
        #expect(!tree.asked.contains { asked in Self.contextRequests.contains { asked.hasPrefix($0) } }, "\(tree.asked)")
    }

    /// **An answer far longer than was asked for is refused before it is searched** (verifier, 2026-10-19): a hostile or
    /// broken app answering 50 MB for a window, or for a sentence, costs no segmentation of it. Red while the whole answer
    /// is handed to the segmenter.
    @Test func anAnswerFarLongerThanAskedIsRefusedUnsearched() throws {
        // About 50 MB each, holding the selection where it was asked for, so only the length can refuse it.
        let filler = String(repeating: "x", count: 50_000_000)
        let range = FakeAccessibility()
        let field = scriptDocument(range, document: "An ephemeral beauty.", selected: "ephemeral",
                                   at: NSRange(location: 3, length: 9))
        range.set(field, kAXStringForRangeParameterizedAttribute, argument: FakeAccessibility.rangeValue(0, 20),
                  ("An ephemeral beauty. " + filler) as CFString)
        let markers = FakeAccessibility()
        page(markers, url: nil)
        markers.scriptSentence(on: markers.element(1), ("A " + filler + " word here.") as CFString)
        let clock = ContinuousClock()
        for tree in [range, markers] {
            var outcome: SelectionOutcome?
            let spent = clock.measure { outcome = read(tree) }
            #expect(outcome.flatMap(context) == .unavailable(.appExposedNone))
            #expect(spent < .seconds(1), "\(spent): the answer was searched")
        }
    }

    /// **The marker sentence's ceiling is inclusive** (verifier round 2, B3): a sentence WebKit names of exactly
    /// `contextUTF16 * markerSentenceCeilingFactor` UTF-16 units is read, and cut around the term; one unit more is
    /// refused. Red if the bound is `<` rather than `<=`.
    @Test func theMarkerSentenceCeilingHoldsItsOwnLength() throws {
        let ceiling = CaptureLimits.shipped.contextUTF16 * SelectionReader.markerSentenceCeilingFactor
        var words = "A word"
        while (words as NSString).length < ceiling { words += " more" }
        let atCeiling = String(words.utf16.prefix(ceiling - 1)).map { $0 + "." }
        let exact = try #require(atCeiling)
        let over = try #require(String(words.utf16.prefix(ceiling - 1)).map { $0 + "s." })
        #expect((exact as NSString).length == ceiling && (over as NSString).length == ceiling + 1)

        let held = FakeAccessibility()
        page(held, url: nil)
        held.scriptSentence(on: held.element(1), exact as CFString)
        let found = try #require(placed(read(held)), "a sentence of exactly the ceiling was refused")
        #expect(found.term == "word")

        let refused = FakeAccessibility()
        page(refused, url: nil)
        refused.scriptSentence(on: refused.element(1), over as CFString)
        #expect(context(read(refused)) == .unavailable(.appExposedNone))
    }

    /// **The reader moving on still ends the read**, while the context is read.
    @Test func aCancellationWhileTheContextIsReadCancels() {
        let tree = FakeAccessibility()
        let field = scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral",
                                   at: NSRange(location: 3, length: 9))
        tree.fail(field, kAXNumberOfCharactersAttribute, with: .cancelled)
        guard case .nothing(.failed(.cancelled, _)) = read(tree) else { Issue.record("a cancellation was swallowed"); return }
    }

    /// **The menu and the shortcut hand the sentence over in the term; the Service only where its text agrees.**
    @Test func theSentenceTravelsInTheTermOfEveryTrigger() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "An ephemeral beauty.", selected: "ephemeral", at: NSRange(location: 3, length: 9))
        let outcome = read(tree)
        let expected = ContextOutcome.available(sentence: "An ephemeral beauty.", term: NSRange(location: 3, length: 9),
                                                cut: [], gap: nil)
        for trigger: CaptureTrigger in [.selection, .menu] {
            #expect(try outcome.capturedTerm(trigger: trigger)?.context == expected, "\(trigger)")
        }
        let source = SourceApp(bundleID: "com.example.reader")
        #expect(try SelectionReader.serviceTerm("ephemeral", read: outcome, source: source, clicked: nil).context == expected)
        #expect(try SelectionReader.serviceTerm("beauty", read: outcome, source: source, clicked: nil).context
                == .unavailable(.disagreesWithServiceText))
    }

    /// **No description of a selection holds a word of its sentence** (ADR-0014 decision 9): the outcome is stringified
    /// into the instruments' events (`serviceSelection`), so its descriptions, its mirror and `dump` say what kind of
    /// context it has and never its text. The term itself is what goes to search, and may appear.
    @Test func noDescriptionOfASelectionHoldsItsSentence() throws {
        let tree = FakeAccessibility()
        scriptDocument(tree, document: "Secretive marmalade ephemeral quixotic.", selected: "ephemeral",
                       at: NSRange(location: 20, length: 9))
        let outcome = read(tree)
        #expect(placed(outcome) != nil, "no sentence was read: this test would hold nothing")
        var dumped = ""
        dump(outcome, to: &dumped)
        let term = try #require(try outcome.capturedTerm(trigger: .selection))
        var dumpedTerm = ""
        dump(term, to: &dumpedTerm)
        for text in [String(describing: outcome), String(reflecting: outcome), dumped, String(describing: term), dumpedTerm] {
            for word in ["Secretive", "marmalade", "quixotic"] {
                #expect(!text.contains(word), "\(word) in \(text)")
            }
        }
    }
}
