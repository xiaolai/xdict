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

    /// **XDict's own window, listed by the compositor at the point, is refused on the main actor before the lane is asked**
    /// (WI-3 verification; XiaolaiDict ADR-0042): here the lane would answer another app's target and a word, and still
    /// nothing is read. Red without the compositor check in `read`.
    @Test func ourListedWindowIsRefusedBeforeTheLaneIsAsked() async {
        let screen = ScriptedPointerWords()
        screen.windows = [ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100))]
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        guard case .quiet(.samePlace) = await read(reader(screen)) else {
            Issue.record("XDict's own listed window was not refused first")
            return
        }
        #expect(screen.reads == 0)
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

    /// **The pointer over XDict's own window reads nothing** — no target is resolved for it and no text read.
    @Test func ourOwnWindowIsRefusedWithoutReading() async {
        let screen = ScriptedPointerWords()
        screen.targetOutcome = .ourOwnWindow
        guard case .quiet(.samePlace) = await read(reader(screen)) else {
            Issue.record("XDict's own window was not refused")
            return
        }
        #expect(screen.reads == 0)
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
