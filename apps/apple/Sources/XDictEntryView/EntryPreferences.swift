import Foundation

/// How an entry is coloured (R4: "app theme plus compatible per-dictionary theme / original mode; no invisible text").
public enum EntryTheme: String, CaseIterable, Sendable {
    /// Light when the app is light. Dark when the app is dark, **the dictionary's own colours kept unless unreadable**:
    /// a colour that falls below 3:1 against what it is drawn on is replaced by black or white, whichever reads.
    case matchApp
    /// The dictionary's own colours on a light page, whatever the app's appearance.
    case original
    /// Dark always, with the same readability rule as `matchApp`.
    case dark

    /// What the page is drawn as, given the app's appearance.
    public func scheme(appIsDark: Bool) -> EntryColourScheme {
        switch self {
        case .matchApp: appIsDark ? .dark : .light
        case .original: .light
        case .dark: .dark
        }
    }
}

public enum EntryColourScheme: String, Sendable {
    case light, dark
}

/// **The reader's choices per dictionary, kept across launches** (R2, R4): zoom and theme, under the binding's
/// `dictionary` (its lineage), in the app's own defaults. What is read back is held to what the view can show: a zoom
/// outside the range, or a theme this version does not know, reads as the default.
public struct EntryPreferences: @unchecked Sendable {
    // `UserDefaults` is documented thread-safe; it is not marked `Sendable`.
    private let defaults: UserDefaults

    public static let zoomRange: ClosedRange<Double> = 0.5...3.0
    public static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func zoomKey(_ dictionary: String) -> String { "entry.zoom.\(dictionary)" }
    static func themeKey(_ dictionary: String) -> String { "entry.theme.\(dictionary)" }

    public func zoom(for dictionary: String) -> Double {
        let stored = defaults.double(forKey: Self.zoomKey(dictionary))
        return Self.zoomRange.contains(stored) ? stored : 1.0
    }

    public func setZoom(_ zoom: Double, for dictionary: String) {
        defaults.set(min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound), forKey: Self.zoomKey(dictionary))
    }

    public func theme(for dictionary: String) -> EntryTheme {
        defaults.string(forKey: Self.themeKey(dictionary)).flatMap(EntryTheme.init(rawValue:)) ?? .matchApp
    }

    public func setTheme(_ theme: EntryTheme, for dictionary: String) {
        defaults.set(theme.rawValue, forKey: Self.themeKey(dictionary))
    }

    /// The next step up or down from `zoom`, within the range.
    public static func step(_ zoom: Double, up: Bool) -> Double {
        if up { return zoomSteps.first { $0 > zoom + 0.001 } ?? zoomRange.upperBound }
        return zoomSteps.last { $0 < zoom - 0.001 } ?? zoomRange.lowerBound
    }
}
