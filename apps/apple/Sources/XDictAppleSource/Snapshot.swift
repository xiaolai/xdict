import Foundation
import XDictContract

// **What the app and the dictionary service both say about an Apple dictionary's files, written once** (ADR-0011
// decisions 4 and 7). The app copies an installed bundle into the shared container and later asks whether Apple changed
// it; the service hashes the copy it converts. Both must walk the same files under the same bounds and hash them the
// same way, or an update would be offered for nothing (or never), so the walk and the manifest live here, in a module
// both link, and never in two places. Nothing here parses a bundle's data: names, sizes and bytes only.

/// **The snapshot's bounds** (ADR-0011 decision 4), checked over the whole tree before a byte is read.
public struct SnapshotBounds: Sendable, Equatable {
    /// Files in the snapshot. 512: the installed bundles hold 47–94 (the six Oxford ones), and a copy of 512 files
    /// stays far under the service's descriptor limit, since none is held open past its own read.
    public var files: Int
    /// Bytes of all its files. 512 MiB: Hungarian, the largest installed bundle, is 123 MB.
    public var bytes: Int

    public init(files: Int, bytes: Int) {
        self.files = files
        self.bytes = bytes
    }

    public static let production = SnapshotBounds(files: 512, bytes: 512 << 20)
}

/// A regular file of the snapshot: its path inside it, `/`-separated, and its size.
public struct SnapshotFile: Sendable, Equatable {
    public let path: String
    public let url: URL
    public let size: Int
}

public enum Snapshot {
    /// Every regular file below `folder`, by `lstat`, never following a link: a link, or anything that is neither a
    /// folder nor a regular file, is refused; so is a snapshot over `bounds`, counted as the walk goes.
    public static func scan(_ folder: URL, bounds: SnapshotBounds) throws(AppleImportRefusal) -> [SnapshotFile] {
        var files: [SnapshotFile] = []
        var bytes = 0
        func walk(_ dir: URL, _ prefix: String) throws(AppleImportRefusal) {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() } catch {
                throw .unreadable(file: prefix, code: (error as NSError).code)
            }
            for name in names {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = dir.appending(path: name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { throw .unreadable(file: path, code: Int(errno)) }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    try walk(url, path)
                case S_IFREG:
                    files.append(SnapshotFile(path: path, url: url, size: Int(st.st_size)))
                    bytes += Int(st.st_size)
                    guard files.count <= bounds.files else { throw .boundExceeded(.fileCount(limit: UInt64(bounds.files))) }
                    guard bytes <= bounds.bytes else { throw .boundExceeded(.snapshotBytes(limit: UInt64(bounds.bytes))) }
                case S_IFLNK:
                    throw .symbolicLink(path: path)
                default:
                    throw .notARegularFile(path: path)
                }
            }
        }
        try walk(folder, "")
        return files
    }
}
