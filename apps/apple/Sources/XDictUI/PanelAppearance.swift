import AppKit
import Foundation

/// **How the lookup popup's background looks, as the reader set it** (Settings ▸ General; owner, 2026-10-18: its
/// lightness and glass effect). Two choices, both safe for the entry's text: a shade (follow the system, or always
/// light, or always dark: the popup's text colours follow its appearance) and how solid the surface is (0 the
/// system's glass as it was, 1 an opaque window colour). A solid surface only raises the text's contrast over the
/// glass, so no setting can leave the text unreadable.
public struct PanelAppearance: Equatable, Sendable {
    public enum Shade: String, CaseIterable, Sendable { case system, light, dark }

    public static let shadeKey = "panel.shade"
    public static let solidityKey = "panel.solidity"

    public var shade: Shade
    /// 0 (glass) to 1 (opaque).
    public var solidity: Double

    public init(shade: Shade = .system, solidity: Double = 0) {
        self.shade = shade
        self.solidity = solidity.isFinite ? min(max(solidity, 0), 1) : 0
    }

    public static func current(in defaults: UserDefaults) -> PanelAppearance {
        PanelAppearance(shade: defaults.string(forKey: shadeKey).flatMap(Shade.init(rawValue:)) ?? .system,
                        solidity: defaults.object(forKey: solidityKey) as? Double ?? 0)
    }

    /// The appearance the popup is forced to, or nil to follow the system.
    public var appearance: NSAppearance? {
        switch shade {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
