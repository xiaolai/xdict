import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **Read text with: Automatic or Screen Only** (owner, 2026-10-19). Automatic is what shipped: Accessibility first, the
/// pixels where it finds no word. Screen Only never asks Accessibility anything — no hit test, no site walk, no text, and
/// none of XDict's own views — and reads the pixels, under every rule the pixels already keep: the app's exclusion by the
/// window's owner, a window that may hold an unnameable page (a known browser's, or one whose owner cannot be named)
/// refused while any site is excluded, the window chosen by the compositor, and the Screen Recording gate.
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

    /// A Screen Only reader whose windows' owners are named by `owner` (the compositor's pid, as the app does by its
    /// running application), with `example.com` excluded.
    private func excludingASite(_ screen: ScriptedPointerWords, owner: @escaping @MainActor (pid_t) -> String?) -> HoverReader {
        let policy = policy(.screenOnly) { $0.excludedHosts = ["example.com"] }
        return HoverReader(policy: { policy }, source: screen, contexts: PendingContexts(),
                           captureDeadline: RecognitionFixtures.patient, bundleIDOf: owner)
    }

    /// **With any site excluded, Screen Only fails closed where a page may be** (verifier, 2026-10-19: refusing every
    /// window silenced hover in every app). A page cannot be named without Accessibility, so a known browser's window is
    /// refused, and so is a window whose owner cannot be named; no pixel is read, nothing is asked of Accessibility.
    @Test func screenOnlyRefusesABrowserOrAnUnnamedOwnerWhileASiteIsExcluded() async {
        for owner: String? in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", nil] {
            let screen = screen(windows: [Self.theirs])
            let outcome = await RecognitionFixtures.read(excludingASite(screen) { _ in owner })
            guard case .quiet(.excludedSite) = outcome else {
                Issue.record("\(owner ?? "an unnamed owner")'s window answered \(outcome) while a site is excluded")
                continue
            }
            #expect(screen.recognitions == 0 && accessibilityAsked(screen) == 0)
        }
    }

    /// **And reads every other app**: a terminal's window is not a page, so a listed site does not silence it.
    @Test func screenOnlyReadsOtherAppsWhileASiteIsExcluded() async {
        let screen = screen(windows: [Self.theirs])
        let outcome = await RecognitionFixtures.read(excludingASite(screen) { _ in "com.mitchellh.ghostty" })
        guard case .recognised(let read, _, _, _) = outcome else {
            Issue.record("a terminal was not read while a site is excluded: \(outcome)")
            return
        }
        #expect(read.word.word == "fine")
        #expect(accessibilityAsked(screen) == 0)
    }

    /// **XDict's own window holds XDict's pages, never a site**: read while a site is listed, whatever is behind it.
    @Test func screenOnlyReadsXDictsOwnWindowWhileASiteIsExcluded() async {
        let screen = screen(windows: [Self.ours, Self.theirs])
        screen.recognition = .success(RecognitionFixtures.recognition("He paid the fine.", bundleID: "ai.xdict.app"))
        let outcome = await RecognitionFixtures.read(excludingASite(screen) { _ in nil })
        guard case .recognised = outcome else {
            Issue.record("XDict's own window was refused while a site is excluded: \(outcome)")
            return
        }
        #expect(screen.recognisedWindows == [Self.ours])
    }

    /// **The window's owner is asked again of the capture itself**: a browser's pixels whose window the compositor's pid
    /// did not name as one (the window changed hands between the list and the capture) are refused, not a word.
    @Test func aBrowsersRecognitionIsRefusedWhileASiteIsExcluded() async {
        let screen = screen(windows: [Self.theirs])
        screen.recognition = .success(RecognitionFixtures.recognition("He paid the fine.", bundleID: "com.apple.Safari"))
        let outcome = await RecognitionFixtures.read(excludingASite(screen) { _ in "com.mitchellh.ghostty" })
        guard case .quiet(.excludedSite) = outcome else {
            Issue.record("a browser's recognised word was delivered while a site is excluded: \(outcome)")
            return
        }
    }

    /// The rule itself: only while a site is listed, only in Screen Only, and only a known browser or no owner at all.
    @Test func thePixelSiteRuleRefusesOnlyBrowsersAndUnnamedOwners() {
        let listing = policy(.screenOnly) { $0.excludedHosts = ["example.com"] }
        #expect(listing.refusesUnnamedPage(in: "com.apple.Safari"))
        #expect(listing.refusesUnnamedPage(in: nil))
        #expect(!listing.refusesUnnamedPage(in: "com.mitchellh.ghostty"))
        #expect(!policy(.screenOnly).refusesUnnamedPage(in: "com.apple.Safari"), "nothing listed, nothing refused")
        #expect(!policy(.screenOnly).refusesUnnamedPage(in: nil))
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
