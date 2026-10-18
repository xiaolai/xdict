import CoreGraphics
import XDictTokens

/// **The lookup popover's size, and the word it points at** (plan-macos-v1 WI-8; P41): its width and the height bounds
/// its entry is fitted within, and the selection's Accessibility rectangle in AppKit's screen coordinates (y up), where
/// its anchor goes. Where the popover sits beside that anchor is AppKit's (`LookupPopover`).
public enum PanelPlacement {
    /// Kept clear of the screen's edges when the room for the entry is measured.
    public static let margin: CGFloat = Tokens.Inset.panelScreenMargin

    /// The panel's height bounds (Codex's UX decision §3, 2026-10-17): header plus the entry, 140–560 pt, opening at
    /// 180 pt while the entry loads.
    public static let minimumHeight: CGFloat = Tokens.Window.panelMinHeight
    public static let maximumHeight: CGFloat = Tokens.Window.panelMaxHeight
    public static let initialHeight: CGFloat = Tokens.Window.panelInitialHeight
    /// Its width: 390 pt, the Look Up popover's body (P41, 2026-10-17); 360 and 640 bound it.
    public static let widths: (min: CGFloat, default: CGFloat, max: CGFloat) = (
        Tokens.Window.panelMinWidth, Tokens.Window.popoverBody, Tokens.Window.panelMaxWidth)

    /// The panel's height for an entry `document` points tall under `chrome` points of header, within the bounds and
    /// the room `available` beside the selection; the opening height when the entry could not be measured.
    public static func height(document: Double?, chrome: CGFloat, available: CGFloat = .infinity) -> CGFloat {
        guard let document, document.isFinite, document > 0 else { return min(initialHeight, available) }
        return min(min(max(CGFloat(document) + chrome, minimumHeight), maximumHeight), available)
    }

    /// An Accessibility rectangle (y down from the primary screen's top-left) in AppKit's coordinates (y up from its
    /// bottom-left).
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
