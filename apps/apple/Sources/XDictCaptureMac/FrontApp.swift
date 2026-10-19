import AppKit

/// The app a selection is read from, captured on the main actor before the Accessibility work moves off it.
public struct FrontApp: Hashable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?

    public init(pid: pid_t, name: String, bundleID: String?) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
    }

    /// The frontmost app, with a process ID Accessibility can use.
    @MainActor
    public static func frontmost() -> FrontApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(resolving)
    }

    /// `app`, with a process ID Accessibility can use (`ProcessResolver`): the window server is asked only when the
    /// reported one is not.
    @MainActor
    public static func resolving(_ app: NSRunningApplication) -> FrontApp? {
        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        let pid = ProcessResolver.pid(reported: app.processIdentifier, bundleID: app.bundleIdentifier,
                                      windowOwners: ordinaryWindowOwners())
        return pid.map { FrontApp(pid: $0, name: name, bundleID: app.bundleIdentifier) }
    }

    /// The owners of the on-screen ordinary windows, front to back, with their apps' bundle identifiers.
    @MainActor
    private static func ordinaryWindowOwners() -> [WindowOwner] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
            .map { WindowOwner(pid: $0, bundleID: NSRunningApplication(processIdentifier: $0)?.bundleIdentifier) }
    }
}

/// The process that owns an on-screen window, as the window server reports it.
public struct WindowOwner: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// **The real process behind an app** (moved from XiaolaiDict's `ProcessResolver`). On macOS 27 `NSWorkspace` reports
/// Safari — launched from a system cryptex — with process ID -1, and an Accessibility element built from that is invalid
/// (every attribute answers `kAXErrorInvalidUIElement`). Its windows belong to the real one.
public enum ProcessResolver {
    /// `reported` when it is valid; otherwise the owner of the app's frontmost window, matched by bundle identifier.
    /// `windowOwners` are front to back, and asked for only when `reported` is invalid — listing every window is work a
    /// valid ID does not need. Nil rather than a guess: reading the wrong process would look up another app's selection.
    public static func pid(
        reported: Int32, bundleID: String?, windowOwners: @autoclosure () -> [WindowOwner]
    ) -> Int32? {
        if reported > 0 { return reported }
        guard let bundleID else { return nil }
        return windowOwners().first { $0.bundleID == bundleID && $0.pid > 0 }?.pid
    }
}
