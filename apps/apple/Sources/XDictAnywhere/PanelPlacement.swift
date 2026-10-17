import CoreGraphics

/// **Where the lookup panel goes** (plan-macos-v1 WI-8: the panel "by the selection"), in AppKit's screen coordinates,
/// y up. With the word's box: centred across it, below it where the panel fits and above where it does not — the larger
/// side, the panel shrunk to it, where neither does — so it never covers the word it explains. Without one (an app that
/// cannot say, or the menu-bar command): below and right of the pointer. Always inside the screen's visible frame, by a
/// margin. Adapted from XiaolaiDict's `PanelPlacement`; the card's tail did not come (XDict's panel is a plain window).
public enum PanelPlacement {
    public static let margin: CGFloat = 8
    /// The gap kept between the panel and the word.
    public static let wordGap: CGFloat = 4
    /// How far right of and below the pointer the panel's top-left corner sits: clear of the cursor's own bitmap.
    public static let pointerGap = CGSize(width: 12, height: 24)

    /// The panel's height bounds (UI review P-03): small for a short entry, capped so a long one scrolls.
    public static let minimumHeight: CGFloat = 180
    public static let maximumHeight: CGFloat = 560
    public static let defaultHeight: CGFloat = 440

    /// The panel's height for an entry `document` points tall under `chrome` points of header; the default when the
    /// entry could not be measured.
    public static func height(document: Double?, chrome: CGFloat) -> CGFloat {
        guard let document, document.isFinite, document > 0 else { return defaultHeight }
        return min(max(CGFloat(document) + chrome, minimumHeight), maximumHeight)
    }

    public static func frame(size: CGSize, word: CGRect?, pointer: CGPoint, visible: CGRect) -> CGRect {
        let bounds = visible.insetBy(dx: margin, dy: margin)
        guard let word else {
            let wanted = CGRect(x: pointer.x + pointerGap.width, y: pointer.y - pointerGap.height - size.height,
                                width: size.width, height: size.height)
            return fitted(wanted, within: bounds)
        }
        let belowTop = min(bounds.maxY, word.minY - wordGap)
        let aboveBottom = max(bounds.minY, word.maxY + wordGap)
        let belowRoom = max(0, belowTop - bounds.minY), aboveRoom = max(0, bounds.maxY - aboveBottom)
        let goesBelow = belowRoom >= size.height || (aboveRoom < size.height && belowRoom >= aboveRoom)
        let height = min(size.height, goesBelow ? belowRoom : aboveRoom)
        let width = min(size.width, bounds.width)
        let x = clamp(word.midX - width / 2, bounds.minX, bounds.maxX - width)
        let y = goesBelow ? belowTop - height : aboveBottom
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// An Accessibility rectangle (y down from the primary screen's top-left) in AppKit's coordinates (y up from its
    /// bottom-left).
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Shrunk to the room, then clamped into it, anchored by its top edge.
    private static func fitted(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let width = max(0, min(rect.width, bounds.width)), height = max(0, min(rect.height, bounds.height))
        return CGRect(x: clamp(rect.minX, bounds.minX, bounds.maxX - width),
                      y: clamp(rect.maxY - height, bounds.minY, bounds.maxY - height), width: width, height: height)
    }

    /// Bounds in the wrong order — a room narrower than the panel — pin to the lower one.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
