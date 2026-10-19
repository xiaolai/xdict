import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// The reader's half: what it reads, given a screen (XiaolaiDict's `HoverReaderSourceTests` and `HoverSiteTests`, moved
/// by name in plan-capture WI-3; the recogniser's cases wait for WI-4). Every read of text goes through the source's one
/// combined job, `readUnlessRefused` (WI-2).
@MainActor
struct HoverReaderSourceTests {
    private func reader(_ screen: ScriptedPointerWords, scripts: Set<CaptureScript>? = [.latin]) -> HoverReader {
        var policy = HoverPolicy.shipped
        policy.allowedScripts = scripts
        return HoverReader(policy: { policy }, source: screen, contexts: PendingContexts())
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { CaptureRequest(number: 7, trigger: .pointerGesture) })
    }

    /// **The hover path asks whether the script is allowed** — by behaviour: a Han word read through Accessibility is
    /// refused where the consumer allowed Latin only, and a Latin word is not (renamed from `aWordInAScriptNotStudiedIsRefused`:
    /// the scripts are the consumer's, not a study setting, ADR-0014 d.10).
    @Test func aWordInAScriptNotAllowedIsRefused() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .hit(HoverFixtures.hit("学习"))
        guard case .quiet(.scriptNotAllowed) = await read(reader(screen)) else {
            Issue.record("a word outside the allowed scripts was not refused")
            return
        }
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        guard case .word(let hit, let request, _) = await read(reader(screen)) else {
            Issue.record("a Latin word was refused")
            return
        }
        #expect(hit.word.word == "tide")
        #expect(request.number == 7, "the word did not carry the request it was read for")
    }

    /// **Remembered on delivery, not on reading.** Reading twice without delivering is two words; after `remember`, the
    /// same word at the same place is `.samePlace`.
    @Test func aWordIsSuppressedOnlyOnceRemembered() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        let reader = reader(screen)
        guard case .word(_, _, let key) = await read(reader) else {
            Issue.record("no word")
            return
        }
        guard case .word = await read(reader) else {
            Issue.record("a word that was never delivered was suppressed")
            return
        }
        reader.remember(key)
        guard case .quiet(.samePlace) = await read(reader) else {
            Issue.record("a delivered word was not suppressed")
            return
        }
    }

    /// **An excluded app is refused before its text is read**, by the owner Accessibility named.
    @Test func anExcludedAppIsRefusedBeforeItsTextIsRead() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target(bundleID: "com.agilebits.onepassword7"))
        screen.readOutcome = .hit(HoverFixtures.hit("secret"))
        guard case .quiet(.excludedApp) = await read(reader(screen)) else {
            Issue.record("a password manager was read")
            return
        }
        #expect(screen.reads == 0)
    }

    /// **XDict's own window, listed by the compositor in front at the point, is read on the main actor and never through
    /// the lane** (owner, 2026-10-19: hover works in XDict's own windows; XiaolaiDict ADR-0042's hazard is a request about
    /// this process made off the main thread). The lane would answer another app's target; it is not asked, and the word
    /// comes from XDict's own application. Red if the own window is refused (the rule before), or read through the lane.
    @Test func ourListedWindowIsReadOnTheMainActorAndNeverThroughTheLane() async {
        let screen = ScriptedPointerWords()
        screen.windows = [ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 3)]
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("tide", bundleID: "ai.xdict.app"))
        guard case .word(let hit, let request, _) = await read(reader(screen)) else {
            Issue.record("a word in XDict's own window was not read")
            return
        }
        #expect(hit.word.word == "tide")
        #expect(request.number == 7)
        #expect(screen.laneTargets == 0 && screen.reads == 0, "XDict's own window was asked about through the lane")
        #expect(screen.ownTargets == 1 && screen.ownReads == 1)
        #expect(screen.ownWorkOffTheMainThread == 0)
    }

    /// **An own window the lane's hit test found after the list was taken is read on the main actor too**: the lane
    /// answers `ownWindow`, and the main actor asks XDict's own application again and reads it there. Red if the read
    /// goes through the lane, or the hover is refused.
    @Test func anOwnWindowTheLaneFoundLateIsReadOnTheMainActor() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .ownWindow
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("tide", bundleID: "ai.xdict.app"))
        guard case .word = await read(reader(screen)) else {
            Issue.record("a late own window was not read")
            return
        }
        #expect(screen.reads == 0, "the own window's text was read through the lane")
        #expect(screen.ownTargets == 1 && screen.ownReads == 1)
    }

    /// **A target in this process is read on the main actor whichever hit test found it** — by its process, as
    /// `AXUIElementGetPid` names it: here the lane's own answer is an element of XDict's. Red if the read is routed by
    /// the compositor's list alone.
    @Test func aTargetInThisProcessIsReadOnTheMainActorByItsPid() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("tide", bundleID: "ai.xdict.app"))
        guard case .word = await read(reader(screen)) else {
            Issue.record("an element of XDict's was not read")
            return
        }
        #expect(screen.reads == 0 && screen.ownReads == 1)
    }

    /// **XDict's own reads keep every exclusion** (owner, 2026-10-19: no separate toggle; "Never look up in" is the
    /// option): XDict is readable by default — the shipped list never holds it — and where the reader adds it, it is
    /// refused by the same bundle-identifier rule as any app, **before any element of XDict's is asked for**; taken off
    /// the list, it is read again. An excluded site inside one of XDict's windows is refused in the same combined read.
    /// Red if the own-window path skips the refusal until after its hit test.
    @Test func ourOwnReadsKeepTheAppAndSiteExclusions() async {
        #expect(!HoverPolicy.shipped.excludes(app: "ai.xdict.app"), "the shipped list excludes XDict itself")
        let screen = ScriptedPointerWords()
        screen.windows = [ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100))]
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .hit(HoverFixtures.hit("secret", bundleID: "ai.xdict.app"))
        var excludingXDict = HoverPolicy.shipped
        excludingXDict.excludedApps.insert("ai.xdict.app")
        final class Stored { var policy = HoverPolicy.shipped }
        let stored = Stored()
        stored.policy = excludingXDict
        let reader = HoverReader(policy: { stored.policy }, source: screen, contexts: PendingContexts(),
                                 ownBundleID: "ai.xdict.app")
        guard case .quiet(.excludedApp) = await read(reader) else {
            Issue.record("XDict was read where the reader excluded it")
            return
        }
        #expect(screen.ownTargets == 0 && screen.ownReads == 0, "an element of XDict's was asked for before the refusal")
        // Taken off the list, XDict's windows are read again.
        stored.policy = .shipped
        guard case .word = await read(reader) else {
            Issue.record("XDict stayed refused after the reader took it off the list")
            return
        }
        let textReadsBefore = screen.textReads
        var excludingSite = HoverPolicy.shipped
        excludingSite.excludedHosts = ["example.com"]
        screen.hostReading = .known("bank.example.com")
        let refusingSite = HoverReader(policy: { excludingSite }, source: screen, contexts: PendingContexts())
        guard case .quiet(.excludedSite) = await read(refusingSite) else {
            Issue.record("an excluded site in XDict's own window was read")
            return
        }
        #expect(screen.textReads == textReadsBefore)
    }

    /// **The hover notice is no target, for Accessibility or the pixels** — a click-through panel of XDict's carries no
    /// reader text: dropped from the compositor's list by its window, so the window under it is the one asked and
    /// captured. Red if it is routed as XDict's own window (the main actor asked, nothing found), or captured.
    @Test func theHoverNoticeIsNoCaptureTarget() async {
        let screen = ScriptedPointerWords()
        let notice = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 9, layer: 3)
        let theirs = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)
        screen.windows = [notice, theirs]
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .miss(.noText(app: "TextEdit", role: nil))
        let reader = HoverReader(policy: { .shipped }, source: screen, contexts: PendingContexts(),
                                 passesClicksThrough: { $0 == 9 })
        _ = await read(reader)
        #expect(screen.ownTargets == 0, "the notice was taken for a window of XDict's to read")
        #expect(screen.laneTargets == 1)
        #expect(screen.recognisedWindows == [theirs], "the pixels read were not the window under the notice")
    }

    /// **Another app's window in front of ours is read** (owner's report, 2026-10-19): XDict's window listed beneath
    /// System Settings no longer silences the hover there. Red under the old any-depth rule.
    @Test func anotherAppsWindowInFrontOfOursIsRead() async {
        let screen = ScriptedPointerWords()
        screen.windows = [ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                          ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100))]
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        guard case .word(let hit, _, _) = await read(reader(screen)) else {
            Issue.record("the window in front of XDict's was not read")
            return
        }
        #expect(hit.word.word == "tide")
    }

    /// **The gate is handed the keys actually held** (WI-3 verification, G1): under the hold gesture with nothing held,
    /// the read is refused at the gate and nothing is asked of the screen. Red if the reader tells the gate the key is
    /// always down.
    @Test func aHoverWithTheKeyUpIsRefusedAtTheGate() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        let outcome = await reader(screen).read(
            at: CGPoint(x: 10, y: 10), modifiersHeld: [], tappedTwice: false, pointerStillFor: .seconds(1),
            begin: { CaptureRequest(number: 7, trigger: .pointerGesture) })
        guard case .quiet(.modifierNotHeld) = outcome else {
            Issue.record("a hover with the key up answered \(outcome)")
            return
        }
        #expect(screen.reads == 0)
    }

    /// **Nothing at the point in XDict's own window: the pixels of XDict's window there**, never the window behind it —
    /// the compositor named XDict's window as the one in front, so it is the owner the capture reads. Red if the capture
    /// falls back to the frontmost ordinary window of another app.
    @Test func ourOwnWindowWithNoElementReadsItsOwnPixels() async {
        let screen = ScriptedPointerWords()
        let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 3, layer: 3)
        let behind = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)
        screen.windows = [ours, behind]
        screen.ownTargetOutcome = .none(.nothingAtPointer)
        _ = await read(reader(screen))
        #expect(screen.recognisedWindows == [ours])
        #expect(screen.laneTargets == 0)
    }
}

