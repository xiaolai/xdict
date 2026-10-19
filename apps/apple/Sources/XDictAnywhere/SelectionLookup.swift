import CoreGraphics
import XDictCapture
import XDictCaptureMac

extension SelectionReader {
    /// **The selection read for lookup**: capture's reader (`XDictCaptureMac`, through the one lane) handed lookup's
    /// admission limit, which is the consumer's (XDict ADR-0014 decision 3) — so the shortcut and the Service refuse the
    /// same over-long selection the way `LookupText` does — and the reader's hover policy, whose excluded apps and sites
    /// decide whether the sentence around the selection is read (never defaulted: `HoverControl.policy`). `ownHolder`
    /// says what holds the selection in XDict's own window, its web views read by their own means (`OwnSelections`).
    public static func read(
        from app: FrontApp, clicked: CGPoint? = nil, excluding exclusions: HoverPolicy,
        ownHolder: @escaping @MainActor @Sendable () -> OwnSelectionHolder = { OwnSelections.keyWindowHolder { _ in nil } }
    ) async -> SelectionOutcome {
        await read(from: app, clicked: clicked, admitting: LookupText.admission, excluding: exclusions, ownHolder: ownHolder)
    }
}
