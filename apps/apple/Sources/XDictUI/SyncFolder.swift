import AppKit
import Foundation

/// **The reader's sync folder** (plan-history-and-learning §2.6): a folder in the reader's own storage — iCloud Drive, a
/// WebDAV mount, a plain folder — chosen once and kept as a bookmark, so a move or a rename does not break it. The core
/// does the merging; this only asks where.
public enum SyncFolder {
    /// Asks for a folder; its name for the pane and its bookmark for the preferences.
    @MainActor public static func choose() -> (name: String, bookmark: Data)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder XDict can sync with on your other devices.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return nil }
        return (url.lastPathComponent, bookmark)
    }

    /// The folder's name, for the pane. Resolved without the security scope: naming it grants nothing.
    public static func name(_ bookmark: Data) -> String? {
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.lastPathComponent
    }

    /// The folder for the app to read and write. `stop` hands the access back; call it when the pass is done.
    public static func open(_ bookmark: Data) -> (path: String, stop: () -> Void)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        let path = url.path(percentEncoded: false)
        return (path, {
            if started { url.stopAccessingSecurityScopedResource() }
        })
    }
}

/// **The files of one sync pass** (plan §2.6): the dictionary service's sandbox cannot read the reader's folder, so the app
/// copies that folder's logs into the app group's inbox, the service merges them and writes this device's log to the
/// outbox, and the app copies it back. Pure file work, so a folder of stray files is a test rather than a surprise.
public enum SyncStaging {
    /// The core refuses a peer log over this; the app does not copy one that big into the group.
    public static let limit = 256 * 1024 * 1024

    /// Empties `inbox` and copies `folder`'s logs into it. A file over `limit` is left out and named: a stray file in the
    /// reader's folder must not fail the pass, and must not reach the service either.
    @discardableResult
    public static func stage(from folder: URL, to inbox: URL, limit: Int = limit)
        throws -> (copied: Int, oversized: [String]) {
        let manager = FileManager.default
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        for file in try manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: file)
        }
        var copied = 0
        var oversized: [String] = []
        for file in try logs(in: folder) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limit else {
                oversized.append(file.lastPathComponent)
                continue
            }
            try manager.copyItem(at: file, to: inbox.appending(path: file.lastPathComponent))
            copied += 1
        }
        return (copied, oversized)
    }

    /// Copies the outbox's logs into the reader's folder, replacing this device's own log from an earlier pass.
    @discardableResult
    public static func collect(from outbox: URL, to folder: URL) throws -> Int {
        let manager = FileManager.default
        var copied = 0
        for file in try logs(in: outbox) {
            let destination = folder.appending(path: file.lastPathComponent)
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: file, to: destination)
            copied += 1
        }
        return copied
    }

    static func logs(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "xdlog" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
