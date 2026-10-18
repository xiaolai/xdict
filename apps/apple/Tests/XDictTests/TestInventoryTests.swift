import Foundation
import Testing
import XDictTestSupport

/// **A target that stops running its tests looks exactly like a target whose tests pass** (adapted from XiaolaiDict's
/// `TestInventoryTests`). There, a scripted edit emptied five files; everything compiled, `swift test` exited 0 with
/// every line "passed", and one target had gone from 47 tests to 4. The number was the only thing that said so.
///
/// So each test target has a floor: the fewest `@Test` declarations it may hold. Floors, not equalities: adding a test
/// needs no edit here, and only a drop is a signal. Lowering one is a deliberate line in a diff, with its reason.
struct TestInventoryTests {
    /// Set to each target's count when the skeleton landed (2026-10-14, WI-2); `XDictContractTests` added, and the
    /// service's and the harness's raised, with the frozen contract and its Codex refutation (2026-10-14, WI-1);
    /// `XDictEntryViewTests` added with the entry view, and the harness's raised by its boundary rows (2026-10-14, WI-4);
    /// `XDictLibraryTests` added with the library, and the view layer's and the service's raised by its sentences and
    /// its scenario (2026-10-14, WI-5); `XDictSearchTests` added with the main window, and the view layer's, the entry
    /// view's and the service's raised by its sentences, its landing, Tab to links and replaced loads, and its scenario
    /// and held transport (2026-10-15, WI-6); `XDictSpeechTests` added with sound and speech, and the main window's and the
    /// view layer's raised by its pronunciation and their sentences (2026-10-15, WI-7); `XDictAnywhereTests` added with
    /// lookup from anywhere, and the main window's and the view layer's raised by the panel's handover and its sentences
    /// (2026-10-15, WI-8).
    static let floors = [
        // 8 → 2 (WI-3): the handshake became the contract's `versions`; its tests moved with it, to XDictClientTests
        // (`LaunchHandshakeTests`) and XDictServiceTests (`ServiceContractTests`).
        "XDictBaseTests": 2,
        "XDictClientTests": 20,
        "XDictContractTests": 80,
        // 52 → 73 (plan WI-5, 2026-10-18): the Apple import's copy, conversion, source record, joins, sweep and restarts.
        "XDictLibraryTests": 73,
        "XDictSearchTests": 49,
        "XDictSpeechTests": 31,
        // 69 → 64 (P41, 2026-10-17): the panel became an NSPopover, placed by AppKit beside its anchor; the placement
        // tests went with PanelPlacement.frame, and LookupPopoverTests (XDictUITests) holds the anchor and the edge.
        // 64 → 37 (plan-capture WI-2, 2026-10-18): by transfer, SelectionReaderTests (24) and SelectedTerm's four cases of
        // LookupTextTests moved by name to XDictCaptureMacTests with the reader; one added (the shortcut's admission).
        // 37 → 66 (plan-capture WI-3): 38 were present (the floor above counted one short); the composition layer for
        // capture — HoverPolicyStoreTests (8) and HoverPauseWiringTests (5) and CaptureHealthWiringTests (1) moved by name
        // from XiaolaiDict, fourteen added (the control's scripts, its default and tolerances, hover off starting nothing,
        // the derived scripts, the popover's acknowledgements, the anchor): 38 + 14 + 14 = 66. 66 → 69: a driven launch
        // starts no hover, and which launch it is, both ways (HoverLaunchTests). 69 → 76 (plan-capture WI-4): the Screen
        // Recording row asks nothing before it is used, at launch either, asks once when used, shows a standing grant, its
        // notice, the session's book shared with the reader, the recogniser's distances from the tokens.
        "XDictAnywhereTests": 76,
        // 24 → 29 (plan WI-5, 2026-10-18): the Add Apple Dictionaries… sheet's logic and its sentences.
        // 29 → 33 (plan-capture WI-3): hover's sentences — keys, gestures, scripts, notices and the pause lines.
        "XDictUITests": 33,
        "XDictEntryViewTests": 43,
        // 90 → 92 (plan WI-5, 2026-10-18): the app's and the service's revisions of one bundle agree.
        "XDictServiceTests": 92,
        // 37 → 39 (plan-capture WI-1, 2026-10-18): capture's transitive boundary and its controls; 39 → 40 (WI-2): the
        // macOS capture target's controls.
        // 40 → 42 (WI-3): the captured context's data-flow rule and its control; 42 → 44: every driven instrument turns
        // hover off, and its control; 44 → 46: the app starts hover only with its launch, and its control.
        "XDictTests": 46,
        // Added with the Apple dictionary converter (ADR-0011, plan WI-3); the service's raised by its acceptance through the
        // core, the harness's by its boundary (2026-10-18). Raised with the conversion in the service (plan WI-4,
        // 2026-10-18): the converter's checkpoint, the app group, contract 6 and the service's conversions.
        "XDictAppleImportTests": 72,
        // Added with the design tokens (2026-10-18): the generated file against its source, and both faces of a token.
        "XDictTokensTests": 6,
        // Added with the Apple import (plan WI-5, 2026-10-18): installed bundles found, copied, swept and hashed.
        "XDictAppleSourceTests": 16,
        // Added with capture's pure target (plan-capture WI-1, 2026-10-18): XiaolaiDict's capture tests moved by name;
        // 261 → 269 (WI-3): one numbering across the four triggers (5) and the ephemeral context session (3).
        // 269 → 282 (WI-4): the pending context, its one ending and its cancel (6), the book of them (3), and the
        // session settling, cancelling and refusing an unknown handle (4).
        "XDictCaptureTests": 282,
        // Added with capture's macOS target (plan-capture WI-2, 2026-10-18): the probe, the session and the one lane (22);
        // 22 → 68 by transfer of the 28 above from XDictAnywhereTests, ProcessResolverTests' five from XiaolaiDict, and
        // thirteen added (the hit test inside the read, the lane and the main actor, the Service text, the admission);
        // 68 → 91: the pointer word reader, ScreenWordBoundsTests (6), the budget tests (6) and ChromiumEscalationTests
        // (2) moved by name from XiaolaiDict, nine added (the marker dialect, the target's order, metadata-only text).
        // 113 → 153 (WI-3): the hover watcher and reader, XiaolaiDict's HoverWatcherSequenceTests (18, with
        // stoppingEndsTheHover), HoverWatcherTests (13), HoverReaderSourceTests (2) and HoverSiteTests (1) moved by name,
        // six added (an excluded app, the own window, an unreadable site, the stuck lane, a request that found nothing);
        // 153 → 156: a hover supersedes a shortcut still reading, the compositor's own window, the key up at the gate.
        // 156 → 205 (WI-4): the recogniser, XiaolaiDict's RecognitionScopeTests (8), ScreenTextRecogniserRunTests (8),
        // StripReadingTests (8), ScreenTextRecogniserBandTests (5) and two ScreenRecordingAccessTests moved by name;
        // twenty-three added (the acquisition limits, the term handed over, the setup row's gate, where ScreenCaptureKit
        // is named, the recorded recognitions). 205 → 226: the hover reader's pixel path, XiaolaiDict's
        // HoverCaptureTargetTests (2), HoverCaptureReleaseTests (1), CaptureWedgeTests (1), HoverPendingContextTests (3),
        // withoutAnElementThePixelsAreNotReadWhileSitesAreExcluded, aRefusedCaptureAsksTheReaderNotTheSystem,
        // thecaptureGuardIsHeldUntilReleased and four watcher cases (aNoticeForAnAbandonedReadIsNotShown,
        // aNoticeForAHoverThatNoLongerStandsIsNotShown, aBlockedReadIsAskedAgainWhenTheCaptureFinishes, aReAskKeepsItsNumber)
        // moved by name; seven added (Accessibility first, a site refused through Accessibility, an excluded app's
        // recognition, an overdue context, a notice told and its request ended, a recognised word presented pending, and
        // one not presented cancelling its context).
        "XDictCaptureMacTests": 226,
    ]

