import AppKit
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **XDict's own web views are read by the view itself, never through Accessibility** (verifier, 2026-10-19). A
/// main-thread Accessibility hit test over XDict's own WKWebView waits on WebKit, which waits on the main thread: 1,530 ms
/// on the build Mac, then -25204. The entry's own script answered the same word in 1–10 ms, the main loop never held more
/// than 6 ms. So where the view under the point — found by window and view geometry on the main actor — is a web view,
/// its own reading is asked, bounded by the hover budget and `CaptureLimits`, and checked before use; a web view nothing
/// reads is asked nothing. Only XDict's native controls go to Accessibility.
@MainActor
struct OwnViewRouteTests {
    private static let point = CGPoint(x: 325, y: 210)
    private static let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                                           windowID: 3)
    private static let sentence = "Quokka hover probe. Second sentence here."

    private func reader(_ screen: ScriptedPointerWords, budget: Duration = PointerWordReader.budget,
                        policy: HoverPolicy = .shipped) -> HoverReader {
        screen.windows = [Self.ours]
        return HoverReader(policy: { policy }, source: screen, budget: budget, contexts: PendingContexts(),
                           ownBundleID: "ai.xdict.app")
    }

    private func hover(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: Self.point, modifiersHeld: [.option], tappedTwice: false, pointerStillFor: .seconds(1),
                          begin: { CaptureRequest(number: 5, trigger: .pointerGesture) })
    }

    /// **Over XDict's entry, the entry answers**: the word and its sentence from the view's own reading, asked for at most
    /// `CaptureLimits.contextUTF16` units; no hit test and no read through Accessibility, on the main actor or the lane.
    /// Red where an own web view is hit-tested through Accessibility.
    @Test func ourEntryIsReadByItsOwnViewNeverByAccessibility() async {
        let screen = ScriptedPointerWords()
        let asked = Mutex<[Int]>([])
        screen.ownView = .webView({ max in
            asked.withLock { $0.append(max) }
            return OwnViewText(text: Self.sentence, offset: 0, cutStart: false, cutEnd: true, maxUTF16: max)
        })
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        let outcome = await hover(reader(screen))
        guard case .word(let hit, _, _) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(hit.word.word == "Quokka")
        #expect(hit.word.sentence.text == "Quokka hover probe.")
        #expect(hit.acquisition == .ownView && hit.bundleID == "ai.xdict.app" && hit.bounds == nil)
        #expect(screen.ownTargets == 0 && screen.ownReads == 0, "XDict's own web view was asked through Accessibility")
        #expect(screen.laneTargets == 0 && screen.reads == 0)
        #expect(asked.withLock { $0 } == [CaptureLimits.shipped.contextUTF16])
    }

    /// **A web view of XDict's that nothing reads is read as pixels, never through Accessibility** (owner, 2026-10-24: a
    /// word on screen is never answered "no word"); the hover notice comes only after that. Red where it falls back to
    /// the Accessibility hit test that waits on WebKit.
    @Test func aWebViewNothingReadsIsReadAsItsOwnPixels() async {
        let screen = ScriptedPointerWords()
        screen.ownView = .webView(nil)
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        let outcome = await hover(reader(screen))
        guard case .nothing(.miss(.noText)) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(screen.ownTargets == 0 && screen.ownReads == 0)
        #expect(screen.recognitions == 1 && screen.recognisedWindows == [Self.ours])
    }

    /// **A view that does not answer is given up at the hover budget**, as past its deadline. Red where the own view's
    /// reading is awaited without a bound. The view answers only once the outcome is in, so no clock decides it
    /// (2026-10-20: a 4 s bound against a 5 s view was the scheduler's under load, not the reader's).
    @Test func aViewThatDoesNotAnswerIsGivenUpAtTheBudget() async {
        let screen = ScriptedPointerWords()
        let silence = Silence()
        screen.ownView = .webView({ _ in
            await silence.wait()
            return nil
        })
        let silent = reader(screen, budget: .milliseconds(100))
        let outcome = await Wait.value(of: Task { await hover(silent) })
        silence.open()
        guard case .nothing(.miss(.failed(.deadlineExceeded, _)))? = outcome else {
            Issue.record("a view that does not answer gave \(String(describing: outcome))")
            return
        }
    }

    /// **Off a word, the view answers nothing and nothing is read**. Red where an empty answer goes on to Accessibility.
    @Test func noWordInTheViewIsAMiss() async {
        let screen = ScriptedPointerWords()
        screen.ownView = .webView({ _ in nil })
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        let outcome = await hover(reader(screen))
        guard case .nothing(.miss(.noText)) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(screen.ownTargets == 0 && screen.ownReads == 0)
    }

    /// **XDict's native controls are still Accessibility's**, on the main actor. Red where the view check swallows them.
    @Test func ourControlsAreReadThroughAccessibility() async {
        let screen = ScriptedPointerWords()
        screen.ownView = .controls
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("Dictionaries", bundleID: "ai.xdict.app"))
        let outcome = await hover(reader(screen))
        guard case .word(let hit, _, _) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(hit.word.word == "Dictionaries")
        #expect(screen.ownTargets == 1 && screen.ownReads == 1)
    }

    /// **XDict excluded: not even the view is looked at.** Red where the view check comes before the refusal.
    @Test func anExcludedXDictLooksAtNoView() async {
        let screen = ScriptedPointerWords()
        screen.ownView = .webView({ _ in OwnViewText(text: "word", offset: 0, cutStart: false, cutEnd: false, maxUTF16: 9) })
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("ai.xdict.app")
        let outcome = await hover(reader(screen, policy: policy))
        guard case .quiet(.excludedApp) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(screen.ownViewChecks == 0)
    }

    /// **The view's answer is data, checked before use**: empty text, text past the bound asked for, and an offset outside
    /// the text are refused; the cut ends come through.
    @Test func aViewsAnswerIsCheckedBeforeUse() throws {
        #expect(OwnViewText(text: "", offset: 0, cutStart: false, cutEnd: false, maxUTF16: 10) == nil)
        #expect(OwnViewText(text: "eleven char", offset: 0, cutStart: false, cutEnd: false, maxUTF16: 10) == nil)
        #expect(OwnViewText(text: "word", offset: 4, cutStart: false, cutEnd: false, maxUTF16: 10) == nil)
        #expect(OwnViewText(text: "word", offset: -1, cutStart: false, cutEnd: false, maxUTF16: 10) == nil)
        #expect(OwnViewText(text: "word", offset: 0, cutStart: false, cutEnd: false, maxUTF16: 0) == nil)
        let cut = try #require(OwnViewText(text: "a word", offset: 2, cutStart: true, cutEnd: false, maxUTF16: 10))
        #expect(cut.cut == [.start])
        #expect(cut.word?.word == "word")
    }

    // MARK: - Which view is under the point, by geometry

    /// Stands in for a web view: the finder is told what a web view is, so no WebKit is needed here.
    final class StandInWebView: NSView {
        var drawsFromTop = true
        override var isFlipped: Bool { drawsFromTop }
    }

    /// A borderless window at (100, 100) on a 1,000-point-tall primary screen: a 400 × 300 content view whose top 200
    /// points are a stand-in web view (with a subview of its own, as WebKit's are), the rest a plain control.
    private func window(webFlipped: Bool = true) -> (NSWindow, StandInWebView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let web = StandInWebView(frame: CGRect(x: 0, y: 100, width: 400, height: 200))
        web.drawsFromTop = webFlipped
        web.addSubview(NSView(frame: web.bounds))
        content.addSubview(web)
        content.addSubview(NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 100)))
        window.contentView = content
        return (window, web)
    }

    /// **A point over the web view is the web view's**, at the point in its own space, y down from its top, whichever
    /// way the view is flipped: 30 points in and 50 down. Red where the finder answers controls over a web view, or hands
    /// the reading the wrong view or point.
    @Test func aPointOverAWebViewIsTheWebViews() {
        for flipped in [true, false] {
            let (window, web) = window(webFlipped: flipped)
            var handed: (NSView, CGPoint)?
            // y down: the window's top is 1,000 - 400 = 600; 50 points below it.
            let found = OwnViews.view(at: CGPoint(x: 130, y: 650), in: window, primaryHeight: 1_000,
                                      isWebView: { $0 is StandInWebView },
                                      reading: { view, point in
                                          handed = (view, point)
                                          return { _ in nil }
                                      })
            guard case .webView(.some) = found else {
                Issue.record("flipped \(flipped): got \(found)")
                continue
            }
            #expect(handed?.0 === web)
            #expect(handed?.1 == CGPoint(x: 30, y: 50), "flipped \(flipped): \(String(describing: handed?.1))")
        }
    }

    /// **A point over a control is Accessibility's**, and nothing is handed to a reading. Red where every point of a
    /// window with a web view is taken for the web view's.
    @Test func aPointOverAControlIsAccessibilitys() {
        let (window, _) = window()
        var handed = false
        let found = OwnViews.view(at: CGPoint(x: 130, y: 850), in: window, primaryHeight: 1_000,
                                  isWebView: { $0 is StandInWebView },
                                  reading: { _, _ in
                                      handed = true
                                      return nil
                                  })
        guard case .controls = found else {
            Issue.record("got \(found)")
            return
        }
        #expect(!handed)
    }

    /// **A web view no reading serves is still a web view**: answered with no reading, so it is asked nothing.
    @Test func aWebViewNoReadingServesIsStillAWebView() {
        let (window, _) = window()
        let found = OwnViews.view(at: CGPoint(x: 130, y: 650), in: window, primaryHeight: 1_000,
                                  isWebView: { $0 is StandInWebView }, reading: { _, _ in nil })
        guard case .webView(nil) = found else {
            Issue.record("got \(found)")
            return
        }
    }
}
