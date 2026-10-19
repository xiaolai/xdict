import AppKit
import XDictCapture

/// **The text under a point of one of XDict's own views, as the view itself answered it** — the entry's own script
/// (owner, 2026-10-19: hover reads XDict's own windows; verifier, 2026-10-19: an in-process Accessibility hit test over
/// XDict's own WKWebView waits on WebKit, which waits on the main thread — 1,530 ms on the build Mac, then -25204).
///
/// **A view's answer is data**, whatever world asked: taken only within the bound asked for, never empty, the offset on a
/// character of the text. The text is a window of the word's block around the word; `cut` names the ends that are cuts.
public struct OwnViewText: Sendable, Equatable {
    public let text: String
    /// Where the word starts in `text`, UTF-16.
    public let offset: Int
    public let cut: TextSegmenter.Clipping

    /// Nil unless `text` holds 1…`maxUTF16` UTF-16 units and `offset` falls on one of them.
    public init?(text: String, offset: Int, cutStart: Bool, cutEnd: Bool, maxUTF16: Int) {
        let count = text.utf16.count
        guard maxUTF16 > 0, count > 0, count <= maxUTF16, offset >= 0, offset < count else { return nil }
        self.text = text
        self.offset = offset
        var cut: TextSegmenter.Clipping = []
        if cutStart { cut.insert(.start) }
        if cutEnd { cut.insert(.end) }
        self.cut = cut
    }

    /// The word at `offset` and its sentence, by the segmenter every other dialect uses; nil off a word.
    public var word: WordAtPoint? { TextSegmenter.word(in: text, utf16Offset: offset, clipped: cut) }
}

/// A view's own reading of the word under the point: handed the most UTF-16 units it may answer, nil off a word.
public typealias OwnViewReading = @MainActor @Sendable (_ maxUTF16: Int) async -> OwnViewText?

/// What lies under a point of XDict's own window, **found by window and view geometry on the main actor — never by
/// Accessibility**.
public enum OwnView: Sendable {
    /// No web view there: XDict's native controls, which Accessibility answers on the main actor in a millisecond or
    /// two (10 ms for the first, measured 2026-10-19).
    case controls
    /// One of XDict's web views: **never asked through Accessibility**. Its own reading, or nil where nothing reads
    /// this view — then it is asked nothing at all.
    case webView(OwnViewReading?)
}

/// **Which of XDict's views is under a screen point**, by the window the compositor puts in front there and AppKit's own
/// hit test of that window's views.
@MainActor
public enum OwnViews {
    /// Whether `view` is a web view of WebKit's, of any subclass — by class name, so this target needs no WebKit: where
    /// WebKit is not loaded there is no web view.
    public nonisolated static func isWebView(_ view: NSView) -> Bool {
        NSClassFromString("WKWebView").map { view.isKind(of: $0) } ?? false
    }

    /// **The view under `point`** (global, y down) **in `window`**: the nearest web view holding AppKit's hit-test answer,
    /// handed to `reading` with the point in its own space, y down from its top — or controls where there is none.
    /// `primaryHeight` is the primary screen's height, which turns y down into AppKit's y up.
    public static func view(
        at point: CGPoint, in window: NSWindow?, primaryHeight: CGFloat, isWebView: (NSView) -> Bool = OwnViews.isWebView,
        reading: (NSView, CGPoint) -> OwnViewReading?
    ) -> OwnView {
        guard let window, let content = window.contentView else { return .controls }
        let inWindow = window.convertPoint(fromScreen: CGPoint(x: point.x, y: primaryHeight - point.y))
        // `hitTest` takes a point in the receiver's superview's space: the frame view's is the window's own.
        let frameView = content.superview ?? content
        var current = frameView.hitTest(inWindow)
        while let view = current, !isWebView(view) { current = view.superview }
        guard let web = current else { return .controls }
        let local = web.convert(inWindow, from: nil)
        let fromTop = CGPoint(x: local.x, y: web.isFlipped ? local.y : web.bounds.height - local.y)
        return .webView(reading(web, fromTop))
    }

    /// The window that takes a click at `point` (global, y down), where it is one of this process's: AppKit's own
    /// answer, which passes through a window that ignores the mouse as the hover notice does (measured 2026-10-19).
    public static func window(at point: CGPoint, primaryHeight: CGFloat) -> NSWindow? {
        let number = NSWindow.windowNumber(at: CGPoint(x: point.x, y: primaryHeight - point.y),
                                           belowWindowWithWindowNumber: 0)
        return number > 0 ? NSApp?.window(withWindowNumber: number) : nil
    }
}
