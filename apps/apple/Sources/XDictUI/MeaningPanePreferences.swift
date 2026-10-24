import Foundation
import XDictTokens

/// **The answer pane's own preferences** (owner, 2026-10-24: the gap between the pane and the main window is the
/// reader's). The token is the default; Settings ▸ General writes the same key.
public enum MeaningPanePreferences {
    public static let gapKey = "meaningPane.gap"
    public static let defaultGap = Double(Tokens.Window.paneGap)
    public static let gapRange: ClosedRange<Double> = 0...40

    /// The gap in points, the stored value held within `gapRange`.
    public static func gap(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: gapKey) as? Double ?? defaultGap
        return CGFloat(min(max(stored, gapRange.lowerBound), gapRange.upperBound))
    }
}
