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

/// **The reader's choices, kept across launches** (R2, R4): the text size, for every dictionary; the theme, under the
/// binding's `dictionary` (its lineage), in the app's own defaults. What is read back is held to what the view can show: a zoom
/// outside the range, or a theme this version does not know, reads as the default.
public struct EntryPreferences: @unchecked Sendable {
    // `UserDefaults` is documented thread-safe; it is not marked `Sendable`.
    private let defaults: UserDefaults

    public static let zoomRange: ClosedRange<Double> = 0.5...3.0
    public static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let zoomKey = "entry.textSize"
    static func themeKey(_ dictionary: String) -> String { "entry.theme.\(dictionary)" }
    public static func originalStyleKey(_ dictionary: String) -> String { "entry.originalStyle.\(dictionary)" }
    /// The reading style's accent, for every dictionary (Settings ▸ Reading).
    public static let accentKey = "reading.accent"

    /// The accent; teal unless chosen, and teal for a value this version does not know.
    public func accent() -> EntryReadingFrame.Accent {
        defaults.string(forKey: Self.accentKey).flatMap(EntryReadingFrame.Accent.init(rawValue:)) ?? .teal
    }

    public func setAccent(_ accent: EntryReadingFrame.Accent) {
        defaults.set(accent.rawValue, forKey: Self.accentKey)
    }

    /// The dictionary shown in its own style, without XDict's reading frame (ADR-0010 Q3). Off unless chosen.
    public func originalStyle(for dictionary: String) -> Bool {
        defaults.bool(forKey: Self.originalStyleKey(dictionary))
    }

    public func setOriginalStyle(_ original: Bool, for dictionary: String) {
        defaults.set(original, forKey: Self.originalStyleKey(dictionary))
    }

    /// Where the reader's choice of a display option is kept for a dictionary (ADR-0013 d.4): per option, per lineage.
    public static func displayChoiceKey(_ option: String, _ dictionary: String) -> String {
        "entry.option.\(option).\(dictionary)"
    }

    /// The reader's choice of a display option for this dictionary, as stored: an intent, kept whatever any edition
    /// declares. Nil until chosen.
    public func storedDisplayChoice(_ option: String, for dictionary: String) -> String? {
        defaults.string(forKey: Self.displayChoiceKey(option, dictionary))
    }

    public func setDisplayChoice(_ value: String, option: String, for dictionary: String) {
        defaults.set(value, forKey: Self.displayChoiceKey(option, dictionary))
    }

    /// **The effective choice** (ADR-0013 d.4): the stored intent where the edition declares that value, else the
    /// edition's default. A value it does not declare stays stored and inactive; it never hides the only variant, which
    /// the core's CSS hides only beside another.
    public func displayChoice(_ option: EntryDisplayOption, for dictionary: String) -> String {
        Self.effective(storedDisplayChoice(option.id, for: dictionary), of: option)
    }

    /// A stored intent resolved against what an edition declares: itself where declared, else the edition's default.
    public static func effective(_ stored: String?, of option: EntryDisplayOption) -> String {
        guard let stored, option.values.contains(stored) else { return option.defaultValue }
        return stored
    }

    /// The value of every option the edition declares, the default included: what the page's root is given.
    public func displayValues(_ options: EntryDisplayOptions, for dictionary: String) -> [EntryDisplayValue] {
        options.options.map { EntryDisplayValue(attribute: $0.attribute, value: displayChoice($0, for: dictionary)) }
    }

    /// The text size, one for every dictionary, as Apple's Dictionary has it (parity P29, owner 2026-10-17; it was per
    /// dictionary, ADR-0010 d.3).
    public func zoom() -> Double {
        let stored = defaults.double(forKey: Self.zoomKey)
        return Self.zoomRange.contains(stored) ? stored : 1.0
    }

    public func setZoom(_ zoom: Double) {
        defaults.set(min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound), forKey: Self.zoomKey)
    }

    public func theme(for dictionary: String) -> EntryTheme {
        defaults.string(forKey: Self.themeKey(dictionary)).flatMap(EntryTheme.init(rawValue:)) ?? .matchApp
    }

    public func setTheme(_ theme: EntryTheme, for dictionary: String) {
        defaults.set(theme.rawValue, forKey: Self.themeKey(dictionary))
    }

    static func collapsedKey(_ dictionary: String) -> String { "entry.page.collapsed.\(dictionary)" }

    /// Whether this dictionary's section of the All page is collapsed to its divider (parity P15), as the reader last
    /// left it. Expanded unless chosen.
    public func collapsed(for dictionary: String) -> Bool {
        defaults.bool(forKey: Self.collapsedKey(dictionary))
    }

    public func setCollapsed(_ collapsed: Bool, for dictionary: String) {
        defaults.set(collapsed, forKey: Self.collapsedKey(dictionary))
    }

    /// The next step up or down from `zoom`, within the range.
    public static func step(_ zoom: Double, up: Bool) -> Double {
        if up { return zoomSteps.first { $0 > zoom + 0.001 } ?? zoomRange.upperBound }
        return zoomSteps.last { $0 < zoom - 0.001 } ?? zoomRange.lowerBound
    }
}
