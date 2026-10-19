import AppKit
import Foundation
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
    /// One recognition of `warmUpImage()`, detached at background priority: off the main actor and off the lane,
    /// fire-and-forget. It holds nothing anyone waits on — hover's start, the capture guard, quitting — and is bounded by
    /// being one call on a 160 × 32 pixel image. The task is returned only for a test to wait on.
    @discardableResult
    public static func warmUp() -> Task<Void, Never> {
        warmUp(recognise: { try recogniseWhole($0) })
    }

    static func warmUp(recognise: @escaping @Sendable (CGImage) throws -> [RecognisedLine]) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            guard let image = warmUpImage() else { return }
            _ = try? recognise(image)
        }
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
