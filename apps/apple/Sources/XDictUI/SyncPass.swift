import AppKit
import Foundation
import Observation
import XDictContract

/// **One sync pass, as Settings ▸ Learning shows it** (UI40): whether one is running (a second Sync Now starts
/// nothing), how the last one ended, when one last succeeded (kept across launches), and disconnect. The folder access
/// is handed back after every pass. The merge itself is the core's; `perform` is that call.
@MainActor
@Observable
public final class SyncPass {
    public enum Phase: Equatable, Sendable {
        /// Nothing said yet: no pass since the pane opened, or the folder was just chosen or disconnected.
        case idle
        case synced(added: UInt64, peers: UInt64)
        case failed
        /// The bookmark no longer opens: the folder was deleted, unmounted, or its permission withdrawn.
        case folderUnavailable
        case noFolder
    }

    public typealias Open = @MainActor (Data) -> (path: String, stop: () -> Void)?
    public typealias Perform = @MainActor (String) async -> SyncReport?

    public private(set) var isRunning = false
    public private(set) var phase: Phase = .idle
    public private(set) var lastSuccess: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let open: Open
    @ObservationIgnored private let perform: Perform
    /// Bumped by `disconnect`: a pass that was running then does not report into the disconnected pane.
    @ObservationIgnored private var generation = 0

    static let lastSuccessKey = "learning.sync.lastSuccess"

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
                open: @escaping Open = { SyncFolder.open($0) }, perform: @escaping Perform) {
        self.defaults = defaults
        self.now = now
        self.open = open
        self.perform = perform
        lastSuccess = defaults.object(forKey: Self.lastSuccessKey) as? Date
    }

    /// One pass with the folder `bookmark` names; nothing while one is running.
    public func run(_ bookmark: Data?) async {
        guard !isRunning else { return }
        guard let bookmark else {
            phase = .noFolder
            return
        }
        guard let folder = open(bookmark) else {
            phase = .folderUnavailable
            return
        }
        let mine = generation
        isRunning = true
        let report = await perform(folder.path)
        folder.stop()
        isRunning = false
        guard mine == generation else { return }
        guard let report else {
            phase = .failed
            return
        }
        let at = now()
        lastSuccess = at
        defaults.set(at, forKey: Self.lastSuccessKey)
        phase = .synced(added: report.added, peers: report.peers)
    }

    /// **Disconnect** stops future passes: the bookmark and the last success are forgotten. The folder's files and this
    /// Mac's history are left as they are; nothing here can reach either.
    public func disconnect(_ preferences: LearningPreferences) {
        generation += 1
        preferences.setSyncFolder(nil)
        lastSuccess = nil
        defaults.removeObject(forKey: Self.lastSuccessKey)
        phase = .idle
    }

    /// A newly chosen folder starts with nothing said about the old one.
    public func folderChanged() {
        generation += 1
        phase = .idle
        lastSuccess = nil
        defaults.removeObject(forKey: Self.lastSuccessKey)
    }
}

/// **Open Notification Settings** (UI41): XDict's own row in System Settings ▸ Notifications, else that pane, else
/// System Settings itself. The addresses are System Settings' documented-by-use deep links, not API; each is tried in
/// turn and the app is the floor.
public enum NotificationSettingsLink {
    static let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    public static func candidates(bundle: String?) -> [URL] {
        var links: [URL] = []
        if let bundle, let row = URL(string: pane + "?id=" + bundle) { links.append(row) }
        if let pane = URL(string: pane) { links.append(pane) }
        return links
    }

    @MainActor public static func open(bundle: String? = Bundle.main.bundleIdentifier) {
        for link in candidates(bundle: bundle) where NSWorkspace.shared.open(link) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
