import AppKit
import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The selection in XDict's own windows, its sentence included** (owner, 2026-10-20: the shortcut, the menu and the
/// Service capture the sentence there as anywhere else). Read by the rules hover keeps for XDict's own windows (ADR-0014
/// d.6, ADR-0018): what holds the selection is found by AppKit's first responder on the main actor, never Accessibility;
/// a web view of XDict's is asked by its own reading, bounded by the selection budget and `CaptureLimits.contextUTF16`
/// and checked before use, and never through Accessibility; native controls are read through Accessibility on the main
/// actor, neither woken nor searched for a page nor hit-tested; a secure field is asked nothing; XDict listed under Never
/// look up in has its term looked up and nothing around it read, as any app listed there.
@MainActor
struct OwnSelectionRouteTests {
    private static let ours = FrontApp(pid: getpid(), name: "XDict", bundleID: "ai.xdict.app")
    private static let granted = AccessibilityAccess(probe: { .granted })
    private static let document = "An ephemeral beauty. Second sentence here."

    /// What the readings and the Accessibility clients were asked.
    final class Asked: Sendable {
        let readings = Mutex<[Bool]>([])
        let bounds = Mutex<[Int]>([])
        let clients = Mutex(0)
    }

    /// A reading of an entry holding `document`, with `selected` selected at `offset` (UTF-16).
    private static func entry(_ asked: Asked, document: String = document, selected: String = "ephemeral",
                              at offset: Int = 3) -> OwnSelectionReading {
        { sentence, most in
            asked.readings.withLock { $0.append(sentence) }
            asked.bounds.withLock { $0.append(most) }
            let around = sentence ? OwnViewText(text: document, offset: offset, cutStart: false, cutEnd: false, maxUTF16: most)
                : nil
            return OwnSelectionText(selected: selected, around: around, maxUTF16: most).map(OwnSelectionAnswer.selected)
        }
    }

    private func read(_ holder: OwnSelectionHolder, _ asked: Asked, policy: HoverPolicy = .shipped,
                      budget: Duration = SelectionReader.budget) async -> SelectionOutcome {
        await SelectionReader.read(
            from: Self.ours, admitting: SelectionReaderTests.admission, excluding: policy, access: Self.granted,
            budget: budget, client: { _ in asked.clients.withLock { $0 += 1 }; return FakeAccessibility() },
            ownHolder: { holder })
    }

