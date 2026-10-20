import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
import XDictCaptureMac

/// **The selection read on the lane, its hit test inside its budget, and handed over as a captured term** (XDict
/// ADR-0014 decisions 2, 6 and 3; plan-capture WI-2). Scripted trees and fake lanes only: no window, no real
/// Accessibility request, no grant of this Mac's.
struct SelectionCaptureTests {
    private let app = FrontApp(pid: 1, name: "Reader", bundleID: "com.example.reader")
    private static let granted = AccessibilityAccess(probe: { .granted })

    /// A text view holding `text` selected, its range and its box, under the element `number` of `tree`.
    private func textView(_ tree: FakeAccessibility, _ number: Int32, holding text: String, box: CGRect) -> AXUIElement {
        let view = tree.element(number)
        let length = (text as NSString).length
        tree.set(view, kAXSelectedTextAttribute, text as CFString)
        tree.set(view, kAXSelectedTextRangeAttribute, FakeAccessibility.rangeValue(0, length))
        tree.set(view, kAXStringForRangeParameterizedAttribute, argument: FakeAccessibility.rangeValue(0, length),
                 text as CFString)
        tree.set(view, kAXBoundsForRangeParameterizedAttribute, argument: FakeAccessibility.rangeValue(0, length),
                 FakeAccessibility.rectValue(box))
        return view
    }

    // MARK: - The hit test inside the read

