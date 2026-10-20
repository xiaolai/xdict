import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The pointer's word in each dialect, who owns the pixel, and what a hit says about itself** (plan-capture WI-2;
/// XDict ADR-0014 decisions 2, 6, 7 and 9). Scripted trees only: the text range and the bounds scan through `Glyphs`,
/// the text markers through `WebPage`; the hit test through `HitTests`. No window, no real Accessibility request.
struct PointerWordReaderTests {
    // MARK: - The text-marker dialect

    /// WebKit's page: "The cat sat." with "cat" at x 140…170, y 200…220, answered through markers only.
    final class WebPage: AccessibilityReading {
        static let sentence = "The cat sat."
        let sentence: String
        init(sentence: String = WebPage.sentence) { self.sentence = sentence }
        private func marker(_ byte: UInt8) -> AXTextMarker { AXTextMarkerCreate(nil, [byte], 1) }
        private var word: AXTextMarkerRange { AXTextMarkerRangeCreate(nil, marker(2), marker(3)) }
        private var whole: AXTextMarkerRange { AXTextMarkerRangeCreate(nil, marker(4), marker(5)) }

        private static func firstByte(_ argument: CFTypeRef) -> UInt8? {
            guard CFGetTypeID(argument) == AXTextMarkerRangeGetTypeID() else { return nil }
            let start = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(argument, to: AXTextMarkerRange.self))
            return AXTextMarkerGetBytePtr(start).pointee
        }

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            name == kAXRoleAttribute ? "AXWebArea" as CFString : nil
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case "AXTextMarkerForPosition": return marker(1)
            case "AXRightWordTextMarkerRangeForTextMarker": return word
            case "AXSentenceTextMarkerRangeForTextMarker": return whole
            case "AXBoundsForTextMarkerRange":
                guard Self.firstByte(argument) == 2 else { return nil }
                var box = CGRect(x: 140, y: 200, width: 30, height: 20)
                return AXValueCreate(.cgRect, &box)
            case "AXStringForTextMarkerRange":
                switch Self.firstByte(argument) {
                case 2: return "cat" as CFString
                case 4: return sentence as CFString
                default: return nil
                }
            default: return nil
            }
        }
    }

    private let target = PointerWordReader.Target(
        element: AXUIElementCreateApplication(pid_t(4_200_000)), appName: "Safari", bundleID: "com.apple.Safari")

    /// **WebKit's markers: the word under the pointer, placed in its sentence**, its box WebKit's word — `containing`,
    /// since WebKit's word can hold more than the token.
    @Test func theMarkerDialectReadsTheWordInItsSentence() throws {
        let outcome = PointerWordReader.read(at: CGPoint(x: 155, y: 210), in: target, tolerance: Measured.hit, with: WebPage())
        guard case .hit(let hit) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(hit.acquisition == .textMarkers)
        #expect(hit.word.word == "cat")
        #expect(hit.word.sentence.text == WebPage.sentence)
        #expect(hit.word.sentence.selection == NSRange(location: 4, length: 3))
        #expect(hit.bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .containing))
    }

    /// Off every word by more than the tolerance, no dialect answers: a miss naming the role, never the nearest word.
    @Test func aPointerOffEveryWordReadsNothing() {
        let outcome = PointerWordReader.read(at: CGPoint(x: 155, y: 260), in: target, tolerance: Measured.hit, with: WebPage())
        #expect(outcome == .miss(.noText(app: "Safari", role: "AXWebArea")))
    }

    /// **A page's "sentence" is cut to the context limit before it is segmented** (decision 3): WebKit can answer a
    /// whole document for a sentence. 160,013 UTF-16 units come back; what is segmented, and handed over, is at most
    /// `contextUTF16` around the word, its cut ends marked.
    @Test func aDocumentLongSentenceIsCutBeforeItIsSegmented() {
        let filler = String(repeating: "lorem ", count: 13_333)
        let long = filler + "The cat sat." + filler + "xxxxx"
        #expect(long.utf16.count == 160_013)
        let outcome = PointerWordReader.read(at: CGPoint(x: 155, y: 210), in: target, tolerance: Measured.hit,
                                             limits: .shipped, with: WebPage(sentence: long))
        guard case .hit(let hit) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(hit.word.word == "cat")
        #expect(hit.word.sentence.text.utf16.count <= CaptureLimits.shipped.contextUTF16)
        #expect(hit.word.sentence.mayBeCut)
    }

    /// **The bounds scan refuses a value longer than its read window before tokenising it**: fifty long words pass the
    /// word cap, so only the length bound keeps the whole value from being segmented and scanned.
    @Test func theBoundsScanDoesNotSegmentAValueLongerThanItsWindow() throws {
        let limits = try #require(CaptureLimits(readRadiusUTF16: 100, contextUTF16: 80, observations: 1, tilePixels: 2,
                                                tileOverlapPixels: 1))
        let value = (0..<50).map { _ in String(repeating: "a", count: 9) }.joined(separator: " ")
        #expect(value.utf16.count > 2 * limits.readRadiusUTF16)
        let glyphs = Glyphs(value, speaksTextRange: false)
        let outcome = PointerWordReader.read(at: CGPoint(x: 105, y: 210), in: target, tolerance: Measured.hit,
                                             limits: limits, with: glyphs)
        guard case .miss = outcome else { Issue.record("got \(outcome)"); return }
        #expect(glyphs.boundsAsked == 0, "the whole value was segmented and scanned")
    }

    // MARK: - Who owns the pixel

    /// A client that answers only the hit test, counting it, with `found` or a stall.
    final class HitTests: AccessibilityReading, Sendable {
        let asked = Mutex(0)
        let pid: pid_t?
        init(finding pid: pid_t?) { self.pid = pid }
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? { nil }
        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            nil
        }
        func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
            asked.withLock { $0 += 1 }
            return pid.map(AXUIElementCreateApplication)
        }
    }

    private static let granted = AccessibilityAccess(probe: { .granted })
    private let point = CGPoint(x: 300, y: 300)

    /// **One of XDict's own floating windows under the pointer is left to the main actor before the hit test** (XiaolaiDict
    /// ADR-0042): off the main actor the hit test itself would be serviced in this process, on this thread. Every window
    /// level counts — the popover floats. Red if the compositor's list is asked after Accessibility, or only at level 0.
    @Test func anOwnFloatingWindowIsLeftToTheMainActorBeforeTheHitTest() {
        let client = HitTests(finding: 4_300_001)
        let panel = ListedWindow(pid: getpid(), bounds: CGRect(x: 250, y: 250, width: 200, height: 200), layer: 3)
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [panel] },
                                               ownProcess: getpid(), refusesOwner: { _ in false }, with: client)
        guard case .ownWindow = outcome else { Issue.record("got \(outcome)"); return }
        #expect(client.asked.withLock { $0 } == 0, "Accessibility was asked about XDict's own window off the main actor")
    }

    /// **And a window of ours that arrived after the list was taken is handed back too**, by the owner of what the hit
    /// test found — late, but no element of XDict's is read off the main actor. The control: another app's window is found.
    @Test func anOwnWindowMissingFromTheListIsHandedBackByItsOwner() {
        let ours = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                            refusesOwner: { _ in false }, with: HitTests(finding: getpid()))
        guard case .ownWindow = ours else { Issue.record("got \(ours)"); return }
        let theirs = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                              refusesOwner: { _ in false }, with: HitTests(finding: 4_300_002))
        guard case .found(let target) = theirs else { Issue.record("got \(theirs)"); return }
        #expect(target.pid == 4_300_002)
    }

    /// A synthetic SwiftUI-shaped window, the shape System Settings answers in (measured 2026-10-19, rebuilt here with
    /// made-up elements): asked through its application, the hit test names only the window's hosting group; the text
    /// under the pointer is found by descending, the smallest child holding the point at each level — a table's column
    /// spans every row, so the row inside it is the one taken. The system-wide hit test names the text directly.
    final class HostedWindow: AccessibilityReading, @unchecked Sendable {
        static let owner: pid_t = 4_300_010
        /// The process whose own hit test names the group: another app's, or this one's for XDict's own window.
        let owner: pid_t
        init(owner: pid_t = HostedWindow.owner) { self.owner = owner }
        let group = AXUIElementCreateApplication(4_400_001)
        let column = AXUIElementCreateApplication(4_400_002)
        let row = AXUIElementCreateApplication(4_400_003)
        let text = AXUIElementCreateApplication(4_400_004)
        let heading = AXUIElementCreateApplication(4_400_005)
        /// The process each hit test was asked of: 0 for the system-wide element.
        private(set) var askedOf: [pid_t] = []

        private func frame(of element: AXUIElement) -> CGRect? {
            switch element {
            case group: CGRect(x: 0, y: 0, width: 740, height: 625)
            case column: CGRect(x: 200, y: 100, width: 500, height: 400)
            case row: CGRect(x: 200, y: 280, width: 500, height: 40)
            case text: CGRect(x: 250, y: 290, width: 100, height: 20)
            case heading: CGRect(x: 250, y: 40, width: 200, height: 20)
            default: nil
            }
        }

        /// Every attribute asked of any element.
        private(set) var attributesAsked = 0

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            attributesAsked += 1
            switch name {
            case kAXChildrenAttribute:
                switch element {
                case group: return [heading, column, row] as CFArray
                case row: return [text] as CFArray
                default: return [] as CFArray
                }
            case kAXPositionAttribute:
                guard var origin = frame(of: element)?.origin else { return nil }
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute:
                guard var size = frame(of: element)?.size else { return nil }
                return AXValueCreate(.cgSize, &size)
            default:
                return nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            nil
        }

        func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
            var pid: pid_t = 0
            if root != AXUIElementCreateSystemWide() { AXUIElementGetPid(root, &pid) }
            askedOf.append(pid)
            return pid == owner ? group : text
        }
    }

    /// **XDict's own window is hit-tested through XDict's own application, never the system-wide element**, and its
    /// answer descended by the same bounded rule as another app's: the element is the text under the point, not the
    /// window's group. Red if the own hit test asks the system-wide element (which can land in another app, synchronous
    /// IPC on the main thread) or takes the group as it is.
    @Test func ourOwnWindowIsHitTestedThroughOurOwnApplicationAndDescended() {
        let tree = HostedWindow(owner: getpid())
        let outcome = PointerWordReader.ownTarget(at: point, access: Self.granted, ownProcess: getpid(), with: tree)
        guard case .found(let target) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(target.element == tree.text)
        #expect(tree.askedOf == [getpid()], "XDict's own hit test was not asked of XDict's own application alone")
    }

    /// Without the grant the main actor asks nothing either.
    @Test func ourOwnTargetWithoutTheGrantAsksNothing() {
        let client = HitTests(finding: getpid())
        let outcome = PointerWordReader.ownTarget(at: point, access: AccessibilityAccess(probe: { .declined }),
                                                  ownProcess: getpid(), with: client)
        guard case .none(.accessibilityOff) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(client.asked.withLock { $0 } == 0)
    }

    /// **Another app's window in front of one of ours is read through that app alone** (owner's report, 2026-10-19:
    /// with XDict's main and Settings windows behind System Settings, hover read only the one word of its title outside
    /// them, and was silent everywhere else). The system-wide hit test is never asked — it could go through a click-through
    /// window to ours, in this process — and the element named is the text under the point, not the window's group. Red
    /// under the old rule (any window of ours at any depth refused the hover).
    @Test func anotherAppsWindowInFrontOfOursIsReadThroughThatAppAlone() {
        let tree = HostedWindow()
        let theirs = ListedWindow(pid: HostedWindow.owner, bounds: CGRect(x: 0, y: 0, width: 740, height: 625))
        let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 100, y: 100, width: 1_000, height: 700))
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [theirs, ours] },
                                               ownProcess: getpid(), refusesOwner: { _ in false }, with: tree)
        guard case .found(let target) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(target.element == tree.text)
        #expect(tree.askedOf == [HostedWindow.owner], "the system-wide hit test was asked with a window of ours beneath")
    }

    /// **An excluded app's window in front of ours is asked nothing** (verifier, 2026-10-19: the descent read an excluded
    /// app's children and frames before the bundle refusal): the owner is known from the compositor before the hit test,
    /// so its application element comes back unread, for the caller to refuse by its bundle identifier. Red if the
    /// refusal moves after the hit test or the descent.
    @Test func anExcludedAppsWindowInFrontOfOursIsAskedNothing() {
        let tree = HostedWindow()
        let theirs = ListedWindow(pid: HostedWindow.owner, bounds: CGRect(x: 0, y: 0, width: 740, height: 625))
        let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 100, y: 100, width: 1_000, height: 700))
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [theirs, ours] },
                                               ownProcess: getpid(), refusesOwner: { $0 == HostedWindow.owner }, with: tree)
        guard case .found(let target) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(target.pid == HostedWindow.owner)
        #expect(tree.askedOf.isEmpty, "the excluded app was hit-tested")
        #expect(tree.attributesAsked == 0, "the excluded app's tree was read: \(tree.attributesAsked) requests")
    }

    /// The control: with no window of ours at the point the system-wide hit test is asked, once, and its element taken as
    /// it is — nothing is descended.
    @Test func withNoWindowOfOursTheSystemWideHitTestIsAsked() {
        let tree = HostedWindow()
        let theirs = ListedWindow(pid: HostedWindow.owner, bounds: CGRect(x: 0, y: 0, width: 740, height: 625))
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [theirs] },
                                               ownProcess: getpid(), refusesOwner: { _ in false }, with: tree)
        guard case .found(let target) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(target.element == tree.text)
        #expect(tree.askedOf == [0])
    }

    /// **A stalled pointer hit test ends at the read's deadline** (decision 6): the hit test is a request of the session,
    /// so one that blocked past the budget is not believed.
    @Test func aStalledPointerHitTestEndsAtItsDeadline() {
        let session = AccessibilitySession(budget: .milliseconds(20), requests: AccessibilityRequests(
            attribute: { _, _ in (.noValue, nil) }, parameterized: { _, _, _ in (.noValue, nil) },
            elementAt: { _, _ in
                Blocking.for(.milliseconds(80))
                return (.success, AXUIElementCreateApplication(4_300_003))
            }))
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                               refusesOwner: { _ in false }, with: session)
        guard case .none(.failed(.deadlineExceeded)) = outcome else { Issue.record("got \(outcome)"); return }
    }

    /// **Without the grant nothing is asked, and nothing prompts** (decision 7): not the compositor, not Accessibility.
    @Test func aTargetWithoutTheGrantAsksNothing() {
        for probe: PermissionProbe in [.declined, .couldNotTell] {
            let client = HitTests(finding: 4_300_004)
            let listed = Mutex(0)
            let outcome = PointerWordReader.target(
                at: point, access: AccessibilityAccess(probe: { probe }),
                windows: { listed.withLock { $0 += 1 }; return [] }, ownProcess: getpid(), refusesOwner: { _ in false },
                with: client)
            guard case .none(.accessibilityOff) = outcome else { Issue.record("got \(outcome)"); continue }
            #expect(client.asked.withLock { $0 } == 0 && listed.withLock { $0 } == 0)
        }
    }

    /// **A hover's target is asked through the lane as hover work**, under the hover messaging timeout.
    @Test func aHoverTargetGoesThroughTheLaneUnderTheHoverTimeout() async {
        let timeouts = Mutex<[Float]>([])
        let lane = AccessibilityLane.patient { timeout in timeouts.withLock { $0.append(timeout) } }
        let source = SystemPointerWords(metrics: Measured.metrics, lane: lane, access: AccessibilityAccess(probe: { .declined }))
        let outcome = await source.target(at: point, windows: { [] }, refusesOwner: { _ in false })
        guard case .none(.accessibilityOff) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(timeouts.withLock { $0 } == [PointerWordReader.messagingTimeout])
    }

    // MARK: - Handed over, and described without its sentence

    /// "cat" in a sentence no diagnostic may carry: x 310…340 in `Glyphs`.
    static let privateSentence = "Quokka sentinel 7741 cat whispers."
    static let sentinel = "Quokka sentinel 7741"

    private func privateHit() throws -> PointerWordReader.Hit {
        let outcome = PointerWordReader.read(at: CGPoint(x: 325, y: 210), in: target, tolerance: Measured.hit,
                                             with: Glyphs(Self.privateSentence, speaksTextRange: true))
        guard case .hit(let hit) = outcome else { throw Unexpected.outcome }
        return hit
    }

    private enum Unexpected: Error { case outcome }

    /// **A pointer hit becomes a captured term with its sentence as an available context** (decision 2): the word's
    /// range in UTF-16, no cut end where the whole text was read, the dialect as the acquisition.
    @Test func aHitIsHandedOverWithItsSentence() throws {
        let hit = try privateHit()
        let pointer = PointerSample(point: DownPoint(x: 325, y: 210), at: nil)
        let term = try hit.capturedTerm(pointer: pointer)
        #expect(term.term == "cat" && term.trigger == .pointerGesture && term.acquisition == .textRange)
        #expect(term.context == .available(sentence: Self.privateSentence, term: NSRange(location: 21, length: 3), cut: [],
                                           gap: nil))
        #expect(term.box == .measured(ReadBounds(rect: DownRect(x: 310, y: 200, width: 30, height: 20), quality: .exact)))
        #expect(term.pointer == pointer)
    }

    /// **No description of a result or its outcome carries the sentence** (decision 9): the observation hooks stringify
    /// outcomes into `events.jsonl`, so a default description would log the reader's text. Every way a value is turned
    /// into text — `String(describing:)`, `debugDescription`, `String(reflecting:)`, `dump` — and the descriptions of the
    /// errors a capture can throw are searched for a sentinel sentence. Red against any default description.
    @Test func noDescriptionOfAResultCarriesItsSentence() throws {
        let hit = try privateHit()
        let term = try hit.capturedTerm(pointer: nil)
        let outcome = PointerWordReader.Outcome.hit(hit)
        var texts: [String] = []
        func describe<T>(_ value: T) {
            texts += [String(describing: value), String(reflecting: value)]
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
        }
        describe(hit)
        describe(outcome)
        describe(hit.word)
        describe(hit.word.sentence)
        describe(term)
        describe(term.context)
        texts += [hit.debugDescription, outcome.debugDescription, term.debugDescription, term.context.debugDescription]
        // The errors: a context the constructor refuses, carrying the sentinel sentence in its input.
        do {
            _ = try CapturedTerm.make(
                term: "cat", trigger: .pointerGesture, acquisition: .textRange, confidence: 1, source: SourceApp(bundleID: nil),
                pointer: nil, box: .absent,
                context: .available(sentence: Self.privateSentence, term: NSRange(location: 0, length: 3), cut: [], gap: nil))
            Issue.record("a range off its term was accepted")
        } catch {
            texts += [String(describing: error), String(reflecting: error), (error as NSError).localizedDescription]
        }
        texts += [String(describing: CaptureError.notResponding), (CaptureError.cancelled as NSError).localizedDescription]
        #expect(texts.count > 20)
        for text in texts { #expect(!text.contains(Self.sentinel), "a description carried the sentence: \(text.prefix(80))") }
        #expect(texts.contains { $0.contains("textRange") }, "the descriptions say nothing at all")
    }
}
