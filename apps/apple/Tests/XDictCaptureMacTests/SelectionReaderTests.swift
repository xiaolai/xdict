import ApplicationServices
import Foundation
import Testing
import XDictCaptureMac

/// **The selection, read as VoiceOver reads it** (plan-macos-v1 WI-8, I2): which element, which dialect, the term less
/// its punctuation, and where it is on screen — against a scripted Accessibility tree. Moved from XiaolaiDict
/// (`SelectionReaderTests`) with the reader, re-checked against the MDX-first model (ADR-0001): XDict looks the term up
/// and puts the panel by it, and keeps no sentence and no provenance, so the tests of those stayed behind. The real apps
/// are the E2E `selection.hosts` sub-stage's. Moved again, by name, from `XDictAnywhereTests` with the reader (plan-capture
/// WI-2): the admission limit is the consumer's (XDict ADR-0014 decision 3), so these hand in lookup's 200.
struct SelectionReaderTests {
    private let app = FrontApp(pid: 1, name: "Reader", bundleID: "com.example.reader")
    /// What lookup admits today (`LookupText.maximumLength`): handed in, never capture's own.
    static let admission = TermAdmission(maximumCharacters: 200)

    private func read(_ tree: FakeAccessibility) -> SelectionOutcome {
        SelectionReader.read(application: tree.application, of: app, with: tree, admitting: Self.admission)
    }

