import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureLab
@testable import XDictCaptureMac

/// **The capture lab's `--read-point`** (plan-capture WI-4): a development instrument outside XDict.app that reads the
/// word under a screen point through hover's own reader and prints the term as capture hands it to search. Reading the
/// real screen from a unit test would measure this Mac's grants, not this code, so the screen here is a stand-in.

/// The hover instrument's command line. A verification command that accepted a typo would report success for something
/// nobody asked for (moved by name from XiaolaiDict's `LaunchArgumentsTests`).
struct ReadPointArgumentTests {
    @Test func aPointIsParsed() {
        #expect(LabCommand.parse(["--read-point", "120", "340.5"]) == .success(.readPoint(CGPoint(x: 120, y: 340.5))))
        #expect(LabCommand.parse(["--read-point", "-5", "0"]) == .success(.readPoint(CGPoint(x: -5, y: 0))))
    }

    @Test(arguments: [["--read-point"], ["--read-point", "120"],
                      ["--read-point", "120", "340", "extra"],
                      ["--read-point", "x", "340"], ["--read-point", "120", "nan"],
                      // XDict's own: nothing at all, and a command this lab does not have.
                      [], ["--read-selection", "com.apple.TextEdit"], ["--access", "x"]])
    func anythingElseIsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try LabCommand.parse(arguments).get() }
    }

    /// **`--access` says what this lab is granted** (plan-capture WI-5; the hover stages' `*.access` checks): asked of
    /// the APIs that never prompt, and it takes no argument.
    @Test func theAccessCommandTakesNothing() {
        #expect(LabCommand.parse(["--access"]) == .success(.access))
    }
}

enum LabFixtures {
    static let window = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)

    static func term(box: WordBox, context: ContextOutcome? = nil) throws -> CapturedTerm {
        try CapturedTerm.make(
            term: "cat", trigger: .pointerGesture, acquisition: .textRange, confidence: 1,
            source: SourceApp(bundleID: "com.apple.TextEdit"), pointer: nil, box: box,
            context: context ?? .available(sentence: "The cat sat.", term: NSRange(location: 4, length: 3), cut: [],
                                           gap: nil))
    }

    static func json(_ report: PointReport) throws -> [String: Any] {
        let line = try report.jsonLine()
        #expect(!line.contains("\n"), "a report is one line")
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    static func recognition(_ sentence: String, word: String, cut: Bool = false) -> Recognition {
        let range = (sentence as NSString).range(of: word)
        guard let context = SentenceContext(text: sentence, mayBeCut: cut, selection: range, cut: cut ? .end : []) else {
            preconditionFailure("a sentence")
        }
        return Recognition(word: WordAtPoint(word: word, sentence: context), confidence: 0.9, mayBeCut: cut,
                           appName: "Ghostty", bundleID: "com.mitchellh.ghostty", gap: nil)
    }
}

/// **`--read-point` says where the word is**, so a stage can check the box against its own measurement (moved by name
/// from XiaolaiDict's `PointReportBoundsTests`; the box is now `CapturedTerm`'s, measured or absent).
struct PointReportBoundsTests {
    @Test func theReportCarriesTheBoxYDownWithItsQuality() throws {
        let read = ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .containing)
        let json = try LabFixtures.json(PointReport(try LabFixtures.term(box: .measured(read)), milliseconds: 3))
        let bounds = try #require(json["bounds"] as? [String: Any])
        #expect(bounds["x"] as? Double == 140 && bounds["y"] as? Double == 200)
        #expect(bounds["width"] as? Double == 30 && bounds["height"] as? Double == 20)
        #expect(bounds["quality"] as? String == "containing")
    }

    @Test func noBoxIsReportedAsNone() throws {
        let line = try PointReport(try LabFixtures.term(box: .absent), milliseconds: 3).jsonLine()
        #expect(!line.contains("\"bounds\""))
    }
}

/// **The report is the term as capture hands it over** (ADR-0014 decision 2): the dialect as the acquisition, the
/// source app, and the context's outcome — never a pending one, which only the reading's end decides.
struct PointReportTests {
    @Test func theContextIsReportedAsCaptureHandsIt() throws {
        let cut = try LabFixtures.json(PointReport(try LabFixtures.term(
            box: .absent, context: .available(sentence: "The cat sat", term: NSRange(location: 4, length: 3),
                                              cut: [.end], gap: .unreadSpan)), milliseconds: 7))
        #expect(cut["term"] as? String == "cat" && cut["acquisition"] as? String == "textRange")
        #expect(cut["bundleID"] as? String == "com.apple.TextEdit" && cut["milliseconds"] as? Int == 7)
        let context = try #require(cut["context"] as? [String: Any])
        #expect(context["state"] as? String == "available" && context["sentence"] as? String == "The cat sat")
        #expect(context["cut"] as? [String] == ["end"] && context["gap"] as? String == "unreadSpan")
        #expect(cut["first"] == nil, "a reading that was whole has no first reading")

        let none = try LabFixtures.json(PointReport(try LabFixtures.term(box: .absent, context: .unavailable(.appExposedNone)),
                                                    milliseconds: 1))
        let unavailable = try #require(none["context"] as? [String: Any])
        #expect(unavailable["state"] as? String == "unavailable" && unavailable["reason"] as? String == "appExposedNone")
        #expect(unavailable["sentence"] == nil)
    }

    @Test func aPendingContextIsNeverReported() throws {
        let pending = try LabFixtures.term(box: .absent, context: .pending(PendingContextHandle(id: 1)))
        #expect(throws: PointReport.Refusal.pendingContext) { try PointReport(pending, milliseconds: 1) }
    }
}