    private func excludingXDict() -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("ai.xdict.app")
        return policy
    }

    /// **A selection in XDict's entry is read by the entry itself, its sentence too, and never through Accessibility**:
    /// asked for at most `CaptureLimits.contextUTF16` units, the term's range in the sentence its own. Red while XDict's
    /// own selection is read only through Accessibility, or its sentence refused.
    @Test func anEntrysSelectionIsReadByTheEntryNeverByAccessibility() async throws {
        let asked = Asked()
        let outcome = await read(.webView(Self.entry(asked)), asked)
        guard case .selected(let selected, let box) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral" && selected.acquisition == .ownView && selected.app == Self.ours)
        #expect(box == nil)
        guard case .available(let sentence, let range, let cut, nil) = selected.context else {
            Issue.record("context \(selected.context)")
            return
        }
        #expect(sentence == "An ephemeral beauty.")
        #expect((sentence as NSString).substring(with: range) == "ephemeral" && cut == [])
        #expect(asked.clients.withLock { $0 } == 0, "XDict's own web view was asked through Accessibility")
        #expect(asked.readings.withLock { $0 } == [true])
        #expect(asked.bounds.withLock { $0 } == [CaptureLimits.shipped.contextUTF16])
        let term = try #require(try outcome.capturedTerm(trigger: .selection))
        #expect(term.source.bundleID == "ai.xdict.app")
    }

    /// **XDict listed under Never look up in: the entry is asked for the selection alone**, never its sentence, and the
    /// term is still looked up — the reader asked. Red where an excluded XDict's sentence is asked for.
    @Test func anExcludedXDictAsksTheEntryForNoSentence() async {
        let asked = Asked()
        let outcome = await read(.webView(Self.entry(asked)), asked, policy: excludingXDict())
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral")
        #expect(selected.context == .unavailable(.excluded))
        #expect(asked.readings.withLock { $0 } == [false])
    }

    /// **A web view of XDict's that nothing reads is asked nothing**, Accessibility included: that would wait on WebKit,
    /// which waits on the main thread. Red where it falls back to Accessibility.
    @Test func aWebViewNothingReadsIsAskedNothing() async {
        let asked = Asked()
        #expect(await read(.webView(nil), asked) == .nothing(.nothingSelected(app: "XDict")))
        #expect(asked.clients.withLock { $0 } == 0)
    }

    /// **A secure field is asked nothing** — no reading, no Accessibility. Red where a refused holder is read.
    @Test func aSecureFieldIsAskedNothing() async {
        let asked = Asked()
        #expect(await read(.refused, asked) == .nothing(.nothingSelected(app: "XDict")))
        #expect(asked.clients.withLock { $0 } == 0)
    }

    /// **An entry that does not answer is given up at the selection's budget**, as past its deadline. Red where the
    /// reading is awaited without a bound.
    @Test func aSilentEntryIsGivenUpAtTheBudget() async {
        let asked = Asked()
        let silent: OwnSelectionReading = { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        let started = ContinuousClock.now
        let outcome = await read(.webView(silent), asked, budget: .milliseconds(100))
        #expect(outcome == .nothing(.failed(.deadlineExceeded, app: "XDict")))
        // Well short of the five seconds the view would hold it, with room for other tests holding the main actor: the
        // read is the main actor's, and its deadline resumes there (1.03 s seen in a run of 367 tests; hover's twin,
        // `OwnViewRouteTests.aViewThatDoesNotAnswerIsGivenUpAtTheBudget`, keeps the same room).
        let took = ContinuousClock.now - started
        #expect(took < .seconds(4), "an own view's reading was awaited \(took)")
    }

    /// **A selection longer than the entry reads is refused with its own sentence**, never cut and never "nothing
    /// selected".
    @Test func aSelectionTooLongToReadSaysSo() async {
        let asked = Asked()
        let long: OwnSelectionReading = { _, _ in .tooLong }
        #expect(await read(.webView(long), asked) == .nothing(.tooLongToRead(app: "XDict")))
    }

    /// **The entry's selection is held to the rules every selection is**: whitespace is nothing selected, punctuation no
    /// word, and a term over the consumer's admission is refused whole with its length.
    @Test func theEntrysSelectionIsAdmittedAsAnyAppsIs() async {
        let asked = Asked()
        let long = String(repeating: "word ", count: 60)
        let cases: [(String, SelectionOutcome)] = [
            ("   ", .nothing(.nothingSelected(app: "XDict"))),
            ("“,”", .nothing(.noWord(app: "XDict"))),
            (long, .nothing(.tooLong(app: "XDict", characters: long.trimmingCharacters(in: .whitespaces).count))),
        ]
        for (selected, expected) in cases {
            let reading = Self.entry(asked, document: selected, selected: selected, at: 0)
            #expect(await read(.webView(reading), asked) == expected, "\(selected)")
        }
    }

    /// **XDict's native controls are read through Accessibility, on the main actor** (ADR-0018 d.3). The control for the
    /// web-view route: the holder decides.
    @Test func ourControlsAreReadThroughAccessibilityOnTheMainActor() async {
        let recorder = SelectionCaptureTests.Recorder()
        let outcome = await SelectionReader.read(
            from: Self.ours, admitting: SelectionReaderTests.admission, excluding: .shipped, access: Self.granted,
            client: { _ in recorder.clients.withLock { $0 += 1 }; return SelectionCaptureTests.ThreadNoting(recorder) },
            ownHolder: { .controls })
        #expect(outcome == .nothing(.nothingSelected(app: "XDict")))
        #expect(recorder.clients.withLock { $0 } == 1)
        let threads = recorder.onMain.withLock { $0 }
        #expect(!threads.isEmpty && threads.allSatisfy { $0 }, "\(threads)")
    }
}

/// **XDict's own controls are read from the focused element alone**: never woken (told an assistive client reads it,
/// XDict would change itself for the rest of the launch), never searched for a page (the page is a web view of XDict's,
/// which Accessibility must not ask), never hit-tested at the Control-click (that point may be over a web view).
struct OwnControlsReadTests {
    /// A client that counts `wake` and passes everything else to a scripted tree.
    final class Waking: AccessibilityReading {
        let tree: FakeAccessibility
        private(set) var wakes = 0
        init(_ tree: FakeAccessibility) { self.tree = tree }
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            try tree.attribute(element, name, ofApplication: ofApplication)
        }
        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            try tree.parameterized(element, name, argument)
        }
        func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
            try tree.hitTest(root, at: point)
        }
        func wake(_ application: AXUIElement) throws(CaptureError) { wakes += 1 }
    }

    /// A window whose page holds a selection, the focused element holding none, a click at (5, 5) over the page: what
    /// another app's read finds by its page search.
    private func pageBehindTheFocus() -> FakeAccessibility {
        let tree = FakeAccessibility()
        let bar = tree.element(1), window = tree.element(2), group = tree.element(3), page = tree.element(4)
        tree.set(tree.application, kAXFocusedUIElementAttribute, bar)
        tree.set(tree.application, kAXFocusedWindowAttribute, window)
        tree.set(window, kAXChildrenAttribute, [group] as CFArray)
        tree.set(group, kAXChildrenAttribute, [page] as CFArray)
        tree.set(page, kAXRoleAttribute, "AXWebArea" as CFString)
        tree.scriptMarkers(on: page, selected: "abbé", sentence: "An abbé.")
        tree.hit(CGPoint(x: 5, y: 5), page)
        return tree
    }

    @Test func ourControlsAreNeitherWokenNorSearchedNorHitTested() {
        let tree = pageBehindTheFocus()
        let client = Waking(tree)
        let ours = FrontApp(pid: getpid(), name: "XDict", bundleID: "ai.xdict.app")
        let outcome = SelectionReader.read(application: tree.application, of: ours, with: client, clicked: CGPoint(x: 5, y: 5),
                                           admitting: SelectionReaderTests.admission, excluding: .shipped)
        #expect(outcome == .nothing(.nothingSelected(app: "XDict")))
        #expect(client.wakes == 0, "XDict woke itself")
        #expect(tree.hitTests.isEmpty, "XDict's own window was hit-tested")
        #expect(!tree.asked.contains(kAXChildrenAttribute) && !tree.asked.contains(kAXFocusedWindowAttribute),
                "XDict's own window was searched for a page: \(tree.asked)")
    }

    /// The control: another app's read is woken, and finds the page behind its focus.
    @Test func anotherAppIsWokenAndSearched() {
        let tree = pageBehindTheFocus()
        let client = Waking(tree)
        let reader = FrontApp(pid: 1, name: "Reader", bundleID: "com.example.reader")
        let outcome = SelectionReader.read(application: tree.application, of: reader, with: client,
                                           admitting: SelectionReaderTests.admission, excluding: .shipped)
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "abbé" && client.wakes == 1)
    }
}

