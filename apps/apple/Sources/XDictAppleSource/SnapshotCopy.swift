import Foundation
import XDictContract

/// **The app's copy of an installed bundle into the shared container** (ADR-0011 decision 4): byte for byte, parsing
/// nothing, into `staging/<uuid>/`, under the snapshot's bounds; a link or anything but a folder or a regular file is
/// refused, never followed. A copy that fails leaves no staging folder behind; one the app dies in the middle of is
/// removed by the launch sweep (`AppleImportSweep`).
public enum SnapshotCopy {
    /// Copies `bundle` into a new `staging/<uuid>/` under `root` (`AppleImports/`) and answers the UUID, the name the
    /// service is sent.
    public static func copy(_ bundle: URL, into root: URL, bounds: SnapshotBounds = .production,
                            id: UUID = UUID()) throws(AppleImportRefusal) -> UUID {
        guard InstalledBundles.isFolder(bundle) else { throw .stagingNotAFolder }
        let files = try Snapshot.scan(bundle, bounds: bounds)
        let staging = SharedContainer.staging(in: root)
        let folder = staging.appending(path: id.uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            // Never into a folder that is there already: a UUID names one copy.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw .unwritable(file: "staging", code: (error as NSError).code)
        }
        do throws(AppleImportRefusal) {
            for file in files { try copy(file, into: folder) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return id
    }

    private static func copy(_ file: SnapshotFile, into folder: URL) throws(AppleImportRefusal) {
        let target = folder.appending(path: file.path)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .unwritable(file: file.path, code: (error as NSError).code)
        }
        let input = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            throw errno == ELOOP ? .symbolicLink(path: file.path) : .unreadable(file: file.path, code: Int(errno))
        }
        let source = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw .unwritable(file: file.path, code: Int(errno)) }
        let sink = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        var copied = 0
        while true {
            let chunk: Data
            do { chunk = try source.read(upToCount: 1 << 20) ?? Data() } catch {
                throw .unreadable(file: file.path, code: (error as NSError).code)
            }
            if chunk.isEmpty { break }
            copied += chunk.count
            // A file that grew since the walk is not the snapshot the bounds were checked over.
            guard copied <= file.size else { throw .unreadable(file: file.path, code: 0) }
            do { try sink.write(contentsOf: chunk) } catch {
                throw .unwritable(file: file.path, code: (error as NSError).code)
            }
        }
        guard copied == file.size else { throw .unreadable(file: file.path, code: 0) }
    }
}
