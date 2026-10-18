import CryptoKit
import Foundation
import XDictContract

/// One file of the manifest: its path in the snapshot, its size and its SHA-256.
public struct ManifestEntry: Sendable, Equatable {
    public let name: String
    public let size: UInt64
    public let sha256: [UInt8]

    public init(name: String, size: UInt64, sha256: [UInt8]) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

public enum ManifestFault: Error, Equatable {
    case duplicateName(String)
    /// A file's size changed between the walk and its read: the snapshot is not one.
    case changed(String)
}

/// **The source revision** (ADR-0011 decision 7): `m1:` and the SHA-256, in hex, of `xdict-apple-manifest`, NUL, the
/// version (4 bytes) and the count (8 bytes), then for each file the converter reads, in the byte order of its UTF-8
/// name: the name's length (8 bytes), the name, the size (8 bytes) and the file's SHA-256; integers big-endian. Each
/// name and size is framed, so the same bytes split differently across files are a different revision. The service
/// stamps it on what it publishes; the app computes it over the installed bundle to see whether Apple changed it.
public enum Manifest {
    public static let version: UInt32 = 1

    /// Whether the converter reads this path: not under a `*.lproj` folder (localisation it never packs), not the
    /// bundle's code signature (`Contents/_CodeSignature/`). A change to those offers nothing.
    public static func isRead(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard !(parts.count >= 2 && parts[0] == "Contents" && parts[1] == "_CodeSignature") else { return false }
        return !parts.dropLast().contains { $0.hasSuffix(".lproj") }
    }

    /// Whether `text` is a revision this version could have written: `m`, the version, `:` and 64 lower-case hex digits.
    public static func isRevision(_ text: String) -> Bool {
        let prefix = "m\(version):"
        guard text.hasPrefix(prefix) else { return false }
        let digits = text.utf8.dropFirst(prefix.utf8.count)
        return digits.count == 64 && digits.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public static func revision(_ entries: [ManifestEntry]) throws(ManifestFault) -> String {
        let sorted = entries.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        var hash = SHA256()
        func put(_ bytes: [UInt8]) { hash.update(data: bytes) }
        func put64(_ v: UInt64) { put((0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xff) }) }
        put(Array("xdict-apple-manifest".utf8) + [0])
        put((0..<4).map { UInt8((version >> UInt32(24 - 8 * $0)) & 0xff) })
        put64(UInt64(sorted.count))
        var previous: [UInt8]?
        for entry in sorted {
            let name = Array(entry.name.utf8)
            guard name != previous else { throw .duplicateName(entry.name) }
            previous = name
            put64(UInt64(name.count))
            put(name)
            put64(entry.size)
            put(entry.sha256)
        }
        return "m\(version):" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    /// The entries of the files the converter reads, each hashed in 1 MiB reads without following a link; `report`
    /// hears bytes hashed of all before each file, and stops the hashing (`CancellationError`) by answering false.
    public static func entries(of files: [SnapshotFile], report: (Int, Int) -> Bool = { _, _ in true }) throws
        -> [ManifestEntry] {
        let read = files.filter { isRead($0.path) }
        let total = read.reduce(0) { $0 + $1.size }
        var done = 0
        var entries: [ManifestEntry] = []
        for file in read {
            guard report(done, total) else { throw CancellationError() }
            entries.append(try entry(file))
            done += file.size
        }
        return entries
    }

    /// **The source revision of a folder**: the walk under `bounds`, then the manifest. What the service stamps on a
    /// conversion and what the app compares an installed bundle with, by the same code.
    public static func revision(of folder: URL, bounds: SnapshotBounds = .production) throws -> String {
        try revision(try entries(of: try Snapshot.scan(folder, bounds: bounds)))
    }

    private static func entry(_ file: SnapshotFile) throws -> ManifestEntry {
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw AppleImportRefusal.symbolicLink(path: file.path) }
            throw AppleImportRefusal.unreadable(file: file.path, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hash = SHA256()
        var size = 0
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch {
                throw AppleImportRefusal.unreadable(file: file.path, code: (error as NSError).code)
            }
            if chunk.isEmpty { break }
            size += chunk.count
            guard size <= file.size else { throw ManifestFault.changed(file.path) }
            hash.update(data: chunk)
        }
        guard size == file.size else { throw ManifestFault.changed(file.path) }
        return ManifestEntry(name: file.path, size: UInt64(size), sha256: Array(hash.finalize()))
    }
}
