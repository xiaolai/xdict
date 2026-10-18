import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **Hover's pixel path: Accessibility first, the recogniser where it finds no word, one capture at a time** (plan-capture
/// WI-4; XDict ADR-0014 decisions 6 to 8). XiaolaiDict's `HoverCaptureTargetTests`, `HoverCaptureReleaseTests`,
/// `CaptureWedgeTests`, `HoverPendingContextTests`, `withoutAnElementThePixelsAreNotReadWhileSitesAreExcluded` and
/// `aRefusedCaptureAsksTheReaderNotTheSystem` moved by name, against a scripted screen.
enum RecognitionFixtures {
    static let window = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)
    /// How long a test lets a capture run: long enough never to be the reason a test passes.
    static let patient: Duration = .seconds(30)

    static func recognition(_ sentence: String, word: String = "fine", cut: Bool = false,
                            bundleID: String = "com.mitchellh.ghostty") -> Recognition {
        let range = (sentence as NSString).range(of: word)
        guard let context = SentenceContext(text: sentence, mayBeCut: cut, selection: range, cut: cut ? .end : []) else {
            preconditionFailure("a sentence")
        }
        return Recognition(word: WordAtPoint(word: word, sentence: context), confidence: 0.9, mayBeCut: cut,
                           appName: "Ghostty", bundleID: bundleID, gap: nil)
    }

    /// A screen whose Accessibility names nothing and whose pixels read `recognition`.
    static func screen(_ recognition: Recognition? = nil) -> ScriptedPointerWords {
        let screen = ScriptedPointerWords()
        screen.windows = [window]
        screen.recognition = .success(recognition ?? Self.recognition("He paid the fine."))
        return screen
    }

    @MainActor
    static func reader(
        _ screen: ScriptedPointerWords, policy: HoverPolicy = .shipped, deadline: Duration = patient,
        contexts: PendingContexts = PendingContexts(), capturing: CaptureGuard = CaptureGuard()
    ) -> HoverReader {
        HoverReader(policy: { policy }, source: screen, contexts: contexts, captureDeadline: deadline, capturing: capturing)
    }

    @MainActor
    static func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { CaptureRequest(number: 1, trigger: .pointerGesture) })
    }
}

/// A taller strip's read, held until the test opens it — and whether it was given up on.
final class GrowthGate: Sendable {
    private let state = Mutex((waiting: false, open: false, cancelled: false))
    var isWaiting: Bool { state.withLock { $0.waiting } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }
    func open() { state.withLock { $0.open = true } }

    func held() async {
        state.withLock { $0.waiting = true }
        while !state.withLock({ $0.open }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        if Task.isCancelled { state.withLock { $0.cancelled = true } }
    }
}

@MainActor
struct HoverRecognitionTests {
    /// **Accessibility first**: a word it reads is the answer and no pixel is read; where it finds none, the recogniser is
    /// asked. Red if the order is reversed or the fallback is missing.
    @Test func theRecogniserIsAskedOnlyWhereAccessibilityFindsNoWord() async {
        let screen = RecognitionFixtures.screen()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.windows = [ListedWindow(pid: HoverFixtures.target().pid, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                       windowID: 9)]
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        let reader = RecognitionFixtures.reader(screen)
        guard case .word = await RecognitionFixtures.read(reader) else {
            Issue.record("Accessibility's word was not the answer")
            return
        }
        #expect(screen.recognitions == 0, "the pixels were read where Accessibility answered")
        screen.readOutcome = .miss(.noText(app: "Ghostty", role: nil))
        guard case .recognised(let read, let request, _, _) = await RecognitionFixtures.read(reader) else {
            Issue.record("no recognition where Accessibility found no word")
            return
        }
        #expect(read.word.word == "fine")
        #expect(request.number == 1)
        #expect(screen.recognitions == 1)
    }

    /// **The capture reads the named app's window** (moved by name from `HoverCaptureTargetTests`): Accessibility named
    /// one app and read nothing; another app's window comes first at the point. Red if the owner is not passed on.
    @Test func theCaptureReadsTheNamedAppsWindow() async {
        let target = HoverFixtures.target()
        let named = ListedWindow(pid: target.pid, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 2)
        let other = ListedWindow(pid: target.pid + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 3)
        let screen = RecognitionFixtures.screen()
        screen.windows = [other, named]
        screen.targetOutcome = .found(target)
        _ = await RecognitionFixtures.read(RecognitionFixtures.reader(screen))
        #expect(screen.recognisedWindows == [named])
    }

    /// The named app has no window at the point: nothing is captured at all (moved by name).
    @Test func noCaptureWhenTheNamedAppHasNoWindowThere() async {
        let target = HoverFixtures.target()
        let screen = RecognitionFixtures.screen()
        screen.windows = [ListedWindow(pid: target.pid + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 3)]
        screen.targetOutcome = .found(target)
        _ = await RecognitionFixtures.read(RecognitionFixtures.reader(screen))
        #expect(screen.recognitions == 0, "another app's window was captured")
    }

