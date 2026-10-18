import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The window's owner is vetted before a pixel is captured** (ADR-0014 decision 7; plan-capture WI-4): the recogniser
/// serves exactly the apps that expose no element, so the Accessibility path cannot vet them, and an excluded app's or an
/// unattributable window's pixels are never taken. Observed at the capture itself: a stand-in for the screen counts every
/// capture call.
struct RecognitionAuthorisationTests {
    struct StandInFilter: CaptureFilter {
        var pointPixelScale: Float { 2 }
    }

    /// The screen side, owned by `bundleID`; every capture is counted, and refused so nothing is read.
    final class CountingCapturer: ScreenCapturing {
        let bundleID: String?
        private let calls = Mutex(0)
        var captures: Int { calls.withLock { $0 } }

        init(bundleID: String?) { self.bundleID = bundleID }

        func target(at point: CGPoint, window: ListedWindow, stripHeight: CGFloat) async throws -> CaptureTarget {
            let region = CGRect(x: 0, y: 0, width: window.bounds.width, height: stripHeight)
            return CaptureTarget(filter: StandInFilter(), region: region, sourceRect: region, appName: "Stand-in",
                                 bundleID: bundleID, frame: window.bounds)
        }

        func capture(_ target: CaptureTarget, of window: ListedWindow) async throws -> CGImage {
            calls.withLock { $0 += 1 }
            throw RecognitionError.windowNotCapturable
        }
    }

    static let window = ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 7)

    static func recogniser(_ capturer: CountingCapturer) -> ScreenTextRecogniser {
        ScreenTextRecogniser(metrics: Measured.metrics, limits: .shipped,
                             access: ScreenRecordingAccessTests.access(probe: .granted, preflight: true), capturer: capturer)
    }

    @Test func anExcludedAppIsRefusedBeforeAnyCapture() async {
        let capturer = CountingCapturer(bundleID: "com.agilebits.onepassword7")
        await #expect(throws: RecognitionError.excludedApp) {
            try await Self.recogniser(capturer).read(at: CGPoint(x: 10, y: 10), window: Self.window, policy: .shipped)
        }
        #expect(capturer.captures == 0, "a password manager's pixels were captured")
    }

    @Test func aWindowWithNoOwnerIsRefusedBeforeAnyCapture() async {
        let capturer = CountingCapturer(bundleID: nil)
        await #expect(throws: RecognitionError.unattributable) {
            try await Self.recogniser(capturer).read(at: CGPoint(x: 10, y: 10), window: Self.window, policy: .shipped)
        }
        #expect(capturer.captures == 0, "a window nobody owns was captured")
    }

    /// The premise: an app hover may read does reach the capture, so the two above count the path that captures.
    @Test func anAllowedAppIsCaptured() async {
        let capturer = CountingCapturer(bundleID: "com.mitchellh.ghostty")
        await #expect(throws: RecognitionError.windowNotCapturable) {
            try await Self.recogniser(capturer).read(at: CGPoint(x: 10, y: 10), window: Self.window, policy: .shipped)
        }
        #expect(capturer.captures == 1)
    }
}
