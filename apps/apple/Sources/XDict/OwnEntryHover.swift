import AppKit
import XDictCaptureMac
import XDictEntryView

extension LookupAnywhere {
    /// **Hover over one of XDict's own entries asks the entry itself** (verifier, 2026-10-19): an Accessibility hit test
    /// of XDict's own web view waits on WebKit, which waits on the main thread. Only an entry view is read — by its own
    /// script, in the shell's world — and its answer is checked twice, in the shape the script writes
    /// (`EntryHoverText`) and against the bound asked for (`OwnViewText`). Any other web view of XDict's is asked nothing.
    static func readsOwnEntry(_ view: NSView, _ point: CGPoint) -> OwnViewReading? {
        guard let entry = view as? EntryWebView else { return nil }
        return { [weak entry] most in
            guard let entry, let reply = await entry.hoverText(at: point, maxUTF16: most) else { return nil }
            return OwnViewText(text: reply.text, offset: reply.offset, cutStart: reply.cutStart, cutEnd: reply.cutEnd,
                               maxUTF16: most)
        }
    }

    /// **A selection in one of XDict's own entries is asked of the entry itself** (owner, 2026-10-20: the shortcut, the
    /// menu and the Service capture its sentence too), for the same reason, by the same script, checked the same two
    /// ways (`EntrySelectionText`, `OwnSelectionText`); a reply whose text around the selection fails the second check is
    /// no answer at all. Any other web view of XDict's is asked nothing.
    static func readsOwnSelection(_ view: NSView) -> OwnSelectionReading? {
        guard let entry = view as? EntryWebView else { return nil }
        return { [weak entry] sentence, most in
            guard let entry else { return nil }
            switch await entry.selectionText(sentence: sentence, maxUTF16: most) {
            case nil: return nil
            case .tooLong: return .tooLong
            case .selected(let selected, let around):
                var shown: OwnViewText?
                if let around {
                    guard let checked = OwnViewText(text: around.text, offset: around.offset, cutStart: around.cutStart,
                                                    cutEnd: around.cutEnd, maxUTF16: most)
                    else { return nil }
                    shown = checked
                }
                return OwnSelectionText(selected: selected, around: shown, maxUTF16: most).map(OwnSelectionAnswer.selected)
            }
        }
    }

    /// What holds the selection in the window the reader is working in, its entries read by their own script.
    static let ownSelectionHolder: @MainActor @Sendable () -> OwnSelectionHolder = {
        OwnSelections.keyWindowHolder(reading: readsOwnSelection)
    }
}