    @Test func everyTargetStillRunsTheTestsItHad() throws {
        let shortfalls = try Self.floors.sorted(by: { $0.key < $1.key }).compactMap { target, floor -> String? in
            let found = try Self.tests(in: target)
            return found < floor ? "\(target): \(found) @Test, floor \(floor)" : nil
        }
        #expect(shortfalls.isEmpty, """
            a test target lost tests — \(shortfalls.joined(separator: "; ")). If they were deliberately deleted, lower \
            the floor in the same change and say why.
            """)
    }

    /// **The floors name every test target SwiftPM knows**, read off the manifest: a target with no floor is one the
    /// guard does not cover, and it goes on passing whatever happens to it.
    @Test func everyTestTargetHasAFloor() throws {
        let declared = try Manifest.dump().targets.values.filter { $0.type == "test" }.map(\.name)
        #expect(Set(declared) == Set(Self.floors.keys), """
            test targets in Package.swift: \(declared.sorted()); with a floor: \(Self.floors.keys.sorted())
            """)
    }

    /// A floor of zero guards nothing, and a directory that reads as empty passes every floor of zero.
    @Test func noFloorIsVacuous() throws {
        for (target, floor) in Self.floors {
            #expect(floor > 0, "\(target) has a floor of \(floor), which nothing can fail")
            #expect(try Self.tests(in: target) > 0, "no @Test found in \(target) at all")
        }
    }

    /// `@Test` attributes under `Tests/<target>`, comments and strings blanked: a comment explaining `@Test` is not one.
    static func tests(in target: String) throws -> Int {
        try SourceScan.files(under: Manifest.package.appending(path: "Tests/\(target)")).reduce(0) { count, file in
            count + SourceScan.codeOnly(file.text).components(separatedBy: "@Test").count - 1
        }
    }
}
