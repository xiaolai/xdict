import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **Screen Recording, probed through ScreenCaptureKit and asked for only by the setup row** (XDict ADR-0014 decision 7;
/// XiaolaiDict ADR-0017; plan-capture WI-4). The first ScreenCaptureKit call — `SCShareableContent` included, which macOS may
/// answer with its consent dialog on a Mac that has never been asked — happens only after the reader used the row, or
/// where macOS reports a standing grant through the one call that never prompts. A hover before that touches nothing.
struct ScreenRecordingAccessTests {
    /// Counts every call into the system, by kind.
    final class Calls: Sendable {
        let probes = Mutex(0)
        let requests = Mutex(0)
        let preflights = Mutex(0)
    }

    static func access(
        probe: PermissionProbe = .granted, preflight: Bool = false, calls: Calls = Calls()
    ) -> ScreenRecordingAccess {
        ScreenRecordingAccess(
            probe: { calls.probes.withLock { $0 += 1 }; return probe },
            preflight: { calls.preflights.withLock { $0 += 1 }; return preflight },
            request: { calls.requests.withLock { $0 += 1 } })
    }

    /// **Before the row, nothing that can prompt**: with no standing grant, capture's state is "not set up" and neither the
    /// probe nor the request is made. Red if the state probes first and asks after.
    @Test func nothingTouchesScreenCaptureKitBeforeTheRow() async {
        let calls = Calls()
        let access = Self.access(calls: calls)
        #expect(await access.captureState() == .notSetUp)
        #expect(!access.mayTouchScreenCaptureKit())
        #expect(calls.probes.withLock { $0 } == 0, "ScreenCaptureKit was asked before the reader used the row")
        #expect(calls.requests.withLock { $0 } == 0)
    }

    /// **The row is the only thing that asks**: it requests once, and from then on capture may probe.
    @Test func theRowAsksAndOpensTheWay() async {
        let calls = Calls()
        let access = Self.access(calls: calls)
        #expect(await access.setUp() == .granted)
        #expect(calls.requests.withLock { $0 } == 1)
        #expect(access.mayTouchScreenCaptureKit())
        #expect(await access.captureState() == .granted)
    }

    /// **A standing grant needs no row**: macOS says so through the one call that cannot prompt, and only then is
    /// ScreenCaptureKit asked — so a reader who granted it before is not sent to Settings after every launch.
    @Test func aStandingGrantOpensTheWayWithoutAsking() async {
        let calls = Calls()
        let access = Self.access(preflight: true, calls: calls)
        #expect(await access.captureState() == .granted)
        #expect(calls.requests.withLock { $0 } == 0, "a standing grant was requested again")
    }

    private static let window = ListedWindow(pid: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), windowID: 1)

    /// **A declined grant is reported, not requested** (moved by name from XiaolaiDict's `ScreenRecordingAccessTests`): the
    /// recogniser, past a standing grant's gate, finds the probe saying no, answers `screenRecordingNeeded`, and asks once —
    /// never the system for the grant.
    @Test func aDeclinedGrantIsReportedNotRequested() async {
        let calls = Calls()
        let recogniser = ScreenTextRecogniser(metrics: Measured.metrics,
                                              access: Self.access(probe: .declined, preflight: true, calls: calls))
        await #expect(throws: RecognitionError.screenRecordingNeeded) {
            try await recogniser.read(at: .zero, window: Self.window, policy: .shipped)
        }
        #expect(calls.probes.withLock { $0 } == 1)
        #expect(calls.requests.withLock { $0 } == 0, "the recogniser requested the grant")
    }

    /// **Could not tell is neither a refusal nor a grant** (moved by name): a probe that failed for another reason says
    /// nothing about consent, and is not reported as the grant being off.
    @Test func anUnreadableGrantIsNeitherARefusalNorAGrant() async {
        let recogniser = ScreenTextRecogniser(metrics: Measured.metrics,
                                              access: Self.access(probe: .couldNotTell, preflight: true))
        await #expect(throws: RecognitionError.screenRecordingUnreadable) {
            try await recogniser.read(at: .zero, window: Self.window, policy: .shipped)
        }
    }

    /// **Before the row the recogniser reaches nothing**: no probe, no request, and the reader is told it is needed.
    @Test func theRecogniserBeforeTheRowTouchesNothing() async {
        let calls = Calls()
        let recogniser = ScreenTextRecogniser(metrics: Measured.metrics, access: Self.access(calls: calls))
        await #expect(throws: RecognitionError.screenRecordingNeeded) {
            try await recogniser.read(at: .zero, window: Self.window, policy: .shipped)
        }
        #expect(calls.probes.withLock { $0 } == 0 && calls.requests.withLock { $0 } == 0)
    }

    /// **A grant is remembered, a refusal never** (XiaolaiDict's `GrantMemo`): the reader granting it is the event a
    /// refusal must not hide.
    @Test func aGrantIsRememberedARefusalIsNot() async {
        let answers = Mutex<[PermissionProbe]>([.declined, .granted, .declined])
        let calls = Calls()
        let access = ScreenRecordingAccess(
            probe: { calls.probes.withLock { $0 += 1 }; return answers.withLock { $0.removeFirst() } },
            preflight: { true }, request: {})
        #expect(await access.captureState() == .declined)
        #expect(await access.captureState() == .granted)
        #expect(await access.captureState() == .granted)
        #expect(calls.probes.withLock { $0 } == 2, "a grant was asked again")
    }
}