/// The reader names the site before it reads (XiaolaiDict's `HoverSiteTests`, moved by name).
@MainActor
struct HoverSiteTests {
    private func reader(_ screen: ScriptedPointerWords, sites: Set<String>) -> HoverReader {
        var policy = HoverPolicy.shipped
        policy.excludedHosts = sites
        return HoverReader(policy: { policy }, source: screen, contexts: PendingContexts())
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
    }

    /// **An excluded site is refused before its text is read** — inside the one job, so the page cannot navigate between
    /// the check and the read. The scripted page would answer a word; the refusal comes first. Red if the reader reads
    /// the text any other way than through `readUnlessRefused` with the reader's own policy.
    @Test func anExcludedSiteIsRefusedBeforeItsTextIsRead() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = .hit(HoverFixtures.hit("secret"))
        screen.hostReading = .known("bank.example.com")
        guard case .quiet(.excludedSite) = await read(reader(screen, sites: ["example.com"])) else {
            Issue.record("an excluded site was read")
            return
        }
        #expect(screen.textReads == 0)
    }

    /// **An unreadable site is refused while the list has anything in it** — fail-closed, from the source's answer.
    @Test func anUnreadableSiteIsRefusedWhileSitesAreExcluded() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = .hit(HoverFixtures.hit("secret"))
        screen.hostReading = .unreadable
        guard case .quiet(.excludedSite) = await read(reader(screen, sites: ["example.com"])) else {
            Issue.record("an unnameable page was read")
            return
        }
        #expect(screen.textReads == 0)
    }
}

/// **A stuck lane says so** (ADR-0014 decision 6; the "capture stuck" notice, plan-capture WI-3): a call blocked in the
/// framework cannot be cancelled, and the reader is told — once per wedge — and told again when the lane answers.
@MainActor
struct HoverLaneHealthTests {
    @Test func aStuckLaneIsReportedOnceAndClearedWhenItAnswers() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .miss(.failed(.notResponding, app: "TextEdit"))
        let reader = HoverReader(policy: { .shipped }, source: screen, contexts: PendingContexts())
        var health: [CaptureHealth] = []
        reader.onCaptureHealth = { health.append($0) }
        func read() async -> HoverReader.Outcome {
            await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                              pointerStillFor: .seconds(1), begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
        }
        _ = await read()
        #expect(health.isEmpty, "a lane that answered was reported")
        screen.lane = .stuck(.explicit, blockedFor: .seconds(3))
        _ = await read()
        _ = await read()
        #expect(health == [.stuck(for: .seconds(3))], "the wedge was reported \(health.count) times")
        screen.lane = .idle
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        _ = await read()
        #expect(health == [.stuck(for: .seconds(3)), .answering], "the lane answered and nobody was told")
    }
}
