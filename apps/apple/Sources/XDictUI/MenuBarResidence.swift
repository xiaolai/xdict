import Foundation

/// **Whether closing the last window leaves XDict running in the menu bar** (Settings ▸ General; XiaolaiDict's menu-bar
/// app never quit with its windows, ported as a switch, on by default): on, the menu-bar item, the lookup shortcut, the
/// Service and hover stay; off, XDict quits with its last window. The menu-bar item itself is always inserted: it is where
/// the scene's actions are handed over (`MenuBarLabel`), and inserting it conditionally (`MenuBarExtra(isInserted:)`)
/// rebuilt the main menu forever on macOS 27 (`ui-fix`, 2026-10-17).
public struct MenuBarResidence {
    public static let key = "keepsRunningInMenuBar"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// On for a reader who never chose; a stored value that is not a Bool is no choice.
    public var keepsRunning: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// What `applicationShouldTerminateAfterLastWindowClosed` answers.
    public var terminatesAfterLastWindowClosed: Bool { !keepsRunning }
}
