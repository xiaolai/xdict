import Foundation

/// **The names macOS gives the permission lists** (XiaolaiDict's `PrivacySettings`, `49059e2`; the owner's rule that a
/// capability is named where the reader would choose it). macOS 27 renamed the Accessibility list to **Device Control and
/// Data Access** and Screen Recording to **Screen & System Audio Recording**; naming the old list sends a reader to a pane
/// that is no longer called that. The names are the system's own, so a translation is whatever the running macOS prints.
public enum PrivacySettings {
    /// The list a reader grants selection lookup and hover reading in.
    public static func accessibility(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> String {
        majorVersion >= 27
            ? String(localized: "Device Control and Data Access",
                     comment: "macOS 27's name for the Accessibility list — use the system's own wording")
            : String(localized: "Accessibility", comment: "The Accessibility permission, as macOS names it")
    }

    /// The list a reader grants screen reading in, for hover where an app shares no text.
    public static func screenRecording(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> String {
        majorVersion >= 27
            ? String(localized: "Screen & System Audio Recording",
                     comment: "macOS 27's name for the Screen Recording list — use the system's own wording")
            : String(localized: "Screen Recording", comment: "The Screen Recording permission, as macOS names it")
    }
}
