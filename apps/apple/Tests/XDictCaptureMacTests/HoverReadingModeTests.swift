import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **Read text with: Automatic or Screen Only** (owner, 2026-10-19). Automatic is what shipped: Accessibility first, the
/// pixels where it finds no word. Screen Only never asks Accessibility anything — no hit test, no site walk, no text, and
/// none of XDict's own views — and reads the pixels, under every rule the pixels already keep: the app's exclusion by the
/// window's owner, an unnameable page refused while any site is excluded, the window chosen by the compositor, and the
/// Screen Recording gate.
@MainActor
struct HoverReadingModeTests {
    private static let theirs = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                             windowID: 5)
    private static let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                           windowID: 6)

    private func policy(_ mode: HoverPolicy.ReadingMode, change: (inout HoverPolicy) -> Void = { _ in }) -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.readingMode = mode
        change(&policy)
        return policy
    }

    /// A screen whose Accessibility would answer a word, and whose pixels read another.
    private func screen(windows: [ListedWindow]) -> ScriptedPointerWords {
        let screen = RecognitionFixtures.screen()
        screen.windows = windows
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        return screen
    }

    /// The Accessibility work a hover asked for, every kind: none is the Screen Only promise.
    private func accessibilityAsked(_ screen: ScriptedPointerWords) -> Int {
        screen.laneTargets + screen.reads + screen.ownTargets + screen.ownReads + screen.ownViewChecks
    }

    @Test func screenOnlyReadsThePixelsAndNeverAsksAccessibility() async {
        let screen = screen(windows: [Self.theirs])
        let reader = RecognitionFixtures.reader(screen, policy: policy(.screenOnly))
        guard case .recognised(let read, _, _, _) = await RecognitionFixtures.read(reader) else {
            Issue.record("Screen Only did not read the pixels")
            return
        }
        #expect(read.word.word == "fine")
        #expect(accessibilityAsked(screen) == 0, "Screen Only asked Accessibility")
        #expect(screen.recognisedWindows == [Self.theirs])
    }

    /// **XDict's own window too**: its pixels, never its views or Accessibility.
    @Test func screenOnlyReadsXDictsOwnWindowAsPixels() async {
        let screen = screen(windows: [Self.ours, Self.theirs])
        let reader = RecognitionFixtures.reader(screen, policy: policy(.screenOnly))
        guard case .recognised = await RecognitionFixtures.read(reader) else {
            Issue.record("Screen Only did not read XDict's own window")
            return
        }
        #expect(accessibilityAsked(screen) == 0, "Screen Only asked Accessibility or a view of XDict's")
        #expect(screen.recognisedWindows == [Self.ours], "a window behind XDict's was read")
    }

    /// **Automatic is unchanged**: Accessibility's word, and no pixel read.
    @Test func automaticAsksAccessibilityFirst() async {
        let screen = screen(windows: [Self.theirs])
        let reader = RecognitionFixtures.reader(screen, policy: policy(.automatic))
        guard case .word = await RecognitionFixtures.read(reader) else {
            Issue.record("Automatic did not answer with Accessibility's word")
            return
        }
        #expect(screen.recognitions == 0)
        #expect(screen.laneTargets == 1)
    }

    /// With any site excluded, a page cannot be named without Accessibility: Screen Only refuses, as the pixel path does
    /// for an element it cannot name.
    @Test func screenOnlyRefusesWhileAnySiteIsExcluded() async {
        let screen = screen(windows: [Self.theirs])
        let reader = RecognitionFixtures.reader(screen, policy: policy(.screenOnly) { $0.excludedHosts = ["example.com"] })
        guard case .quiet(.excludedSite) = await RecognitionFixtures.read(reader) else {
            Issue.record("a page was read as pixels while a site is excluded")
            return
        }
        #expect(screen.recognitions == 0 && accessibilityAsked(screen) == 0)
    }

    /// XDict excluded by the reader: its own window is not read in Screen Only either.
    @Test func screenOnlyKeepsXDictsOwnExclusion() async {
        let screen = screen(windows: [Self.ours])
        let reader = HoverReader(policy: { self.policy(.screenOnly) { $0.excludedApps.insert("ai.xdict.app") } },
                                 source: screen, contexts: PendingContexts(), captureDeadline: RecognitionFixtures.patient,
                                 ownBundleID: "ai.xdict.app")
        guard case .quiet(.excludedApp) = await RecognitionFixtures.read(reader) else {
            Issue.record("XDict's own window was read with XDict excluded")
            return
        }
        #expect(screen.recognitions == 0)
    }

    /// Without Screen Recording, Screen Only says so — the notice the pixel path already gives — and asks nothing else.
    @Test func screenOnlyWithoutScreenRecordingSaysSo() async {
        let screen = screen(windows: [Self.theirs])
        screen.recognition = .failure(.screenRecordingNeeded)
        let reader = RecognitionFixtures.reader(screen, policy: policy(.screenOnly))
        guard case .needsScreenRecording = await RecognitionFixtures.read(reader) else {
            Issue.record("Screen Only without the grant did not say it needs Screen Recording")
            return
        }
        #expect(accessibilityAsked(screen) == 0)
    }
}