/// A screen that answers what the test set: Accessibility's word, or the recogniser's.
final class LabScreen: PointerWordSource, Sendable {
    let targetOutcome: PointerWordReader.TargetOutcome
    let readOutcome: PointerWordReader.Outcome
    let recognition: Result<Recognition, RecognitionError>
    private let recognised = Mutex(0)

    init(target: PointerWordReader.TargetOutcome = .none(.nothingAtPointer),
         read: PointerWordReader.Outcome = .miss(.noText(app: "TextEdit", role: nil)),
         recognition: Result<Recognition, RecognitionError> = .failure(.nothingUnderPointer)) {
        targetOutcome = target
        readOutcome = read
        self.recognition = recognition
    }

    var recognitions: Int { recognised.withLock { $0 } }
    func listedWindows() -> [ListedWindow] { [LabFixtures.window] }
    func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow], refusesOwner: @escaping @Sendable (pid_t) -> Bool
    ) async -> PointerWordReader.TargetOutcome {
        targetOutcome
    }
    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        .read(readOutcome)
    }
    func ownView(at point: CGPoint) -> OwnView { .controls }
    func ownTarget(at point: CGPoint) async -> PointerWordReader.OwnTargetOutcome { .none(.nothingAtPointer) }
    func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        .read(readOutcome)
    }
    func laneState() -> LaneState { .idle }
    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        recognised.withLock { $0 += 1 }
        return try recognition.get()
    }
}

/// **One read through hover's own reader**, Accessibility first and the pixels where it found no word, with the shipped
/// policy and a deadline of the instrument's own.
@MainActor
struct ReadPointRunTests {
    @Test func anAccessibilityWordIsReportedWithItsDialect() async throws {
        let target = PointerWordReader.Target(element: AXUIElementCreateApplication(getpid() + 1), appName: "TextEdit",
                                              bundleID: "com.apple.TextEdit")
        let word = try #require(TextSegmenter.word(in: "The cat sat.", utf16Offset: 5))
        let hit = PointerWordReader.Hit(word: word, acquisition: .textMarkers, appName: "TextEdit",
                                        bundleID: "com.apple.TextEdit", bounds: nil)
        let screen = LabScreen(target: .found(target), read: .hit(hit))
        let report = try await ReadPoint.run(at: CGPoint(x: 10, y: 10), source: screen).get()
        #expect(report.term == "cat" && report.acquisition == "textMarkers" && report.first == nil)
        #expect(report.context.sentence == "The cat sat.")
        #expect(screen.recognitions == 0, "the pixels were read where Accessibility had the word")
    }

    /// **A recognised word waits for the rest of its sentence**, and says what it first read and how it ended.
    @Test func aRecognisedWordWaitsForItsSentence() async throws {
        var first = LabFixtures.recognition("He paid the", word: "paid", cut: true)
        let grown = LabFixtures.recognition("He paid the fine.", word: "paid")
        first.growth = { grown }
        let report = try await ReadPoint.run(at: CGPoint(x: 10, y: 10), source: LabScreen(recognition: .success(first))).get()
        #expect(report.term == "paid" && report.acquisition == "recognition")
        #expect(report.context.sentence == "He paid the fine.", "the report is not the settled sentence")
        let earlier = try #require(report.first, "a reading that grew has no first reading")
        #expect(earlier.context.sentence == "He paid the" && earlier.end == "settled")
    }

    /// **Without Screen Recording nothing is asked**: the lab says where it is allowed and fails.
    @Test func withoutScreenRecordingTheLabSaysSoAndFails() async {
        let result = await ReadPoint.run(at: CGPoint(x: 10, y: 10),
                                         source: LabScreen(recognition: .failure(.screenRecordingNeeded)))
        guard case .failure(let failure) = result else { Issue.record("read without Screen Recording"); return }
        #expect(failure.message.contains("Screen Recording"), "\(failure.message)")
    }

    @Test func nothingReadIsAFailureThatSaysWhy() async {
        let result = await ReadPoint.run(at: CGPoint(x: 10, y: 10), source: LabScreen())
        guard case .failure(let failure) = result else { Issue.record("a report of nothing"); return }
        #expect(failure.message.hasPrefix("nothing read:"), "\(failure.message)")
    }
}

/// **What the lab's process says and exits with**: the report on standard output, one line; anything else on standard
/// error, with 1 for nothing read and 64 for a command it does not have.
@MainActor
struct LabMainTests {
    final class Lines: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
    }

    @Test func aUsageErrorPrintsNothingOnStandardOutput() async {
        let lines = Lines()
        let status = await LabMain.run(arguments: ["--read-pont", "1", "2"], source: LabScreen(),
                                       out: { lines.out.append($0) }, err: { lines.err.append($0) })
        #expect(status == .usage && status.rawValue == 64)
        #expect(lines.out.isEmpty && lines.err.count == 1)
    }

    @Test func aReportIsOneLineOnStandardOutput() async {
        let lines = Lines()
        let screen = LabScreen(recognition: .success(LabFixtures.recognition("He paid the fine.", word: "fine")))
        let status = await LabMain.run(arguments: ["--read-point", "10", "10"], source: screen,
                                       out: { lines.out.append($0) }, err: { lines.err.append($0) })
        #expect(status == .success && lines.out.count == 1 && lines.err.isEmpty, "\(lines.err)")
        #expect(lines.out.first?.contains("\"term\":\"fine\"") == true, "\(lines.out)")
    }

    @Test func nothingReadExitsOne() async {
        let lines = Lines()
        let status = await LabMain.run(arguments: ["--read-point", "10", "10"], source: LabScreen(),
                                       out: { lines.out.append($0) }, err: { lines.err.append($0) })
        #expect(status == .failure && status.rawValue == 1 && lines.out.isEmpty)
    }
}