    /// A Cocoa text view: the selected text, its range and its box.
    @Test func theRangeDialectReadsTheSelectedText() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "take off" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(4, 8))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(4, 8), "take off" as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(4, 8),
                 rectValue(CGRect(x: 10, y: 20, width: 60, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "take off")
        #expect(selection.app == app)
        #expect(bounds == SelectionBox(rect: CGRect(x: 10, y: 20, width: 60, height: 16), quality: .exact))
    }

    /// **Chrome answers both dialects**, its text range disagreeing with its own text (an empty range for "word"): the
    /// markers' answer is used, whole, and boxed by them.
    @Test func aRangeThatDisagreesWithItsTextGivesWayToTheMarkers() {
        let tree = FakeAccessibility()
        let text = tree.element(1)
        let page = tree.element(2)
        tree.set(tree.application, kAXFocusedUIElementAttribute, text)
        tree.set(text, kAXSelectedTextAttribute, "word" as CFString)
        tree.set(text, kAXSelectedTextRangeAttribute, rangeValue(5, 0))
        tree.set(text, kAXParentAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "word")
        #expect(bounds == SelectionBox(rect: CGRect(x: 80, y: 140, width: 40, height: 18), quality: .exact))
    }

    /// Safari with the keyboard in its address bar: nothing in the focused element, so the window's page is searched.
    @Test func thePageIsSearchedWhenTheFocusedElementHasNothing() {
        let tree = FakeAccessibility()
        let bar = tree.element(1), window = tree.element(2), group = tree.element(3), page = tree.element(4)
        tree.set(tree.application, kAXFocusedUIElementAttribute, bar)
        tree.set(tree.application, kAXFocusedWindowAttribute, window)
        tree.set(window, kAXChildrenAttribute, [group] as CFArray)
        tree.set(group, kAXChildrenAttribute, [page] as CFArray)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "abbé", sentence: "An abbé.")
        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "abbé")
    }

    /// Nothing selected, only punctuation, or more than a lookup takes: each its own answer, never a silent nothing.
    @Test func nothingNoWordAndTooLongAreToldApart() {
        let empty = FakeAccessibility()
        #expect(read(empty) == .nothing(.nothingSelected(app: "Reader")))
        let long = String(repeating: "word ", count: 60)
        for (selected, refusal) in [("“…”", SelectionRefusal.noWord(app: "Reader")),
                                    (long, .tooLong(app: "Reader", characters: 299))] {
            let tree = FakeAccessibility()
            let field = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, field)
            tree.set(field, kAXSelectedTextAttribute, selected as CFString)
            #expect(read(tree) == .nothing(refusal), "\(selected.prefix(10))")
        }
    }

    /// The panel's query is the selection exactly, Unicode and phrases included — trimmed of nothing but its wrapping
    /// punctuation and whitespace.
    @Test func aUnicodePhraseIsReadExactly() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, " crème brûlée 煎饼\n" as CFString)
        guard case .selected(let selection, _) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "crème brûlée 煎饼")
    }

    @Test func anExhaustedPageSearchSaysSo() {
        let tree = FakeAccessibility()
        let window = tree.element(1)
        tree.set(tree.application, kAXFocusedWindowAttribute, window)
        var parent = window
        for index in 2...(SelectionReader.webAreaSearchLimit + 10) {
            let child = tree.element(Int32(index))
            tree.set(parent, kAXChildrenAttribute, [child] as CFArray)
            parent = child
        }
        guard case .nothing(let reason) = read(tree) else { Issue.record("expected nothing"); return }
        #expect(reason == .searchLimitReached(app: "Reader", limit: SelectionReader.webAreaSearchLimit))
    }

    /// **The Service's read: the element under the reader's Control-click** (E2E `services.notes`, 2026-10-18). Once the
    /// Services menu had closed, Notes answered with no focused selection and a window too large to search for a page,
    /// and TextEdit with no focused selection at all, though the text view under the click still held the selection:
    /// the panel fell back to a 16 pt box at the pointer and sat 3 pt over Notes' 23 pt line. That element, or one of
    /// its parents, is read after the focused element and before the page search, its box exact.
    @Test func theElementUnderTheClickIsReadWhenTheFocusHasNothing() {
        let tree = FakeAccessibility()
        let window = tree.element(1), view = tree.element(2), paragraph = tree.element(3)
        tree.set(tree.application, kAXFocusedWindowAttribute, window)
        var parent = window
        for index in 10...(SelectionReader.webAreaSearchLimit + 20) {
            let child = tree.element(Int32(index))
            tree.set(parent, kAXChildrenAttribute, [child] as CFArray)
            parent = child
        }
        tree.set(paragraph, kAXParentAttribute, view)
        tree.set(view, kAXSelectedTextAttribute, "crème brûlée 煎饼" as CFString)
        tree.set(view, kAXSelectedTextRangeAttribute, rangeValue(40, 15))
        tree.set(view, kAXStringForRangeParameterizedAttribute, argument: rangeValue(40, 15), "crème brûlée 煎饼" as CFString)
        tree.set(view, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(40, 15),
                 rectValue(CGRect(x: 429, y: 140, width: 166, height: 23)))
        #expect(read(tree) == .nothing(.searchLimitReached(app: "Reader", limit: SelectionReader.webAreaSearchLimit)),
                "without the click, as in the E2E run")
        let outcome = SelectionReader.read(application: tree.application, of: app, with: tree, under: paragraph,
                                           admitting: Self.admission)
        guard case .selected(let selection, let bounds) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selection.text == "crème brûlée 煎饼")
        #expect(bounds == SelectionBox(rect: CGRect(x: 429, y: 140, width: 166, height: 23), quality: .exact))
    }

    @Test func aLockedScreenIsNotNothingSelected() {
        let tree = FakeAccessibility()
        tree.fail(tree.application, kAXFocusedUIElementAttribute, with: .accessibilityRefused)
        guard case .nothing(let reason) = read(tree) else { Issue.record("expected nothing"); return }
        #expect(reason == .failed(.accessibilityRefused, app: "Reader"))
    }

    /// **A selection is kept when reading its range fails** — the reader asked about the selection, and a spent budget
    /// while reading around it threw it away with it in XiaolaiDict. It stands, with no box.
    @Test func aSelectionSurvivesAFailedRangeRead() throws {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
        tree.fail(field, kAXSelectedTextRangeAttribute, with: .deadlineExceeded)
        guard case .selected(let selection, _) = read(tree) else {
            Issue.record("a failed range read lost the selection")
            return
        }
        #expect(selection.text == "ephemeral")
    }

    // MARK: - Where the selection is (the owner's decision of 2026-10-09: the card anchored on the word)

    /// **The text-range dialect is asked for the term's own range** — the selection less the punctuation it was trimmed
    /// of — so the box is the word's, exact.
    @Test func theRangeDialectBoxesTheTermsOwnRange() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "“meeting,”" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 10))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(20, 10), "“meeting,”" as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(21, 7),
                 rectValue(CGRect(x: 300, y: 90, width: 56, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "meeting")
        #expect(bounds == SelectionBox(rect: CGRect(x: 300, y: 90, width: 56, height: 16), quality: .exact))
    }

    /// A selected range that no longer spans the text read is a selection that moved between the reads: no box, and the
    /// selection itself is kept.
    @Test func aRangeThatNoLongerSpansTheTextLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "meeting" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 9))
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(20, 7),
                 rectValue(CGRect(x: 300, y: 90, width: 56, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "meeting")
        #expect(bounds == nil)
    }

    /// **The box is the captured text's, or there is none** (audit of 2026-10-10). A selected range of the same length is
    /// not the same text: *cat* captured, then *dog* at that range when the box is asked — an edit between the two reads —
    /// was boxed as *cat*. The captured range is kept and its text read back before its box is believed.
    @Test func aRangeWhoseTextChangedBetweenTheReadsLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(20, 3))
        tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(20, 3), "dog" as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(20, 3),
                 rectValue(CGRect(x: 300, y: 90, width: 30, height: 16)))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "cat")
        #expect(bounds == nil, "dog's box was given for cat")
    }

    /// **A view that answers only with its whole value is read back through that**, so it keeps its box.
    @Test func aViewThatAnswersOnlyItsWholeValueIsReadBackThroughIt() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(4, 3))
        tree.set(field, kAXValueAttribute, "The cat sat." as CFString)
        tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(4, 3),
                 rectValue(CGRect(x: 140, y: 200, width: 30, height: 20)))
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == SelectionBox(rect: CGRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
        tree.set(field, kAXValueAttribute, "The dog sat." as CFString)
        guard case .selected(_, let edited) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(edited == nil, "a value that no longer holds the selection was believed")
    }

    /// **And a selection that moved between the reads locates nothing**, even onto the same word: the range captured is
    /// the one boxed, never one read again later — which was the box of wherever the reader had gone.
    @Test func aSelectionThatMovedBetweenTheReadsLocatesNothing() {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        tree.answer(field, kAXSelectedTextRangeAttribute, in: [rangeValue(20, 3), rangeValue(40, 3)])
        for location in [20, 40] {
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(location, 3), "cat" as CFString)
            tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(location, 3),
                     rectValue(CGRect(x: CGFloat(10 * location), y: 90, width: 30, height: 16)))
        }
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == nil, "the box of where the selection went was given for where it was: \(String(describing: bounds))")
    }

    /// **WebKit's markers too**: the box asked for is the captured markers', so its text is read back first — a page that
    /// changed under them locates nothing.
    @Test func markersWhoseTextChangedLocateNothing() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
        tree.answerSelectionText(on: page, in: ["word", "ward"])
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == nil, "the markers' box was believed over text that is no longer the selection's")
    }

    /// **Where the word is, is worth having and not worth the selection — but the reader moving on still ends the read**
    /// (audit of 2026-10-10). The box's requests were read with `try?`, which took a cancellation for "no box" and handed
    /// back a selection the reader had already left; in the marker dialect the term's own box swallowed it too. A failure
    /// there leaves the selection with no box; a cancellation cancels.
    @Test func aCancellationWhileTheBoxIsReadCancelsTheSelection() {
        // The text-range dialect: the selection's range, read again for the box, is where the reader moved on.
        let range = FakeAccessibility()
        let field = range.element(1)
        range.set(range.application, kAXFocusedUIElementAttribute, field)
        range.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        range.answer(field, kAXSelectedTextRangeAttribute, in: [rangeValue(4, 3)], thenFail: .cancelled)
        range.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(4, 3), "cat" as CFString)
        // The marker dialect: the selection's first index, asked for the term's own box.
        let markers = FakeAccessibility()
        let page = markers.element(1)
        markers.set(markers.application, kAXFocusedUIElementAttribute, page)
        markers.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        markers.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
        markers.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
        markers.failIndex(on: page, with: .cancelled)
        for (dialect, tree) in [("range", range), ("markers", markers)] {
            let outcome = read(tree)
            guard case .nothing(.failed(.cancelled, _)) = outcome else {
                Issue.record("\(dialect): a cancelled read answered \(outcome)"); continue
            }
        }
    }

    /// **And any other failure there keeps the selection, with no box** — or, where only the term's own box failed, the
    /// selection's box, `containing`, as where WebKit cannot say where the term is.
    @Test func aFailureWhileTheBoxIsReadKeepsTheSelection() {
        let range = FakeAccessibility()
        let field = range.element(1)
        range.set(range.application, kAXFocusedUIElementAttribute, field)
        range.set(field, kAXSelectedTextAttribute, "cat" as CFString)
        range.answer(field, kAXSelectedTextRangeAttribute, in: [rangeValue(4, 3)], thenFail: .notResponding)
        range.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(4, 3), "cat" as CFString)
        guard case .selected(let selection, let bounds) = read(range) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "cat" && bounds == nil)

        let markers = FakeAccessibility()
        let page = markers.element(1)
        markers.set(markers.application, kAXFocusedUIElementAttribute, page)
        markers.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        markers.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
        markers.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
        markers.failIndex(on: page, with: .notResponding)
        guard case .selected(_, let box) = read(markers) else { Issue.record("expected a selection"); return }
        #expect(box == SelectionBox(rect: CGRect(x: 80, y: 140, width: 42, height: 18), quality: .containing))
    }

    /// **A WebKit selection that moved locates nothing, even onto the same word** (audit of 2026-10-10): the captured
    /// markers' text was read back, and still is, but the selection was never asked again — so moving it, to another
    /// occurrence of the same word, kept the old rectangle. The current selection's two ends must be the captured ones.
    @Test func aMarkerSelectionThatMovedLocatesNothing() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
        tree.moveSelection(on: page, toMarkers: 8, 9, indices: nil)
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "word")
        #expect(bounds == nil, "the rectangle of where the selection was was given for where it went")
    }

    /// **The same ends, read as other bytes, are the same selection**: WebKit need not hand back identical markers for one
    /// position, so where the bytes differ the ends are compared by their indices — equal here, so the box stands.
    @Test func aMarkerSelectionReadAgainAtTheSameEndsKeepsItsBox() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "word", sentence: "A word here.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
        tree.moveSelection(on: page, toMarkers: 10, 11, indices: (2, 6))
        guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(bounds == SelectionBox(rect: CGRect(x: 80, y: 140, width: 40, height: 18), quality: .exact))
    }

    /// **WebKit: the selection's own markers, boxed** — exact where the term is the whole selection, `containing` where
    /// punctuation was trimmed from it, since the box then holds that too.
    @Test func theMarkerDialectBoxesTheSelection() {
        for (selected, quality) in [("word", SelectionBox.Quality.exact), ("“word,”", .containing)] {
            let tree = FakeAccessibility()
            let page = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, page)
            tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
            tree.scriptMarkers(on: page, selected: selected, sentence: "A \(selected) here.")
            tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 40, height: 18))
            guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(selection.text == "word")
            #expect(bounds == SelectionBox(rect: CGRect(x: 80, y: 140, width: 40, height: 18), quality: quality), "\(selected)")
        }
    }

    /// **The term's own box where punctuation was trimmed from it** (D3, 2026-10-10): WebKit counts the page's text in
    /// UTF-16 from its start, so the term's markers are the selection's first index plus where the term sits in it — and
    /// the box of those is the word's, read back and held to the term before it is believed: exact. A selection whose
    /// whole box would centre the card's tail on punctuation (`“Q…”`, measured on the E2E Mac) is boxed by its word.
    @Test func aTrimmedSelectionIsBoxedByItsTermWhereWebKitCanSayWhereItIs() {
        let tree = FakeAccessibility()
        let page = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
        tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
        tree.scriptTermMarkers(on: page, selectionIndex: 10, at: 1, length: 1, text: "Q", CGRect(x: 87, y: 140, width: 12, height: 18))
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "Q")
        #expect(bounds == SelectionBox(rect: CGRect(x: 87, y: 140, width: 12, height: 18), quality: .exact))
    }

    /// **And `containing` where WebKit cannot say** — no index for the selection's start, or markers whose text is not the
    /// term: the selection's own box, as before, never a box guessed at.
    @Test func aTrimmedSelectionKeepsTheSelectionsBoxWhereItsTermCannotBeLocated() {
        for (index, text) in [(nil, "Q"), (10, "Q…")] as [(Int?, String)] {
            let tree = FakeAccessibility()
            let page = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, page)
            tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
            tree.scriptMarkers(on: page, selected: "“Q…”", sentence: "Then came “Q…” and more.")
            tree.scriptSelectionBox(on: page, CGRect(x: 80, y: 140, width: 42, height: 18))
            if let index {
                tree.scriptTermMarkers(on: page, selectionIndex: index, at: 1, length: 1, text: text,
                                       CGRect(x: 87, y: 140, width: 12, height: 18))
            }
            guard case .selected(_, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(bounds == SelectionBox(rect: CGRect(x: 80, y: 140, width: 42, height: 18), quality: .containing),
                    "index \(String(describing: index)), text \(text)")
        }
    }

    /// **A range from another process is checked before any sum of it** (audit of 2026-10-10): a selection at `Int.max`
    /// with punctuation trimmed from its front made `location + offset` trap, ending the app; one at a negative location
    /// asked for a box at a negative range, and believed it. Each locates nothing, and the selection itself stands.
    @Test(arguments: [CFRange(location: .max, length: 5), CFRange(location: .max - 1, length: 5),
                      CFRange(location: -5, length: 5), CFRange(location: -1, length: 5)])
    func aSelectedRangeThatCannotBeTheTextsLocatesNothingAndNeverTraps(range: CFRange) {
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, "“cat”" as CFString)
        tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(range.location, range.length))
        // Answered, as a hostile or broken app would, for the range a sum that wrapped or went negative would ask for.
        for location in [range.location &+ 1, range.location] {
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(location, range.length), "“cat”" as CFString)
            tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(location, 3),
                     rectValue(CGRect(x: 300, y: 90, width: 30, height: 16)))
        }
        guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
        #expect(selection.text == "cat")
        #expect(bounds == nil, "a range at \(range.location) was believed")
    }

    /// **Where the word is is worth having, not worth the selection**: an app that answers no box, or an empty one, still
    /// hands over what was selected — with no box, so the card keeps the pointer rule.
    @Test func noBoxOrAnEmptyOneKeepsTheSelectionAndLocatesNothing() {
        for box in [nil, CGRect.zero] {
            let tree = FakeAccessibility()
            let field = tree.element(1)
            tree.set(tree.application, kAXFocusedUIElementAttribute, field)
            tree.set(field, kAXSelectedTextAttribute, "ephemeral" as CFString)
            tree.set(field, kAXSelectedTextRangeAttribute, rangeValue(0, 9))
            tree.set(field, kAXStringForRangeParameterizedAttribute, argument: rangeValue(0, 9), "ephemeral" as CFString)
            if let box { tree.set(field, kAXBoundsForRangeParameterizedAttribute, argument: rangeValue(0, 9), rectValue(box)) }
            guard case .selected(let selection, let bounds) = read(tree) else { Issue.record("expected a selection"); return }
            #expect(selection.text == "ephemeral")
            #expect(bounds == nil)
        }
    }

    private func rangeValue(_ location: Int, _ length: Int) -> AXValue {
        FakeAccessibility.rangeValue(location, length)
    }

    private func rectValue(_ rect: CGRect) -> AXValue {
        let box = rect
        return FakeAccessibility.rectValue(box)
}

}

