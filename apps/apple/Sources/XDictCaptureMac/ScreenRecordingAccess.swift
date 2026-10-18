import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization
import XDictBase
import os

/// What capture may do with the screen now (XDict ADR-0014 decision 7).
public enum ScreenRecordingState: Sendable, Equatable {
    /// The reader has not used the setup row in this run, and macOS reports no standing grant: nothing that could prompt
    /// has been, or may be, called.
    case notSetUp
    case granted
    /// The reader said no, or has not said yes. Only System Settings changes it; capture never asks again.
    case declined
    /// The probe failed for a reason that is not a refusal: it says nothing about consent.
    case couldNotTell
}

/// **Whether XDict may record the screen — and the one place it is asked for** (ported from XiaolaiDict's
/// `ScreenRecordingAccess` and the Screen Recording half of its `Permission`, plan-capture WI-4).
///
/// - **The probe is ScreenCaptureKit's own** (`SCShareableContent`, the API the recogniser captures through), bounded,
///   three-valued: only `SCStreamErrorUserDeclined` is a refusal (XiaolaiDict ADR-0017: a cold failure collapsed to "no"
///   raised a dialog that granted nothing). `CGPreflightScreenCaptureAccess()` is never the answer: it is cached per
///   process and goes on saying no after a live grant.
/// - **The first ScreenCaptureKit call happens only behind the setup row** (decision 7; XiaolaiDict ADR-0017 let a probe
///   prompt, XDict does not). On a Mac whose privacy database has never recorded XDict, `SCShareableContent` may put up
///   macOS's consent dialog, so capture may touch ScreenCaptureKit only once the reader used the row in this run
///   (`setUp`), **or** where macOS reports a standing grant through `CGPreflightScreenCaptureAccess()` — which never
///   prompts, so its "yes" can open the way and its "no" only keeps it shut. Nothing is stored: a reset, a denial or a
///   restart is read again from the system, never from a flag.
/// - **`setUp` is the only request** (`CGRequestScreenCaptureAccess()`, Apple's documented one), called by the row and by
///   nothing else (`ScreenCaptureUseTests`).
/// - **A grant is remembered, a refusal never**: macOS stops a process whose grant it withdraws, and the reader granting
///   it is exactly the event a remembered refusal would hide.
public final class ScreenRecordingAccess: Sendable {
    private let probe: @Sendable () async -> PermissionProbe
    private let preflight: @Sendable () -> Bool
    private let request: @Sendable () -> Void

    private struct State {
        /// The reader used the setup row in this run.
        var setUp = false
        /// A probe answered `granted` in this run.
        var granted = false
    }

    private let state = Mutex(State())

    /// The seams are the tests'; `system` is the real screen.
    public init(
        probe: @escaping @Sendable () async -> PermissionProbe, preflight: @escaping @Sendable () -> Bool,
        request: @escaping @Sendable () -> Void
    ) {
        self.probe = probe
        self.preflight = preflight
        self.request = request
    }

    /// The real screen, one per process: the setup row and every capture read the same answer.
    public static let system = ScreenRecordingAccess(
        probe: { await ScreenRecordingAccess.shareableContentProbe() },
        preflight: { CGPreflightScreenCaptureAccess() },
        request: { _ = CGRequestScreenCaptureAccess() })

    /// **The setup row's interaction, and the only request**: macOS shows its prompt (once ever; after that, the reader
    /// is sent to System Settings), the way to ScreenCaptureKit opens for this run, and the grant is probed.
    public func setUp() async -> PermissionProbe {
        state.withLock { $0.setUp = true }
        request()
        return await probed()
    }

    /// Whether ScreenCaptureKit may be called now without any chance of a prompt nobody asked for.
    public func mayTouchScreenCaptureKit() -> Bool {
        state.withLock { $0.setUp || $0.granted } || preflight()
    }

    /// What capture may do: **`notSetUp` without calling anything that can prompt**, otherwise the probe's answer.
    public func captureState() async -> ScreenRecordingState {
        guard mayTouchScreenCaptureKit() else { return .notSetUp }
        switch await probed() {
        case .granted: return .granted
        case .declined: return .declined
        case .couldNotTell: return .couldNotTell
        }
    }

    private func probed() async -> PermissionProbe {
        if state.withLock({ $0.granted }) { return .granted }
        let answer = await probe()
        if answer == .granted { state.withLock { $0.granted = true } }
        return answer
    }

    /// How long the probe may take before it counts as having said nothing: it bounds a wedged capture service, against a
    /// measured ~70 ms (XiaolaiDict). A duration, not a design value.
    static let probeDeadline: Duration = .seconds(3)

    /// **`SCShareableContent`, on-screen windows only, bounded** — the call the recogniser makes, so the answer is the one
    /// the reader will meet. Only the SDK's `userDeclined` is a refusal; anything else, a timeout included, is
    /// `couldNotTell`, logged by domain and code (the message may carry a path).
    static func shareableContentProbe() async -> PermissionProbe {
        let answer = Answer<PermissionProbe>()
        let probe = Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                answer.give(.granted)
            } catch let error as NSError
                        where error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue {
                answer.give(.declined)
            } catch {
                let failure = error as NSError
                Logger(subsystem: XDictIdentity.app, category: "capture").error(
                    "screen-recording probe failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
                answer.give(.couldNotTell)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: probeDeadline)
            answer.give(.couldNotTell)
        }
        let found = await answer.value()
        probe.cancel()
        timer.cancel()
        return found
    }
}