/// **Where ScreenCaptureKit and the permission calls may be named**, read off this target's sources with comments blanked:
/// the request and the non-prompting preflight in `ScreenRecordingAccess.swift` only, and ScreenCaptureKit's calls in that
/// file and the recogniser's. A second caller would be a second way to reach a prompt that no row stands in front of.
struct ScreenCaptureUseTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/XDictCaptureMac")

    /// Each name and the files that may say it.
    static let allowed: [String: Set<String>] = [
        "CGRequestScreenCaptureAccess": ["ScreenRecordingAccess.swift"],
        "CGPreflightScreenCaptureAccess": ["ScreenRecordingAccess.swift"],
        "SCShareableContent": ["ScreenRecordingAccess.swift", "ScreenTextRecogniser.swift"],
        "SCScreenshotManager": ["ScreenTextRecogniser.swift"],
        "import ScreenCaptureKit": ["ScreenRecordingAccess.swift", "ScreenTextRecogniser.swift"],
    ]

    /// Code only: every `//` comment blanked, and string literals left (no permission call is spelled in one).
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let comment = line.range(of: "//") else { return line }
            return line[..<comment.lowerBound]
        }.joined(separator: "\n")
    }

    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        files.flatMap { file in
            allowed.sorted(by: { $0.key < $1.key }).compactMap { name, owners in
                code(file.text).contains(name) && !owners.contains(file.name) ? "\(file.name) names \(name)" : nil
            }
        }.sorted()
    }

    @Test func screenCaptureIsNamedOnlyWhereTheRowStandsInFront() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
        #expect(!files.isEmpty, "the scan read nothing of \(Self.sources.path)")
        #expect(Self.problems(files) == [])
        // The premise: the owners do name them. A rule about calls nobody makes holds nothing.
        let owner = try #require(files.first { $0.name == "ScreenRecordingAccess.swift" })
        #expect(Self.code(owner.text).contains("CGRequestScreenCaptureAccess"))
    }

    /// **The control**: a planted caller elsewhere is named, and a comment that mentions one is not.
    @Test func aCallerOutsideTheOwnersIsNamed() {
        let planted = [(name: "HoverReader.swift", text: "let c = try await SCShareableContent.current\nCGRequestScreenCaptureAccess()"),
                       (name: "Notes.swift", text: "// SCShareableContent may prompt")]
        #expect(Self.problems(planted)
                == ["HoverReader.swift names CGRequestScreenCaptureAccess", "HoverReader.swift names SCShareableContent"])
    }
}
