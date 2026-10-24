import Foundation
import CoreText
import Synchronization
import Vision
import XDictCapture

/// **Vision warmed once, before the first hover that needs it** (coordinator's brief, 2026-10-19). Vision's first text
/// recognition after a long idle took 25,469 ms on the build Mac, and the next ones 23–38 ms; fresh processes after it
/// took 78–80 ms for their first (measured 2026-10-19 with the recogniser's own settings). The load is the system's,
/// not the process's, and alone it outlasts the capture deadline (5 s), so the first hover after idle reported a stuck
/// capture. One recognition of a small drawn image pays it in the background.
///
/// **Nothing but Vision**: the image is drawn here, never captured, so ScreenCaptureKit is not reached and nothing can
/// prompt; Vision asks for no permission. The answer is discarded and nothing about it is logged.
extension ScreenTextRecogniser {
    /// One recognition of `warmUpImage()` on a background dispatch queue: off the main actor, off the lane and **off Swift
    /// concurrency's pool** (verifier, 2026-10-19), whose few threads every task of the app shares — a 25-second call
    /// there holds one of them. Fire-and-forget: it holds nothing anyone waits on — hover's start, the capture guard,
    /// quitting — and is bounded by being one call on a 160 × 32 pixel image.
    public static func warmUp() {
        warmUp(recognise: { try recogniseWhole($0) })
    }

    /// `done` is a test's, called once the recognition has returned.
    static func warmUp(
        recognise: @escaping @Sendable (CGImage) throws -> [RecognisedLine], done: (@Sendable () -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .background).async {
            if let image = warmUpImage() { _ = try? recognise(image) }
            done?()
        }
    }

    /// Whether Vision has gone unanswered in this process for `interval` at `now` — never answered counts.
    public static func idle(for interval: Duration, at now: ContinuousClock.Instant) -> Bool {
        lastAnswered.withLock { last in last.map { now - $0 >= interval } ?? true }
    }

    /// A short word in the system font, black on white: enough for Vision to load its text models, not only its setup.
    static func warmUpImage() -> CGImage? {
        let (width, height) = (160, 32)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        // Size 0: the system font at its default size.
        guard let font = CTFontCreateUIFontForLanguage(.system, 0, nil) else { return nil }
        let word = NSAttributedString(string: "Look up", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.textPosition = CGPoint(x: 6, y: 10)
        CTLineDraw(CTLineCreateWithAttributedString(word), context)
        return context.makeImage()
    }
}

/// **Vision kept warm while hover watches** (owner, 2026-10-19: the OCR stall must be fixed). Measured that day on the
/// build Mac, in fresh processes with the recogniser's own settings: Vision's text models are dropped system-wide after
/// some minutes with no recognition, and the next first call takes 24.2 s (Latin; 14.1 s more for Arabic, a model of its
/// own) where a warm one takes 30–110 ms — so a warm-up at launch only moved the 24 s stall to the first hover after a
/// pause. A ScreenCaptureKit screenshot of the same strip took 65–144 ms and the window list 15–23 ms: not the stall.
///
/// **One warm-up each `interval` in which Vision answered nothing**, through the same background job as the launch's
/// (`ScreenTextRecogniser.warmUp`): a reader hovering keeps it warm by reading, and pays nothing extra. Started and
/// stopped with the watcher; a test's `warm`, `idle` and `sleep` replace the real ones.
@MainActor
public final class RecognitionKeepWarm {
    /// Under the shortest drop measured (see the type's note), so a warm model never lapses between two ticks.
    public static let interval: Duration = .seconds(120)

    private let interval: Duration
    private let warm: @MainActor () -> Void
    private let idle: @MainActor (Duration) -> Bool
    private let sleep: @Sendable (Duration) async -> Void
    private var ticking: Task<Void, Never>?

    public init(
        interval: Duration = RecognitionKeepWarm.interval,
        warm: @escaping @MainActor () -> Void = { ScreenTextRecogniser.warmUp() },
        idle: @escaping @MainActor (Duration) -> Bool = { ScreenTextRecogniser.idle(for: $0, at: .now) },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.warm = warm
        self.idle = idle
        self.sleep = sleep
    }

    public var isRunning: Bool { ticking != nil }

    /// Starts ticking; a second start while running does nothing.
    public func start() {
        guard ticking == nil else { return }
        let interval = interval, sleep = sleep
        ticking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                if self.idle(interval) { self.warm() }
            }
        }
    }

    public func stop() {
        ticking?.cancel()
        ticking = nil
    }
}
