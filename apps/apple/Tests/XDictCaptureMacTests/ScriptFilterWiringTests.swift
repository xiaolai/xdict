import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The hover reader's half of XiaolaiDict's `ScriptFilterWiringTests`** (moved by name from its `HoverAuditTests.swift`
/// at `044dac6`; capture-migration manifest §7.2): the suppression key and the hover's end. The shortcut's half and the
/// defaults suite are `XDictTests`' (`ScriptFilterWiringTests` there); the ledger's and the drawer's are not moved —
/// XDict has neither (`XDictCaptureMac/PROVENANCE.md`).
@MainActor
struct ScriptFilterWiringTests {
    /// **Two apps showing the same word at the same place are two hovers.** The suppression key was the word and an
    /// 8-point cell and nothing else, so resting on `run` in a terminal and then on `run` at the same screen position in
    /// a browser looked like the same lookup, and the second was silently dropped.
    @Test func theSuppressionKeyTellsTwoAppsApart() {
        let point = CGPoint(x: 100, y: 200)
        let terminal = HoverReader.key(bundleID: "com.apple.Terminal", sentence: "run", word: "run", at: point)
        let browser = HoverReader.key(bundleID: "com.apple.Safari", sentence: "run", word: "run", at: point)
        #expect(terminal != browser)
        #expect(terminal == HoverReader.key(bundleID: "com.apple.Terminal", sentence: "run", word: "run", at: point))
    }

    /// **Letting go of the key ends the hover, so the next one may repeat the word.** Suppression was only ever cleared by
    /// a *different* successful lookup, so a reader who looked a word up, released the key and reached for the same word
    /// again got nothing. Safe to drive directly: with no key held the gate refuses before any Accessibility or capture
    /// work.
    @Test func releasingTheModifierClearsTheSuppressedWord() async {
        let reader = HoverReader(policy: { .shipped }, source: ScriptedPointerWords(), contexts: PendingContexts(),
                                 captureDeadline: RecognitionFixtures.patient)
        reader.lastLookedUp = "run@12x25"
        let outcome = await reader.read(
            at: CGPoint(x: 100, y: 200), modifiersHeld: [], tappedTwice: false, pointerStillFor: .seconds(1),
            begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
        guard case .quiet(.modifierNotHeld) = outcome else {
            Issue.record("expected the key gate to refuse, got \(outcome)")
            return
        }
        #expect(reader.lastLookedUp == nil, "the word stayed suppressed after the hover ended")
    }
}