/// A scripted Accessibility tree. Elements are application elements for made-up process IDs:
/// distinct, comparable CF objects that no request ever reaches.
final class FakeAccessibility: AccessibilityReading {
    /// Values for the scripted tree, the argument's type checked by its type ID before any cast below. A value the API
    /// will not make is the test's own mistake, so it stops the test.
    static func rangeValue(_ location: Int, _ length: Int) -> AXValue {
        guard let value = AccessibilitySession.rangeValue(CFRange(location: location, length: length)) else {
            preconditionFailure("no AXValue for a range")
        }
        return value
    }

    static func rectValue(_ rect: CGRect) -> AXValue {
        var box = rect
        guard let value = AXValueCreate(.cgRect, &box) else { preconditionFailure("no AXValue for a rectangle") }
        return value
    }

    private struct Key: Hashable {
        let element: AXUIElement
        let name: String
        let argument: String?
    }

    let application = AXUIElementCreateApplication(90_000)
    private var values: [Key: CFTypeRef] = [:]
    private var failures: [Key: CaptureError] = [:]
    /// Answers that change between reads, as an app's do while the reader works: one per read, the last kept.
    private var sequences: [Key: [Answer]] = [:]

    private enum Answer {
        case value(CFTypeRef)
        case failure(CaptureError)
    }