/// **An entry's answer is data**: taken only where the selection is 1…`maxUTF16` units and the text around it, where
/// there is one, holds the selection exactly where it says.
struct OwnSelectionTextTests {
    private func around(_ text: String, _ offset: Int) -> OwnViewText? {
        OwnViewText(text: text, offset: offset, cutStart: false, cutEnd: false, maxUTF16: 100)
    }

    @Test func aSelectionHeldWhereItSaysIsTaken() throws {
        let text = try #require(OwnSelectionText(selected: "beauty", around: around("An ephemeral beauty.", 13), maxUTF16: 100))
        #expect(text.selected == "beauty" && text.around?.offset == 13)
        #expect(OwnSelectionText(selected: "beauty", around: nil, maxUTF16: 100)?.around == nil)
    }

    @Test func anAnswerOutOfShapeIsRefused() {
        // Not where it says; running past the text; empty; longer than asked for.
        #expect(OwnSelectionText(selected: "beauty", around: around("An ephemeral beauty.", 3), maxUTF16: 100) == nil)
        #expect(OwnSelectionText(selected: "beauty.!", around: around("An ephemeral beauty.", 13), maxUTF16: 100) == nil)
        #expect(OwnSelectionText(selected: "", around: nil, maxUTF16: 100) == nil)
        #expect(OwnSelectionText(selected: String(repeating: "x", count: 101), around: nil, maxUTF16: 100) == nil)
    }
}

/// **What holds the selection in XDict's own window is AppKit's first responder**, found on the main actor: a web view
/// (any `WKWebView`) and whatever is inside it is the web view's, asked by its own reading; a secure field, or its field
/// editor, is refused; anything else is a native control.
@MainActor
struct OwnSelectionHolderTests {
    final class StandInWebView: NSView {}
    final class Focusable: NSView { override var acceptsFirstResponder: Bool { true } }

    private func window(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = content
        return window
    }

    private func holder(_ window: NSWindow?, handed: inout [NSView]) -> OwnSelectionHolder {
        var seen: [NSView] = []
        let found = OwnSelections.holder(in: window, isWebView: { $0 is StandInWebView }, reading: { view in
            seen.append(view)
            return { _, _ in nil }
        })
        handed = seen
        return found
    }

    @Test func aResponderInsideAWebViewIsTheWebViews() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let web = StandInWebView(frame: content.bounds)
        let inner = Focusable(frame: web.bounds)
        web.addSubview(inner)
        content.addSubview(web)
        let window = window(content)
        #expect(window.makeFirstResponder(inner))
        var handed: [NSView] = []
        guard case .webView(let reading?) = holder(window, handed: &handed) else { Issue.record("not the web view's"); return }
        _ = reading
        #expect(handed.count == 1 && handed.first === web)
    }

    @Test func aNativeControlIsAControl() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let view = NSTextView(frame: content.bounds)
        content.addSubview(view)
        let window = window(content)
        #expect(window.makeFirstResponder(view))
        var handed: [NSView] = []
        guard case .controls = holder(window, handed: &handed) else { Issue.record("not a control"); return }
        #expect(handed.isEmpty)
    }

    /// Red where a secure field, or the field editor editing one, is read as a control.
    @Test func aSecureFieldIsRefused() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let field = NSSecureTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "hunter2"
        content.addSubview(field)
        let window = window(content)
        #expect(window.makeFirstResponder(field))
        var handed: [NSView] = []
        guard case .refused = holder(window, handed: &handed) else {
            Issue.record("a secure field was not refused: \(String(describing: window.firstResponder))")
            return
        }
        #expect(OwnSelections.isSecure(field))
    }
}
