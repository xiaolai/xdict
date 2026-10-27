import AppKit
import Foundation

/// **Whether XDict shows a Dock icon** (owner, 2026-10-27: "allowing users choose whether show dock icon (default to no)"):
/// off for a reader who never chose — XDict lives in the menu bar, its windows open and close without it ever quitting,
/// and the menu-bar icon's own menu is where it is quit. Turning it on makes XDict an ordinary app in the Dock.
///
/// The policy is the system's: `.accessory` has no Dock icon and no application menu until one of its windows is active;
/// `.regular` is an ordinary app. Applied at launch by the app delegate, and again whenever the reader changes it.
public struct DockVisibility {
    public static let key = "showsInDock"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Off for a reader who never chose; a stored value that is not a Bool is no choice.
    public var showsInDock: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    public var policy: NSApplication.ActivationPolicy { showsInDock ? .regular : .accessory }

    /// The reader's choice, on the running app.
    @MainActor public func apply() {
        NSApp.setActivationPolicy(policy)
    }
}