    func element(_ number: Int32) -> AXUIElement { AXUIElementCreateApplication(90_000 + number) }

    /// What the hit test finds at a point, by its coordinates.
    private var hits: [String: AXUIElement] = [:]
    /// Every hit test asked, in order.
    private(set) var hitTests: [CGPoint] = []

    /// `element` is what a hit test at `point` finds under the application.
    func hit(_ point: CGPoint, _ element: AXUIElement) { hits["\(point.x) \(point.y)"] = element }

    func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
        hitTests.append(point)
        return root == application ? hits["\(point.x) \(point.y)"] : nil
    }

    func set(_ element: AXUIElement, _ name: String, argument: CFTypeRef? = nil, _ value: CFTypeRef) {
        values[Key(element: element, name: name, argument: argument.map(Self.describe))] = value
    }

    /// `name` answers each of `answers` in turn, one per read, and then the last one for good — or, given `failure`,
    /// fails with it from the read after the last answer on.
    func answer(_ element: AXUIElement, _ name: String, argument: CFTypeRef? = nil, in answers: [CFTypeRef],
                thenFail failure: CaptureError? = nil) {
        sequences[Key(element: element, name: name, argument: argument.map(Self.describe))] =
            answers.map(Answer.value) + (failure.map { [Answer.failure($0)] } ?? [])
    }

    /// The scripted selection's text, read through its markers, answering each of `texts` in turn.
    func answerSelectionText(on page: AXUIElement, in texts: [String]) {
        answer(page, "AXStringForTextMarkerRange", argument: AXTextMarkerRangeCreate(nil, marker(1), marker(2)),
               in: texts.map { $0 as CFString })
    }

    private func next(_ key: Key) throws(CaptureError) -> CFTypeRef? {
        guard var answers = sequences[key], let first = answers.first else { return values[key] }
        if answers.count > 1 { answers.removeFirst(); sequences[key] = answers }
        switch first {
        case .value(let value): return value
        case .failure(let error): throw error
        }
    }

    func fail(_ element: AXUIElement, _ name: String, with error: CaptureError) {
        failures[Key(element: element, name: name, argument: nil)] = error
    }

    /// The marker dialect for one selection inside one sentence, as WebKit answers it.
    func scriptMarkers(on page: AXUIElement, selected: String, sentence: String) {
        let start = marker(1), end = marker(2), last = marker(3), sentenceStart = marker(4), sentenceEnd = marker(5)
        let selection = AXTextMarkerRangeCreate(nil, start, end)
        let sentenceRange = AXTextMarkerRangeCreate(nil, sentenceStart, sentenceEnd)
        set(page, "AXSelectedTextMarkerRange", selection)
        set(page, "AXStringForTextMarkerRange", argument: selection, selected as CFString)
        set(page, "AXPreviousTextMarkerForTextMarker", argument: end, last)
        set(page, "AXSentenceTextMarkerRangeForTextMarker", argument: start, sentenceRange)
        set(page, "AXSentenceTextMarkerRangeForTextMarker", argument: last, sentenceRange)
        set(page, "AXStringForTextMarkerRange", argument: sentenceRange, sentence as CFString)
    }

    /// WebKit's index dialect for a term inside the scripted selection: the selection's first index, a marker for each
    /// of the term's two ends, the range they make, the text that range reads back as, and its box.
    func scriptTermMarkers(on page: AXUIElement, selectionIndex: Int, at offset: Int, length: Int, text: String,
                           _ rect: CGRect) {
        set(page, "AXIndexForTextMarker", argument: marker(1), selectionIndex as CFNumber)
        let first = marker(6), last = marker(7)
        set(page, "AXTextMarkerForIndex", argument: (selectionIndex + offset) as CFNumber, first)
        set(page, "AXTextMarkerForIndex", argument: (selectionIndex + offset + length) as CFNumber, last)
        let range = AXTextMarkerRangeCreate(nil, first, last)
        set(page, "AXTextMarkerRangeForUnorderedTextMarkers", argument: [first, last] as CFArray, range)
        set(page, "AXStringForTextMarkerRange", argument: range, text as CFString)
        let box = rect
        set(page, "AXBoundsForTextMarkerRange", argument: range, Self.rectValue(box))
    }

    /// The selection's first index failing with `error` when the term's
    /// own box is found from it.
    func failIndex(on page: AXUIElement, with error: CaptureError) {
        answer(page, "AXIndexForTextMarker", argument: marker(1), in: [], thenFail: error)
    }

    /// The selection read a second time — when its box is asked for — as the markers `start` and `end`. With `indices`,
    /// those and the scripted selection's own ends answer the same indices, as one position read twice does.
    func moveSelection(on page: AXUIElement, toMarkers start: UInt8, _ end: UInt8, indices: (start: Int, end: Int)?) {
        answer(page, "AXSelectedTextMarkerRange",
               in: [AXTextMarkerRangeCreate(nil, marker(1), marker(2)), AXTextMarkerRangeCreate(nil, marker(start), marker(end))])
        guard let indices else { return }
        set(page, "AXIndexForTextMarker", argument: marker(1), indices.start as CFNumber)
        set(page, "AXIndexForTextMarker", argument: marker(2), indices.end as CFNumber)
        set(page, "AXIndexForTextMarker", argument: marker(start), indices.start as CFNumber)
        set(page, "AXIndexForTextMarker", argument: marker(end), indices.end as CFNumber)
    }

    /// The box WebKit gives the scripted selection's own markers.
    func scriptSelectionBox(on page: AXUIElement, _ rect: CGRect) {
        let box = rect
        set(page, "AXBoundsForTextMarkerRange", argument: AXTextMarkerRangeCreate(nil, marker(1), marker(2)),
            Self.rectValue(box))
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        let key = Key(element: element, name: name, argument: nil)
        if let failure = failures[key] { throw failure }
        return try next(key)
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        try next(Key(element: element, name: name, argument: Self.describe(argument)))
    }

    private func marker(_ byte: UInt8) -> AXTextMarker { AXTextMarkerCreate(nil, [byte], 1) }

    /// Arguments compared by content: a range by its bounds, a marker by its bytes.
    private static func describe(_ argument: CFTypeRef) -> String {
        let type = CFGetTypeID(argument)
        if type == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(unsafeDowncast(argument, to: AXValue.self), .cfRange, &range)
            return "range \(range.location) \(range.length)"
        }
        if type == AXTextMarkerGetTypeID() { return "marker \(bytes(unsafeDowncast(argument, to: AXTextMarker.self)))" }
        if type == CFArrayGetTypeID(), let items = argument as? [CFTypeRef] {
            return "array " + items.map(describe).joined(separator: " ")
        }
        if type == AXTextMarkerRangeGetTypeID() {
            let range = unsafeDowncast(argument, to: AXTextMarkerRange.self)
            return "markers \(bytes(AXTextMarkerRangeCopyStartMarker(range))) \(bytes(AXTextMarkerRangeCopyEndMarker(range)))"
        }
        return String(describing: argument)
    }

    private static func bytes(_ marker: AXTextMarker) -> [UInt8] {
        Array(UnsafeBufferPointer(start: AXTextMarkerGetBytePtr(marker), count: AXTextMarkerGetLength(marker)))
    }
}
