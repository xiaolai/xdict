import CoreGraphics
import XDictCapture
import XDictCaptureMac

extension SelectionReader {
    /// **The selection read for lookup**: capture's reader (`XDictCaptureMac`, through the one lane) handed lookup's
    /// admission limit, which is the consumer's (XDict ADR-0014 decision 3) — so the shortcut and the Service refuse the
    /// same over-long selection the way `LookupText` does — and the reader's hover policy, whose excluded apps and sites
    /// decide whether the sentence around the selection is read (never defaulted: `HoverControl.policy`).
    public static func read(from app: FrontApp, clicked: CGPoint? = nil, excluding exclusions: HoverPolicy) async
        -> SelectionOutcome {
        await read(from: app, clicked: clicked, admitting: LookupText.admission, excluding: exclusions)
    }
}
