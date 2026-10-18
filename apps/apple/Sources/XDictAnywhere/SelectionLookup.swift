import CoreGraphics
import XDictCaptureMac

extension SelectionReader {
    /// **The selection read for lookup**: capture's reader (`XDictCaptureMac`, through the one lane) handed lookup's
    /// admission limit, which is the consumer's (XDict ADR-0014 decision 3) — so the shortcut and the Service refuse the
    /// same over-long selection the way `LookupText` does, and the app's call sites read as they did before the reader
    /// moved down.
    public static func read(from app: FrontApp, clicked: CGPoint? = nil) async -> SelectionOutcome {
        await read(from: app, clicked: clicked, admitting: LookupText.admission)
    }
}
