import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **XDict's own window is transparent to hover where it holds no word** (owner, 2026-10-24: "哪怕它与其他窗口重叠或者
/// 当前 frontmost 的时候也不能鼠标取词，这就不对了"; and: a word the screen shows is never answered "no word"). The
/// surface the reader sees is read first — the view's own answer or the controls, then its pixels — and then the first
/// ordinary window of another app behind it, through that app's own Accessibility and then its pixels. Only when every
/// window at the point is wordless is the miss reported; a pixel read that could not run for lack of Screen Recording
/// says so instead.
@MainActor
struct HoverLookThroughTests {
    private static let point = CGPoint(x: 10, y: 10)
    private static let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                           windowID: 3)
    private static let behind = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                             windowID: 5)

    private func reader(
        _ screen: ScriptedPointerWords, ownBundleID: String? = "ai.xdict.app",
        bundleIDOf: @escaping @MainActor (pid_t) -> String? = { _ in "com.apple.TextEdit" },
        policy: HoverPolicy = .shipped
    ) -> HoverReader {
        HoverReader(policy: { policy }, source: screen, contexts: PendingContexts(), ownBundleID: ownBundleID,
                    bundleIDOf: bundleIDOf)
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: Self.point, modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
    }

    /// **A word XDict's own window answers is the answer**: the reader is reading XDict, and the app behind is never asked.
    @Test func aWordInXDictsOwnWindowIsNotPierced() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        let text = "tide and quokka"
        screen.ownView = .webView { max in
            OwnViewText(text: text, offset: 0, cutStart: false, cutEnd: false, maxUTF16: max)
        }
        screen.behindTargetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = .hit(HoverFixtures.hit("safari", bundleID: "com.apple.Safari"))
        guard case .word(let hit, _, _) = await read(reader(screen)) else {
            Issue.record("XDict's own word was not read")
            return
        }
        #expect(hit.word.word == "tide")
        #expect(hit.bundleID == "ai.xdict.app")
        #expect(screen.behindTargets.isEmpty, "the app behind was asked although XDict's window had a word")
        #expect(screen.recognitions == 0)
    }

    /// **No word in XDict's window: its own pixels are read, then the app behind answers through its own Accessibility**
    /// — an app-scoped hit test, proven to answer for a covered window on macOS 27.
    @Test func aWordlessOwnWindowFallsThroughToTheAppBehind() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.ownView = .webView { _ in nil }
        screen.recognition = .failure(.nothingUnderPointer)
        screen.behindTargetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = .hit(HoverFixtures.hit("quokka", bundleID: "com.apple.Safari"))
        guard case .word(let hit, _, _) = await read(reader(screen)) else {
            Issue.record("the app behind XDict's window was not read")
            return
        }
        #expect(hit.word.word == "quokka")
        #expect(hit.bundleID == "com.apple.Safari", "the word did not keep the program it was read in")
        #expect(screen.recognisedWindows == [Self.ours], "XDict's own surface was not read as pixels first")
        #expect(screen.behindTargets == [Self.behind.pid])
        #expect(screen.recognitions == 1, "the app behind was captured although its Accessibility answered")
    }

    /// **An app behind whose Accessibility has no word is read as pixels**, and keeps its own window and owner.
    @Test func anAppBehindWithNoWordIsReadAsPixels() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.ownView = .webView { _ in nil }
        screen.recognitionsByWindow = [
            Self.ours.windowID: .failure(.nothingUnderPointer),
            Self.behind.windowID: .success(RecognitionFixtures.recognition("He paid the fine.")),
        ]
        guard case .recognised(let read, _, _, _) = await read(reader(screen)) else {
            Issue.record("the app behind was not read as pixels")
            return
        }
        #expect(read.word.word == "fine")
        #expect(screen.recognisedWindows == [Self.ours, Self.behind])
        #expect(screen.behindTargets == [Self.behind.pid])
    }

    /// **The reader's exclusions reach the app behind**: Never look up in ▸ an App refuses it before anything is asked.
    @Test func anExcludedAppBehindIsNotRead() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.ownView = .webView { _ in nil }
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("com.acme.secret")
        let refusing = reader(screen, bundleIDOf: { _ in "com.acme.secret" }, policy: policy)
        guard case .quiet(.excludedApp) = await read(refusing) else {
            Issue.record("an excluded app behind XDict's window was read")
            return
        }
        #expect(screen.behindTargets.isEmpty)
        #expect(screen.recognitions == 1, "XDict's own surface should still have been read")
    }

    /// **A secure field in XDict's own window is never pierced**: it is the window's answer at this point, and no app
    /// behind it is asked.
    @Test func aSecureFieldInXDictsOwnWindowIsNotPierced() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.ownTargetOutcome = .found(HoverFixtures.ownTarget())
        screen.readOutcome = .miss(.secure(app: "XDict"))
        guard case .nothing(.miss(.secure)) = await read(reader(screen)) else {
            Issue.record("a secure field was pierced")
            return
        }
        #expect(screen.behindTargets.isEmpty)
        #expect(screen.recognitions == 0)
    }

    /// **A screen-spanning overlay of another app is not the app behind**: Notification Center lists a full-screen
    /// layer-21 window on macOS 27.0.1 and its hit test answers with its menu bar; the ordinary window under it is the
    /// app the reader would see. Red where the overlay is taken for the app behind.
    @Test func aScreenSpanningOverlayIsNotTakenForTheAppBehind() async {
        let screen = ScriptedPointerWords()
        let overlay = ListedWindow(pid: getpid() + 2, bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                                   windowID: 9, layer: 21)
        screen.windows = [overlay, Self.ours, Self.behind]
        screen.ownView = .webView { _ in nil }
        screen.recognition = .failure(.nothingUnderPointer)
        screen.behindTargetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = .hit(HoverFixtures.hit("tide", bundleID: "com.apple.Safari"))
        guard case .word(let hit, _, _) = await read(reader(screen)) else {
            Issue.record("the app behind was not read")
            return
        }
        #expect(hit.bundleID == "com.apple.Safari")
        #expect(screen.behindTargets == [Self.behind.pid], "the overlay was taken for the app behind")
    }

    /// **Screen Only follows the same order with pixels only**: XDict's window, then the app behind, Accessibility never
    /// asked.
    @Test func screenOnlyFallsThroughToTheAppBehindAsPixels() async {
        var policy = HoverPolicy.shipped
        policy.readingMode = .screenOnly
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.recognitionsByWindow = [
            Self.ours.windowID: .failure(.nothingUnderPointer),
            Self.behind.windowID: .success(RecognitionFixtures.recognition("He paid the fine.")),
        ]
        guard case .recognised(let read, _, _, _) = await read(reader(screen, policy: policy)) else {
            Issue.record("Screen Only did not read the app behind")
            return
        }
        #expect(read.word.word == "fine")
        #expect(screen.recognisedWindows == [Self.ours, Self.behind])
        #expect(screen.laneTargets == 0 && screen.behindTargets.isEmpty, "Screen Only asked Accessibility")
    }

    /// **A pixel read that could not run for lack of Screen Recording says so**, rather than "no word" (owner: a word on
    /// screen is never answered "no word").
    @Test func aWindowThatCouldNotBeCapturedAsksForTheGrant() async {
        let screen = ScriptedPointerWords()
        screen.windows = [Self.ours, Self.behind]
        screen.ownView = .webView { _ in nil }
        screen.recognition = .failure(.screenRecordingNeeded)
        guard case .needsScreenRecording = await read(reader(screen)) else {
            Issue.record("a capture that needed the grant was not told so")
            return
        }
    }
}
