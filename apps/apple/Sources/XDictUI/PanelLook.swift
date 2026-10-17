import SwiftUI

/// **The lookup panel's metrics, the system Look Up popover's own** (P41; owner, 2026-10-17: the panel imitates the
/// popover). Measured on macOS 27.0.1 through the popover's Accessibility tree over a TextEdit document
/// (`dev-docs/artifacts/apple-dictionary/apple/popover.*`): a 390 pt body; a 16 pt space, then a 24 pt title row in the
/// system font at 20 pt, 24 pt from the body's edge, a rule after it to 27 pt from the other edge; the entry; then rows of
/// 26 pt ("Open in Dictionary", "Configure Dictionaries"), each under an 8 pt gap and a hairline, text 26 pt in and an
/// icon at the trailing inset.
public enum PanelLook {
    public static let titleSize: CGFloat = 20
    public static let leading: CGFloat = 24
    public static let trailing: CGFloat = 27
    public static let topSpace: CGFloat = 16
    public static let titleRow: CGFloat = 24
    public static let footerRow: CGFloat = 26
    public static let footerGap: CGFloat = 8
    public static let footerLeading: CGFloat = 26
    public static let footerFontSize: CGFloat = 13
}