    /// **The same site check as the text** (moved by name from `HoverSiteTests`): with no element there is no page to
    /// name, and while the reader excludes a site the pixels are refused, not read. Red without the rule on the pixel path.
    @Test func withoutAnElementThePixelsAreNotReadWhileSitesAreExcluded() async {
        let screen = RecognitionFixtures.screen()
        var policy = HoverPolicy.shipped
        policy.excludedHosts = ["example.com"]
        guard case .quiet(.excludedSite) = await RecognitionFixtures.read(RecognitionFixtures.reader(screen, policy: policy))
        else {
            Issue.record("an unnamed page was captured")
            return
        }
        #expect(screen.recognitions == 0)
    }

    /// **An excluded site found through Accessibility is never read as pixels either**: the one combined job refused it,
    /// and the recogniser is not the way around that.
    @Test func aSiteRefusedThroughAccessibilityIsNotRecognised() async {
        let screen = RecognitionFixtures.screen()
        screen.targetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.windows = [ListedWindow(pid: HoverFixtures.target().pid, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                       windowID: 9)]
        screen.hostReading = .known("bank.example.com")
        var policy = HoverPolicy.shipped
        policy.excludedHosts = ["example.com"]
        guard case .quiet(.excludedSite) = await RecognitionFixtures.read(RecognitionFixtures.reader(screen, policy: policy))
        else {
            Issue.record("an excluded site was not refused")
            return
        }
        #expect(screen.recognitions == 0, "an excluded site's pixels were read")
    }

    /// **The window's owner is checked again on the word read**: a recognition whose app is excluded is not a word.
    @Test func aRecognitionInAnExcludedAppIsRefused() async {
        let screen = RecognitionFixtures.screen(RecognitionFixtures.recognition("He paid the fine.",
                                                                                bundleID: "com.agilebits.onepassword7"))
        guard case .quiet(.excludedApp) = await RecognitionFixtures.read(RecognitionFixtures.reader(screen)) else {
            Issue.record("a password manager's pixels became a word")
            return
        }
    }

    /// **Screen Recording off asks the reader, not the system** (moved by name from `ScreenRecordingAccessTests`): the
    /// reader answers `needsScreenRecording` for the request, which the consumer words.
    @Test func aRefusedCaptureAsksTheReaderNotTheSystem() async {
        let screen = RecognitionFixtures.screen()
        screen.recognition = .failure(.screenRecordingNeeded)
        guard case .needsScreenRecording(let request) = await RecognitionFixtures.read(RecognitionFixtures.reader(screen))
        else {
            Issue.record("a refused capture was not turned into the notice")
            return
        }
        #expect(request.number == 1)
    }

    /// **A finished capture is reported** (moved by name from `HoverCaptureReleaseTests`), so a hover refused for the busy
    /// capture is asked again. Red if the release is not told.
    @Test func aFinishedCaptureIsReported() async {
        let screen = RecognitionFixtures.screen()
        let reader = RecognitionFixtures.reader(screen)
        var released = 0
        reader.onCaptureReleased = { released += 1 }
        _ = await RecognitionFixtures.read(reader)
        #expect(screen.recognitions == 1)
        await HoverFixtures.settle { released > 0 }
        #expect(released == 1, "the capture finished and nobody was told")
    }

    /// **The guard is held until released** (moved by name from `HoverAuditTests`).
    @Test func theCaptureGuardIsHeldUntilReleased() {
        let capture = CaptureGuard()
        #expect(capture.claim())
        #expect(!capture.claim(), "a second capture was let start")
        #expect(capture.isHeld)
        capture.release()
        #expect(!capture.isHeld)
        #expect(capture.claim())
    }

    /// **A capture that never returns says so, and AX stays available meanwhile** (moved by name from `CaptureWedgeTests`;
    /// the second half is XDict ADR-0014 decision 8). The first hover's capture hangs and its read gives up at the deadline,
    /// reported stuck at once; later pixel hovers are refused as a capture in flight — so they are asked again on release —
    /// without a second report; a hover Accessibility can read is answered while the capture is still wedged; and when the
    /// capture returns, it answers again. Red if the deadline releases the guard, or the wedge blocks Accessibility.
    @Test func aWedgedCaptureIsReportedOnceAndClearedOnRelease() async throws {
        let screen = RecognitionFixtures.screen()
        screen.hangs = true
        let reader = RecognitionFixtures.reader(screen, deadline: .milliseconds(20))
        var health: [CaptureHealth] = []
        reader.onCaptureHealth = { health.append($0) }

        guard case .nothing(.captureTimedOut) = await RecognitionFixtures.read(reader) else {
            Issue.record("a capture past its deadline was not given up on")
            return
        }
        #expect(health == [.stuck(for: .milliseconds(20))], "the wedge was not reported at the deadline")
        guard case .quiet(.captureInFlight) = await RecognitionFixtures.read(reader) else {
            Issue.record("a hover during a wedge lost its retry on release")
            return
        }
        #expect(health.count == 1, "the wedge was reported \(health.count) times")

        screen.targetOutcome = .found(HoverFixtures.target())
        screen.windows = [ListedWindow(pid: HoverFixtures.target().pid, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                                       windowID: 9)]
        screen.readOutcome = .hit(HoverFixtures.hit("tide"))
        guard case .word = await RecognitionFixtures.read(reader) else {
            Issue.record("Accessibility was blocked by a wedged capture")
            return
        }

        screen.finishCapture()
        await HoverFixtures.settle { health.count == 2 }
        #expect(health.last == .answering, "the capture answered and nobody was told")
    }

