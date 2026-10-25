import AppKit
import WebKit
import XDictTokens

/// **The context menu, stripped to what keeps the reader in XDict** (ADR-0009 decision 7): WebKit's default menu opens a
/// link in a new window, downloads a linked file or an image, opens an image, copies a link — each a way out that no
/// navigation delegate is asked about the same way. An allowlist, not a list of what to remove: an item a later WebKit
/// adds is gone until it is judged.
public enum EntryMenu {
    /// WebKit's identifiers for the items kept: copying the selection, Look Up, Translate, and Speech.
    public static let kept: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierSpeechMenu",
    ]

    /// Removes every item not kept, then the separators left leading, trailing or doubled. Returns what was kept and
    /// what was removed, by identifier (or title, for an item with none), for the log.
    @MainActor
    @discardableResult
    public static func filter(_ menu: NSMenu) -> (kept: [String], removed: [String]) {
        var keptNames: [String] = [], removedNames: [String] = []
        for item in menu.items where !item.isSeparatorItem {
            let name = item.identifier?.rawValue ?? "untitled: \(item.title)"
            if let id = item.identifier?.rawValue, kept.contains(id) {
                keptNames.append(name)
            } else {
                removedNames.append(name)
                menu.removeItem(item)
            }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item); continue }
            previousWasSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return (keptNames, removedNames)
    }
}

/// The entry's web view: WebKit's, with its context menu filtered before it opens.
@MainActor
public final class EntryWebView: WKWebView {
    var onMenu: ((_ kept: [String], _ removed: [String]) -> Void)?
    /// A frame of the All page (parity P15) is as tall as its document, so the page scrolls, not the frame: the wheel
    /// goes to the page's scroll view.
    var passesScrollToPage = false
    /// Where Shift-Tab out of the entry goes (the window's results list), asked when the key is pressed, so a frame made
    /// later or a key-view loop the window recalculated cannot send it elsewhere.
    weak var keyViewPredecessor: NSView?

    override public var previousValidKeyView: NSView? {
        if let predecessor = keyViewPredecessor, predecessor.canBecomeKeyView { return predecessor }
        return super.previousValidKeyView
    }

    /// A capped frame scrolls its own document (audit round 4, 2026-10-25), and hands the wheel to the page when its
    /// document's edge is reached; a frame as tall as its document passes every wheel event to the page.
    var scrollsInternally = false
    /// **The document's own scroll position** (audit round 4, 2026-10-25): its scroll and resize listener reports
    /// `(y, max)` here, because macOS's `WKWebView` has no public `scrollView` to ask.
    var innerScroll = (y: 0.0, max: 0.0)

    override public func scrollWheel(with event: NSEvent) {
        guard passesScrollToPage, let page = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        guard scrollsInternally else {
            page.scrollWheel(with: event)
            return
        }
        let up = event.scrollingDeltaY > 0
        let edge = Tokens.Window.scrollEdgeTolerance
        if (up && innerScroll.y <= edge) || (!up && innerScroll.y >= innerScroll.max - edge) {
            page.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let (kept, removed) = EntryMenu.filter(menu)
        onMenu?(kept, removed)
        super.willOpenMenu(menu, with: event)
    }
}
