import AppKit
import WebKit

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

    override public func scrollWheel(with event: NSEvent) {
        if passesScrollToPage, let page = enclosingScrollView {
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