    /// **The clicked position is hit-tested by the read itself** (decision 6): the element there is found through the
    /// read's own client — so through its budget — and its selection read, as XDict's Service fix reads beneath the
    /// secondary click. Red if the hit test happens anywhere but the read's client.
    @Test func theClickedPositionIsHitTestedInsideTheRead() {
        let tree = FakeAccessibility()
        let clicked = CGPoint(x: 440, y: 150)
        let paragraph = tree.element(3)
        let view = textView(tree, 2, holding: "crème brûlée", box: CGRect(x: 429, y: 140, width: 120, height: 23))
        tree.set(paragraph, kAXParentAttribute, view)
        tree.hit(clicked, paragraph)
        let outcome = SelectionReader.read(application: tree.application, of: app, with: tree, clicked: clicked,
                                           admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions)
        #expect(tree.hitTests == [clicked])
        guard case .selected(let selected, let box) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "crème brûlée")
        #expect(box == SelectionBox(rect: CGRect(x: 429, y: 140, width: 120, height: 23), quality: .exact))
    }

    /// **A stalled hit test does not outlive the selection's budget**: the session's deadline covers it, so a hit test
    /// that blocked past the budget ends the read as `deadlineExceeded` and nothing more is asked of the app.
    @Test func aStalledHitTestDoesNotOutliveTheSelectionsBudget() {
        let asked = Mutex(0)
        let session = AccessibilitySession(budget: .milliseconds(20), requests: AccessibilityRequests(
            attribute: { _, _ in asked.withLock { $0 += 1 }; return (.noValue, nil) },
            parameterized: { _, _, _ in asked.withLock { $0 += 1 }; return (.noValue, nil) },
            elementAt: { root, _ in
                Blocking.for(.milliseconds(80))
                return (.success, root)
            }))
        let outcome = SelectionReader.read(application: AXUIElementCreateApplication(91_100), of: app, with: session,
                                           clicked: CGPoint(x: 1, y: 1), admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions)
        #expect(outcome == .nothing(.failed(.deadlineExceeded, app: "Reader")))
        #expect(asked.withLock { $0 } == 0, "the read went on asking after its budget was spent")
    }

    // MARK: - The lane and the main actor

    /// Records what the lane was asked and on which thread each request ran.
    final class Recorder: Sendable {
        let timeouts = Mutex<[Float]>([])
        let onMain = Mutex<[Bool]>([])
        let clients = Mutex(0)
    }

    /// A client with nothing selected that notes the thread of every request.
    final class ThreadNoting: AccessibilityReading {
        let recorder: Recorder
        init(_ recorder: Recorder) { self.recorder = recorder }
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            recorder.onMain.withLock { $0.append(Thread.isMainThread) }
            return nil
        }
        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            recorder.onMain.withLock { $0.append(Thread.isMainThread) }
            return nil
        }
    }

    /// **This process's own windows are read on the main actor, and never through the lane** (XiaolaiDict ADR-0042): a
    /// request about this process is serviced on the calling thread, and a floating panel of XDict's answering it off
    /// the main thread is a SwiftUI body evaluated off it — a trap. Red if the own-process read is sent to the lane or
    /// detached.
    @Test func theReadersOwnWindowsAreReadOnTheMainActorAndNeverThroughTheLane() async {
        let recorder = Recorder()
        let lane = AccessibilityLane.patient { timeout in recorder.timeouts.withLock { $0.append(timeout) } }
        let ours = FrontApp(pid: getpid(), name: "XDict", bundleID: "ai.xdict.app")
        let outcome = await SelectionReader.read(
            from: ours, admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions, access: Self.granted, lane: lane,
            client: { _ in recorder.clients.withLock { $0 += 1 }; return ThreadNoting(recorder) }, ownHolder: { .controls })
        #expect(outcome == .nothing(.nothingSelected(app: "XDict")))
        #expect(recorder.timeouts.withLock { $0 }.isEmpty, "the own-process read went through the lane")
        let threads = recorder.onMain.withLock { $0 }
        #expect(!threads.isEmpty && threads.allSatisfy { $0 }, "an own-process request ran off the main thread: \(threads)")
    }

    /// **Another app's selection is read through the lane**, as an explicit request under the explicit timeout, off the
    /// main thread. The control for the test above.
    @Test func anotherAppsSelectionIsReadThroughTheLaneOffTheMainThread() async {
        let recorder = Recorder()
        let lane = AccessibilityLane.patient { timeout in recorder.timeouts.withLock { $0.append(timeout) } }
        let outcome = await SelectionReader.read(
            from: app, admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions, access: Self.granted, lane: lane,
            client: { _ in ThreadNoting(recorder) }, ownHolder: { .controls })
        #expect(outcome == .nothing(.nothingSelected(app: "Reader")))
        #expect(recorder.timeouts.withLock { $0 } == [AccessibilitySession.messagingTimeout])
        #expect(recorder.onMain.withLock { $0 }.allSatisfy { !$0 }, "another app was asked from the main thread")
    }

    /// **Without the grant nothing is asked**, of the lane or of the app, and nothing prompts (decision 7).
    @Test func aReadWithoutTheGrantAsksNothing() async {
        let recorder = Recorder()
        let lane = AccessibilityLane.patient { timeout in recorder.timeouts.withLock { $0.append(timeout) } }
        for probe: PermissionProbe in [.declined, .couldNotTell] {
            let outcome = await SelectionReader.read(
                from: app, admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions, access: AccessibilityAccess(probe: { probe }),
                lane: lane, client: { _ in recorder.clients.withLock { $0 += 1 }; return ThreadNoting(recorder) },
                ownHolder: { .controls })
            #expect(outcome == .nothing(.notTrusted))
        }
        #expect(recorder.clients.withLock { $0 } == 0 && recorder.timeouts.withLock { $0 }.isEmpty)
    }

    /// A client whose first request does not return until released: a call blocked inside another process.
    final class Blocked: AccessibilityReading, Sendable {
        let release = Mutex(false)
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            Blocking.until { release.withLock { $0 } }
            return nil
        }
        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            nil
        }
    }

    /// **A read blocked in the framework is told, not waited on**: past its budget and the lane's overrun the shortcut
    /// is answered that the app did not answer, while the lane reports itself stuck. Red if the read waits for the
    /// blocked request to return.
    @Test func aStuckReadIsAnsweredAsAnAppNotAnswering() async throws {
        let bounds = try #require(LaneBounds(explicitResidence: .seconds(1), hoverResidence: .seconds(1),
                                             overrun: .milliseconds(20)))
        let lane = AccessibilityLane(bounds: bounds) { _ in }
        let blocked = Blocked()
        let reading = Task {
            await SelectionReader.read(from: app, admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions, access: Self.granted,
                                       lane: lane, budget: .milliseconds(20), client: { _ in blocked },
                                       ownHolder: { .controls })
        }
        let outcome = await Wait.value(of: reading)
        #expect(outcome == .nothing(.failed(.notResponding, app: "Reader")))
        if case .stuck = lane.current() {} else { Issue.record("the lane says \(lane.current()) while blocked") }
        blocked.release.withLock { $0 = true }
        #expect(await Wait.until { lane.current() == .idle })
    }

    // MARK: - Handed over

    /// **The selection becomes a captured term** with its facts apart (decision 2): trigger and acquisition as two fields,
    /// the measured box of its quality, the app, and the context as read: this view answers no text around its
    /// selection, so it says so (the sentence itself: `SelectionContextReadTests`).
    @Test func aSelectionIsHandedOverAsACapturedTerm() throws {
        let tree = FakeAccessibility()
        let view = textView(tree, 2, holding: "take off", box: CGRect(x: 10, y: 20, width: 60, height: 16))
        tree.set(tree.application, kAXFocusedUIElementAttribute, view)
        let outcome = SelectionReader.read(application: tree.application, of: app, with: tree,
                                           admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions)
        let term = try #require(try outcome.capturedTerm(trigger: .selection))
        #expect(term.term == "take off")
        #expect(term.trigger == .selection && term.acquisition == .textRange)
        #expect(term.source == SourceApp(bundleID: "com.example.reader"))
        #expect(term.box == .measured(ReadBounds(rect: DownRect(x: 10, y: 20, width: 60, height: 16), quality: .exact)))
        #expect(term.context == .unavailable(.appExposedNone))
        #expect(try SelectionOutcome.nothing(.noApp).capturedTerm(trigger: .menu) == nil)
    }

    /// **Capture never cuts a key** (decision 3): a 299-character selection is refused whole under lookup's 200, and read
    /// whole under a consumer that admits more — the limit is the consumer's, not the reader's.
    @Test func aLongSelectionIsReadWholeUnderAWiderAdmission() {
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let tree = FakeAccessibility()
        let field = tree.element(1)
        tree.set(tree.application, kAXFocusedUIElementAttribute, field)
        tree.set(field, kAXSelectedTextAttribute, long as CFString)
        let wide = SelectionReader.read(application: tree.application, of: app, with: tree,
                                        admitting: TermAdmission(maximumCharacters: 300),
                                        excluding: SelectionReaderTests.exclusions)
        guard case .selected(let selected, _) = wide else { Issue.record("got \(wide)"); return }
        #expect(selected.text == long && selected.text.count == 299)
    }

    // MARK: - The Service's text wins

    private let source = SourceApp(bundleID: "com.example.reader")
    private let clicked = DownPoint(x: 440, y: 150)

    /// **Service text that differs from the current selection stays the query, with no context and no geometry from
    /// it**: the app's selection changed after macOS handed the Service its text. The placement falls back to the click.
    @Test func theServiceTextStaysTheQueryWhenTheSelectionDisagrees() throws {
        let read = SelectionOutcome.selected(
            SelectedText(text: "take", app: app, acquisition: .textRange),
            box: SelectionBox(rect: CGRect(x: 1, y: 2, width: 30, height: 16), quality: .exact))
        let term = try SelectionReader.serviceTerm("take off", read: read, source: source, clicked: clicked)
        #expect(term.term == "take off")
        #expect(term.trigger == .service && term.acquisition == .serviceText)
        #expect(term.box == .clickPlacement(clicked), "geometry came from a selection that is not the query")
        #expect(term.context == .unavailable(.disagreesWithServiceText))
    }

    /// **The originating app has quit**: the read failed, the Service's text is still the query, placed by the click.
    @Test func theServiceTextStaysTheQueryWhenTheAppHasExited() throws {
        let tree = FakeAccessibility()
        tree.fail(tree.application, kAXFocusedUIElementAttribute, with: .appUnavailable)
        let read = SelectionReader.read(application: tree.application, of: app, with: tree,
                                        admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions)
        #expect(read == .nothing(.failed(.appUnavailable, app: "Reader")))
        let term = try SelectionReader.serviceTerm("take off", read: read, source: source, clicked: clicked)
        #expect(term.term == "take off" && term.acquisition == .serviceText)
        #expect(term.box == .clickPlacement(clicked))
        #expect(term.context == .unavailable(.notCaptured))
    }

    /// **The pointer moved into the Services submenu**: the element under the pointer now is the menu item, whose text
    /// is the item's title — read, it disagrees, and supplies nothing. The Service's text stays the query, placed by
    /// where the reader Control-clicked, never by where the pointer went.
    @Test func theServiceTextStaysTheQueryWhenThePointerMovedIntoTheSubmenu() throws {
        let tree = FakeAccessibility()
        let pointer = CGPoint(x: 700, y: 300)
        let item = textView(tree, 4, holding: "Look Up in XDict", box: CGRect(x: 690, y: 290, width: 140, height: 22))
        tree.hit(pointer, item)
        let read = SelectionReader.read(application: tree.application, of: app, with: tree, clicked: pointer,
                                        admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions)
        let term = try SelectionReader.serviceTerm("ephemeral", read: read, source: source, clicked: clicked)
        #expect(term.term == "ephemeral")
        #expect(term.box == .clickPlacement(clicked))
        #expect(term.context == .unavailable(.disagreesWithServiceText))
    }

    /// The control: a selection that reads back as the Service's text lends its measured box.
    @Test func theServiceTextAgreeingWithTheSelectionTakesItsBox() throws {
        let read = SelectionOutcome.selected(
            SelectedText(text: "take off", app: app, acquisition: .textMarkers),
            box: SelectionBox(rect: CGRect(x: 1, y: 2, width: 60, height: 16), quality: .containing))
        let term = try SelectionReader.serviceTerm("take off", read: read, source: source, clicked: clicked)
        #expect(term.box == .measured(ReadBounds(rect: DownRect(x: 1, y: 2, width: 60, height: 16), quality: .containing)))
        #expect(term.acquisition == .serviceText && term.context == .unavailable(.notCaptured))
        #expect(try SelectionReader.serviceTerm("take off", read: nil, source: source, clicked: nil).box == .absent)
    }
}
