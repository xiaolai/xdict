import SwiftUI
import XDictTokens

/// **The lookup panel's metrics, the system Look Up popover's own** (P41; owner, 2026-10-17: the panel imitates the
/// popover). Measured on macOS 27.0.1 through the popover's Accessibility tree over a TextEdit document
/// (`dev-docs/artifacts/apple-dictionary/apple/popover.*`): a 390 pt body; a 16 pt space, then a 24 pt title row in the
/// system font at 20 pt, 24 pt from the body's edge, a rule after it to 27 pt from the other edge; the entry; then rows of
/// 26 pt ("Open in Dictionary", "Configure Dictionaries"), each under an 8 pt gap and a hairline, text 26 pt in and an
/// icon at the trailing inset.
public enum PanelLook {
    public static var titleSize: CGFloat { Tokens.TextRole.panelTitle.nsFont.pointSize }
    public static let leading: CGFloat = Tokens.Inset.panelLeading
    public static let trailing: CGFloat = Tokens.Inset.panelTrailing
    public static let topSpace: CGFloat = Tokens.Inset.panelTop
    public static let titleRow: CGFloat = Tokens.Row.panelTitle
    public static let footerRow: CGFloat = Tokens.Row.panelFooter
    public static let footerGap: CGFloat = Tokens.Inset.panelFooterGap
    public static let footerLeading: CGFloat = Tokens.Inset.panelFooterLeading
    public static var footerFontSize: CGFloat { Tokens.TextRole.panelFooter.nsFont.pointSize }
    /// Under the last footer row: the popover's 8 pt row spacing (its table's), so the row never sits on the edge.
    public static let bottomInset: CGFloat = Tokens.Inset.panelBottom
    /// The entry's last 16 pt fade to clear above the footer: scrolled text never meets the footer's hairline.
    public static let entryFade: CGFloat = Tokens.Inset.panelEntryFade
}
