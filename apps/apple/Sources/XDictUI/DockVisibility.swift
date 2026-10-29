import AppKit
import SwiftUI

/// **Whether XDict shows a Dock icon** (owner, 2026-10-27: "allowing users choose whether show dock icon (default to no)"):
/// off for a reader who never chose — XDict lives in the menu bar, its windows open and close without it ever quitting,
/// and the menu-bar icon's own menu is where it is quit. Turning it on makes XDict an ordinary app in the Dock.
///
/// **A main window brings the icon whether the switch is on or not** (owner, 2026-10-29: "when dictionary main window is
/// opening, the dock icon should show up"): a reader reading in a window sees the app in the Dock while that window is
/// open, and XDict goes back to the menu bar alone when the last one closes (`DockPresence`).
///
/// The policy is the system's: `.accessory` has no Dock icon; `.regular` is an ordinary app. Applied at launch by the app
/// delegate, and again whenever the reader changes it or a window opens or closes.
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

}

/// **The running app's Dock presence** (owner, 2026-10-29): the reader's switch, or a main window being open — whichever
/// comes first. Closing the last main window puts XDict back in the menu bar alone, which is what a reader who never
/// turned the switch on expects of a menu-bar dictionary; the switch keeps the icon there with no window at all.
///
/// SwiftUI has no activation policy: AppKit is the boundary, and an `NSWindow` is the thing that can say it is open.
/// A window registers itself through `DockPresenceProbe` (the main window's scene does), and the notification that it is
/// closing takes it out again — the same signal whether the reader closes it, a tab closes, or the app quits.
@MainActor
public final class DockPresence: NSObject {
    /// The app's one presence, over the reader's own defaults.
    public static let shared = DockPresence(defaults: .standard)

    private let defaults: UserDefaults
    /// How the policy reaches the running app; a test records it instead of changing its own process.
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    /// The main windows open now, by identity. Weak: a window that goes without its closing notification is no window.
    private var open: [ObjectIdentifier: WeakWindow] = [:]

    /// `AnyObject`, not `NSWindow`: a test process cannot make an `NSApplication` (`NSApplication.shared` alone seizes
    /// it), so the registry is stated over what can be observed — the window's identity — and the app passes `NSWindow`.
    private struct WeakWindow {
        weak var window: AnyObject?
    }

    public init(defaults: UserDefaults,
                setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.defaults = defaults
        self.setPolicy = setPolicy
        super.init()
    }

    /// **The policy the switch and the open windows give**: a Dock icon while a main window is open, or always for a
    /// reader who asked for one; otherwise the menu bar alone.
    public var policy: NSApplication.ActivationPolicy {
        if DockVisibility(defaults: defaults).showsInDock || !open.isEmpty { return .regular }
        return .accessory
    }

    /// Whether any main window is open now.
    public var hasWindow: Bool { !open.isEmpty }

    /// Puts the policy on the running app.
    public func apply() {
        setPolicy(policy)
    }

    /// A main window is open: the Dock icon comes with it. Idempotent — SwiftUI moves a window's views about, and only
    /// the window's own closing takes it out again.
    public func opened(_ window: AnyObject) {
        let id = ObjectIdentifier(window)
        guard open[id]?.window !== window else { return }
        open[id] = WeakWindow(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        prune()
        apply()
    }

    /// **A window closed**: it stops counting, and the last one returns XDict to the menu bar alone.
    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object else { return }
        open[ObjectIdentifier(window as AnyObject)] = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        prune()
        apply()
    }

    /// Forgets windows that went without their closing notification, so a stale entry never holds the icon up.
    private func prune() {
        open = open.filter { $0.value.window != nil }
    }
}

/// **A main window's Dock presence, attached in its scene** (owner, 2026-10-29): the view joins the window and tells
/// `DockPresence`; the window's own closing notification takes it out again. AppKit here is the activation policy, which
/// SwiftUI has no API for.
public struct DockPresenceProbe: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> Probe { Probe() }
    public func updateNSView(_ probe: Probe, context: Context) {}

    public final class Probe: NSView {
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DockPresence.shared.opened(window)
        }
    }
}
