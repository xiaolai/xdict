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
}