    // MARK: - The pending context (moved by name from `HoverPendingContextTests`)

    private func growing(_ gate: GrowthGate) -> ScriptedPointerWords {
        var first = RecognitionFixtures.recognition("He paid the fine and", cut: true)
        first.wantsMore = [.below]
        first.growth = {
            await gate.held()
            return Task.isCancelled ? nil : RecognitionFixtures.recognition("Before leaving, he paid the fine and went home.")
        }
        return RecognitionFixtures.screen(first)
    }

    /// **The word is delivered while the taller strip is still read**, its context pending, and no other capture starts
    /// until the context settles — to the grown sentence, its range the word's.
    @Test func theFirstStripAnswersAndTheCaptureIsHeldUntilTheContextSettles() async throws {
        let gate = GrowthGate()
        let screen = growing(gate)
        let reader = RecognitionFixtures.reader(screen)
        var releases = 0
        reader.onCaptureReleased = { releases += 1 }
        guard case .recognised(let read, _, _, let context) = await RecognitionFixtures.read(reader) else {
            Issue.record("the first strip's word was not delivered while the context was read")
            return
        }
        #expect(read.word.sentence.text == "He paid the fine and")
        let pending = try #require(context, "a reading still growing was delivered with nothing to wait for")
        await HoverFixtures.settle { gate.isWaiting }
        #expect(gate.isWaiting, "the taller strip was never read")
        guard case .quiet(.captureInFlight) = await RecognitionFixtures.read(reader) else {
            Issue.record("a second capture was let start while the taller strip was read")
            return
        }
        #expect(releases == 0)
        gate.open()
        await HoverFixtures.settle { pending.end != nil }
        #expect(pending.end == .settled(.available(sentence: "Before leaving, he paid the fine and went home.",
                                                    term: NSRange(location: 28, length: 4), cut: [], gap: nil)))
        await HoverFixtures.settle { releases == 1 }
        #expect(releases == 1, "the capture was never let go")
    }

    /// **A context nobody will show is not read on**: cancelling it lets the capture go.
    @Test func cancellingTheContextLetsTheCaptureGo() async throws {
        let gate = GrowthGate()
        let reader = RecognitionFixtures.reader(growing(gate))
        var releases = 0
        reader.onCaptureReleased = { releases += 1 }
        guard case .recognised(_, _, _, let context?) = await RecognitionFixtures.read(reader) else {
            Issue.record("no context to cancel")
            return
        }
        await HoverFixtures.settle { gate.isWaiting }
        context.cancel()
        await HoverFixtures.settle { gate.sawCancellation }
        #expect(gate.sawCancellation, "the taller strip went on being read")
        await HoverFixtures.settle { releases == 1 }
        #expect(releases == 1, "the capture was held for a context nobody will show")
        #expect(context.end == .cancelled)
    }

    /// **A reading with nothing left to read has no context**, and lets the capture go.
    @Test func aWholeReadingHasNoContext() async throws {
        let reader = RecognitionFixtures.reader(RecognitionFixtures.screen())
        var releases = 0
        reader.onCaptureReleased = { releases += 1 }
        guard case .recognised(_, _, _, let context) = await RecognitionFixtures.read(reader) else {
            Issue.record("no word")
            return
        }
        #expect(context == nil)
        await HoverFixtures.settle { releases == 1 }
        #expect(releases == 1)
    }

    /// **A pending context never outlives its bound** (decision 8): a taller strip that never answers leaves the first
    /// reading standing, overdue, at the capture deadline counted from the first read.
    @Test func aContextThatNeverSettlesIsOverdueAtTheDeadline() async throws {
        let gate = GrowthGate()
        let reader = RecognitionFixtures.reader(growing(gate), deadline: .milliseconds(200))
        guard case .recognised(let read, _, _, let context?) = await RecognitionFixtures.read(reader) else {
            Issue.record("no context")
            return
        }
        await HoverFixtures.settle { context.end != nil }
        #expect(context.end == .overdue(read.context))
        gate.open()
    }
}
