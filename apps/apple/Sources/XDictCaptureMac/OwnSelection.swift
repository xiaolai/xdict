import AppKit
import XDictCapture

/// **The selection in one of XDict's own web views, as the view itself answered it** (owner, 2026-10-20: the shortcut,
/// the menu and the Service capture the sentence in XDict's own windows too). An Accessibility request about XDict's own
/// web view waits on WebKit, which waits on the main thread (ADR-0014 d.6), so the entry's own script answers instead.
///
/// **A view's answer is data**, whatever world asked: the selection 1…`maxUTF16` UTF-16 units, and the text around it,
/// where there is one, holding the selection exactly at its offset.
public struct OwnSelectionText: Sendable, Equatable {
    /// The selected text as shown, whitespace and punctuation included: the term is taken from it as from any selection.
    public let selected: String
    /// The shown text of the selection's block around it, the selection at `offset`; nil where it was not asked for, or
    /// the view had none (a selection across blocks).
    public let around: OwnViewText?

    /// Nil unless `selected` holds 1…`maxUTF16` UTF-16 units and `around`, where given, holds it at its offset.
    public init?(selected: String, around: OwnViewText?, maxUTF16: Int) {
        let length = (selected as NSString).length
        guard maxUTF16 > 0, length > 0, length <= maxUTF16 else { return nil }
        if let around {
            let text = around.text as NSString
            guard around.offset <= text.length - length,
                  text.substring(with: NSRange(location: around.offset, length: length)) == selected
            else { return nil }
        }
        self.selected = selected
        self.around = around
    }
}

/// A web view's answer about its selection: what is selected, or that it is longer than the view was asked to read —
/// said, never cut.
public enum OwnSelectionAnswer: Sendable, Equatable {
    case selected(OwnSelectionText)
    case tooLong
}

/// A web view's own reading of its selection: asked for the text around it or not (`sentence`), and handed the most
/// UTF-16 units it may answer for either; nil where nothing shown is selected.
public typealias OwnSelectionReading = @MainActor @Sendable (_ sentence: Bool, _ maxUTF16: Int) async -> OwnSelectionAnswer?

/// What holds the selection in XDict's own key window, **found by AppKit's first responder on the main actor — never
/// by Accessibility**.
public enum OwnSelectionHolder: Sendable {
    /// XDict's native controls: Accessibility answers them on the main actor in a millisecond or two (ADR-0018).
    case controls
    /// One of XDict's web views: **never asked through Accessibility**. Its own reading, or nil where nothing reads
    /// this view — then it is asked nothing at all.
    case webView(OwnSelectionReading?)
    /// A secure field, or the field editor editing one: asked nothing.
    case refused
}

@MainActor
public enum OwnSelections {
    /// **What holds the selection in `window`**: its first responder, or the nearest web view holding it (any
    /// `WKWebView`: its content's responders are inside it), handed to `reading`; a secure field is refused; anything
    /// else, and no window at all, is a native control — Accessibility's focused element of XDict's own application,
    /// which with no key window is not a web view's either.
    public static func holder(
        in window: NSWindow?, isWebView: (NSView) -> Bool = OwnViews.isWebView, reading: (NSView) -> OwnSelectionReading?
    ) -> OwnSelectionHolder {
        guard let responder = window?.firstResponder else { return .controls }
        if isSecure(responder) { return .refused }
        var current = responder as? NSView
        while let view = current, !isWebView(view) { current = view.superview }
        guard let web = current else { return .controls }
        return .webView(reading(web))
    }

    /// The holder in the window the reader is working in: the key window, else the main one.
    public static func keyWindowHolder(reading: (NSView) -> OwnSelectionReading?) -> OwnSelectionHolder {
        holder(in: NSApp?.keyWindow ?? NSApp?.mainWindow, reading: reading)
    }

    /// A secure text field, or the field editor editing one: AppKit gives the editor the keyboard, and its delegate is the
    /// field.
    public static func isSecure(_ responder: NSResponder) -> Bool {
        if responder is NSSecureTextField { return true }
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate is NSSecureTextField
    }
}
