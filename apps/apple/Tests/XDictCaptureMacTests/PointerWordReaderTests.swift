import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
import XDictCaptureMac

/// **The pointer's word in each dialect, who owns the pixel, and what a hit says about itself** (plan-capture WI-2;
/// XDict ADR-0014 decisions 2, 6, 7 and 9). Scripted trees only: the text range and the bounds scan through `Glyphs`,
/// the text markers through `WebPage`; the hit test through `HitTests`. No window, no real Accessibility request.
struct PointerWordReaderTests {
    // MARK: - The text-marker dialect

    /// WebKit's page: "The cat sat." with "cat" at x 140…170, y 200…220, answered through markers only.
    final class WebPage: AccessibilityReading {
        static let sentence = "The cat sat."
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
                case 4: return Self.sentence as CFString
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

    /// **One of XDict's own floating windows under the pointer is refused before the hit test** (XiaolaiDict ADR-0042):
    /// the hit test itself would be serviced in this process, on this thread, off the main actor. Every window level
    /// counts — the panel floats. Red if the compositor's list is asked after Accessibility, or only at level 0.
    @Test func anOwnProcessFloatingWindowIsRefusedBeforeTheHitTest() {
        let client = HitTests(finding: 4_300_001)
        let panel = ListedWindow(pid: getpid(), bounds: CGRect(x: 250, y: 250, width: 200, height: 200), layer: 3)
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [panel] },
                                               ownProcess: getpid(), with: client)
        guard case .ourOwnWindow = outcome else { Issue.record("got \(outcome)"); return }
        #expect(client.asked.withLock { $0 } == 0, "Accessibility was asked about XDict's own window")
    }

    /// **And a window of ours that arrived after the list was taken is still refused**, by the owner of what the hit test
    /// found — late, but caught. The control: another app's window is found.
    @Test func anOwnWindowMissingFromTheListIsRefusedByItsOwner() {
        let ours = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                            with: HitTests(finding: getpid()))
        guard case .ourOwnWindow = ours else { Issue.record("got \(ours)"); return }
        let theirs = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                              with: HitTests(finding: 4_300_002))
        guard case .found(let target) = theirs else { Issue.record("got \(theirs)"); return }
        #expect(target.pid == 4_300_002)
    }

    /// **A stalled pointer hit test ends at the read's deadline** (decision 6): the hit test is a request of the session,
    /// so one that blocked past the budget is not believed.
    @Test func aStalledPointerHitTestEndsAtItsDeadline() {
        let session = AccessibilitySession(budget: .milliseconds(20), requests: AccessibilityRequests(
            attribute: { _, _ in (.noValue, nil) }, parameterized: { _, _, _ in (.noValue, nil) },
            elementAt: { _, _ in
                Thread.sleep(forTimeInterval: 0.08)
                return (.success, AXUIElementCreateApplication(4_300_003))
            }))
        let outcome = PointerWordReader.target(at: point, access: Self.granted, windows: { [] }, ownProcess: getpid(),
                                               with: session)
        guard case .none(.failed(.deadlineExceeded)) = outcome else { Issue.record("got \(outcome)"); return }
    }

    /// **Without the grant nothing is asked, and nothing prompts** (decision 7): not the compositor, not Accessibility.
    @Test func aTargetWithoutTheGrantAsksNothing() {
        for probe: PermissionProbe in [.declined, .couldNotTell] {
            let client = HitTests(finding: 4_300_004)
            let listed = Mutex(0)
            let outcome = PointerWordReader.target(
                at: point, access: AccessibilityAccess(probe: { probe }),
                windows: { listed.withLock { $0 += 1 }; return [] }, ownProcess: getpid(), with: client)
            guard case .none(.accessibilityOff) = outcome else { Issue.record("got \(outcome)"); continue }
            #expect(client.asked.withLock { $0 } == 0 && listed.withLock { $0 } == 0)
        }
    }

    /// **A hover's target is asked through the lane as hover work**, under the hover messaging timeout.
    @Test func aHoverTargetGoesThroughTheLaneUnderTheHoverTimeout() async {
        let timeouts = Mutex<[Float]>([])
        let lane = AccessibilityLane { timeout in timeouts.withLock { $0.append(timeout) } }
        let source = SystemPointerWords(tolerance: Measured.hit, lane: lane, access: AccessibilityAccess(probe: { .declined }))
        let outcome = await source.target(at: point, windows: { [] })
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
