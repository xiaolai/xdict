import CryptoKit
import Foundation
import XDictAppleImport
import XDictContract

// **Apple's dictionaries are converted here, in the service, and nowhere else** (ADR-0011 decision 3): a bundle is
// untrusted binary input (ADR-0001), so the converter is linked into this process alone (`ModuleBoundaryTests`). The
// app stages a snapshot in the app-group container both share (decision 4); the service resolves it by UUID, bounds it,
// hashes what the converter reads (decision 7), converts it and publishes the pair into a folder of its own
// (decision 9). Whatever the outcome, the staging folder is removed; a refused or cancelled conversion leaves nothing.

/// **The snapshot's bounds** (ADR-0011 decision 4), checked over the whole staged tree before a byte is read.
struct SnapshotBounds: Sendable, Equatable {
    /// Files in the snapshot. 512: the installed bundles hold 47–94 (the six Oxford ones), and a copy of 512 files
    /// stays far under the service's descriptor limit, since none is held open past its own read.
    var files: Int
    /// Bytes of all its files. 512 MiB: Hungarian, the largest installed bundle, is 123 MB.
    var bytes: Int

    static let production = SnapshotBounds(files: 512, bytes: 512 << 20)
}

/// **Where conversions live**: `<app-group container>/AppleImports/` (`AppGroup.appleImports`), or a folder of a test's
/// own. `staging/<uuid>/` is what the app copied; `<conversion uuid>/` what the service published.
struct AppleImportStore: Sendable {
    let root: URL
    let snapshot: SnapshotBounds
    let converter: Bounds
    /// For tests: told of every converter step before the checkpoint answers, so a test can hold a conversion there.
    let onStep: (@Sendable (ConversionStep) -> Void)?

    init(root: URL, snapshot: SnapshotBounds = .production, converter: Bounds = .production,
         onStep: (@Sendable (ConversionStep) -> Void)? = nil) {
        self.root = root
        self.snapshot = snapshot
        self.converter = converter
        self.onStep = onStep
    }

    var staging: URL {
        root.appending(path: "staging", directoryHint: .isDirectory)
    }
}

enum AppleImports {
    static let converterRevision = AppleImport.converterRevision
    /// The published files' name: fixed, since the bytes do not depend on it (ADR-0011 decision 6).
    static let outputName = "dictionary"

    /// **Converts the snapshot staged as `staging`** and publishes it, or says why not. `progress` hears the steps
    /// (hashing, reading, writing; `ProgressScale`) and cancels at the next one once `cancel()` is called.
    static func convert(staging: UUID, in store: AppleImportStore, progress: ImportProgress?) -> Result<Converted, WireError> {
        let folder = store.staging.appending(path: staging.uuidString, directoryHint: .isDirectory)
        defer { discard(folder) }
        let scale = ProgressScale(progress: progress)
        do {
            guard scale.report(.hashing, done: 0, total: 1) else { throw Stop.cancelled }
            try checkFolder(store.root)
            try checkFolder(store.staging)
            try checkStaging(folder)
            let files = try Snapshot.scan(folder, bounds: store.snapshot)
            let revision = try Manifest.revision(try Manifest.entries(of: files, scale: scale))
            return .success(try publish(folder, store: store, revision: revision, scale: scale))
        } catch let refusal as AppleImportRefusal {
            return .failure(.appleImport(refusal))
        } catch Stop.cancelled {
            return .failure(.core(.cancelled(detail: "the conversion was cancelled")))
        } catch is CancellationError {
            return .failure(.core(.cancelled(detail: "the conversion was cancelled while hashing")))
        } catch let fault as ManifestFault {
            return .failure(.appleImport(.corrupt(detail: "\(fault)")))
        } catch {
            return .failure(.core(.internalFault(detail: "\(error)")))
        }
    }

    /// The source revision of a staged snapshot, alone: what `convert` stamps on what it publishes.
    static func sourceRevision(of folder: URL, bounds: SnapshotBounds) -> Result<String, WireError> {
        do {
            let files = try Snapshot.scan(folder, bounds: bounds)
            return .success(try Manifest.revision(try Manifest.entries(of: files, scale: ProgressScale(progress: nil))))
        } catch let refusal as AppleImportRefusal {
            return .failure(.appleImport(refusal))
        } catch {
            return .failure(.appleImport(.corrupt(detail: "\(error)")))
        }
    }

    /// Removes a staging folder that will never be converted: its client went before its turn (`ConnectionSession`).
    static func discard(staging: UUID, in store: AppleImportStore) {
        discard(store.staging.appending(path: staging.uuidString, directoryHint: .isDirectory))
    }

    /// `removeItem` on a link removes the link, never what it points to.
    private static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private enum Stop: Error {
        case cancelled
    }

    /// The store's own folders must be folders, not links planted to lead elsewhere.
    private static func checkFolder(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw AppleImportRefusal.stagingNotFound }
    }

    private static func checkStaging(_ folder: URL) throws {
        var st = stat()
        guard lstat(folder.path, &st) == 0 else {
            if errno == ENOENT { throw AppleImportRefusal.stagingNotFound }
            throw AppleImportRefusal.unreadable(file: "", code: Int(errno))
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw AppleImportRefusal.stagingNotAFolder }
    }

    /// Converts into a new `<conversion uuid>/`, removed again unless both files were published into it.
    private static func publish(_ folder: URL, store: AppleImportStore, revision: String, scale: ProgressScale) throws
        -> Converted {
        let conversion = UUID()
        let out = store.root.appending(path: conversion.uuidString, directoryHint: .isDirectory)
        // Never reused, never overwritten (ADR-0011 decision 9): an existing folder of that name refuses the creation.
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        } catch {
            throw AppleImportRefusal.unwritable(file: conversion.uuidString, code: (error as NSError).code)
        }
        do {
            let summary = try XDictAppleImport.convert(snapshot: folder, into: out, name: outputName, bounds: store.converter,
                                                       checkpoint: { step in
                                                           store.onStep?(step)
                                                           return scale.report(step)
                                                       })
            return Converted(conversion: conversion, sourceRevision: revision, converterRevision: UInt32(converterRevision),
                             files: summary.files, entries: UInt64(summary.entries), redirects: UInt64(summary.redirects),
                             resources: UInt64(summary.resources))
        } catch {
            try? FileManager.default.removeItem(at: out)
            guard let refusal = AppleImportRefusal(error) else { throw Stop.cancelled }
            throw refusal
        }
    }
}

/// **Progress across a conversion's four phases**, each a quarter of one scale, so the client sees one rising count:
/// hashing (bytes of the files read), reading (bytes of the body's sections), building (entries transformed), writing
/// (records written).
struct ProgressScale {
    enum Phase: UInt64 {
        case hashing = 0, reading, building, writing
    }

    static let unit: UInt64 = 1 << 20
    static let total = 4 * unit
    let progress: ImportProgress?

    /// Reports and answers whether to go on.
    func report(_ phase: Phase, done: Int, total: Int) -> Bool {
        guard let progress else { return true }
        let within = total > 0 ? UInt64(min(max(done, 0), total)) * Self.unit / UInt64(total) : 0
        return progress.progress(done: phase.rawValue * Self.unit + within, total: Self.total)
    }

    func report(_ step: ConversionStep) -> Bool {
        let phase: Phase = switch step.phase {
        case .reading: .reading
        case .building: .building
        case .writing: .writing
        }
        return report(phase, done: step.done, total: step.total)
    }
}

// MARK: - The snapshot

/// A regular file of the snapshot: its path inside it, `/`-separated, and its size.
struct SnapshotFile: Sendable {
    let path: String
    let url: URL
    let size: Int
}

enum Snapshot {
    /// Every regular file below `folder`, by `lstat`, never following a link: a link, or anything that is neither a
    /// folder nor a regular file, is refused; so is a snapshot over `bounds`, counted as the walk goes.
    static func scan(_ folder: URL, bounds: SnapshotBounds) throws -> [SnapshotFile] {
        var files: [SnapshotFile] = []
        var bytes = 0
        func walk(_ dir: URL, _ prefix: String) throws {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() } catch {
                throw AppleImportRefusal.unreadable(file: prefix, code: (error as NSError).code)
            }
            for name in names {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = dir.appending(path: name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { throw AppleImportRefusal.unreadable(file: path, code: Int(errno)) }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    try walk(url, path)
                case S_IFREG:
                    files.append(SnapshotFile(path: path, url: url, size: Int(st.st_size)))
                    bytes += Int(st.st_size)
                    guard files.count <= bounds.files else {
                        throw AppleImportRefusal.boundExceeded(.fileCount(limit: UInt64(bounds.files)))
                    }
                    guard bytes <= bounds.bytes else {
                        throw AppleImportRefusal.boundExceeded(.snapshotBytes(limit: UInt64(bounds.bytes)))
                    }
                case S_IFLNK:
                    throw AppleImportRefusal.symbolicLink(path: path)
                default:
                    throw AppleImportRefusal.notARegularFile(path: path)
                }
            }
        }
        try walk(folder, "")
        return files
    }
}

// MARK: - The manifest

/// One file of the manifest: its path in the snapshot, its size and its SHA-256.
struct ManifestEntry: Sendable, Equatable {
    let name: String
    let size: UInt64
    let sha256: [UInt8]
}

enum ManifestFault: Error, Equatable {
    case duplicateName(String)
    /// A file's size changed between the walk and its read: the snapshot is not one.
    case changed(String)
}

/// **The source revision** (ADR-0011 decision 7): `m1:` and the SHA-256, in hex, of `xdict-apple-manifest`, NUL, the
/// version (4 bytes) and the count (8 bytes), then for each file the converter reads, in the byte order of its UTF-8
/// name: the name's length (8 bytes), the name, the size (8 bytes) and the file's SHA-256; integers big-endian. Each
/// name and size is framed, so the same bytes split differently across files are a different revision.
enum Manifest {
    static let version: UInt32 = 1

    /// Whether the converter reads this path: not under a `*.lproj` folder (localisation it never packs), not the
    /// bundle's code signature (`Contents/_CodeSignature/`). A change to those offers nothing.
    static func isRead(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard !(parts.count >= 2 && parts[0] == "Contents" && parts[1] == "_CodeSignature") else { return false }
        return !parts.dropLast().contains { $0.hasSuffix(".lproj") }
    }

    static func revision(_ entries: [ManifestEntry]) throws(ManifestFault) -> String {
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

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    /// The entries of the files the converter reads, each hashed in 1 MiB reads without following a link, the
    /// hashing reported (and cancellable) file by file.
    static func entries(of files: [SnapshotFile], scale: ProgressScale) throws -> [ManifestEntry] {
        let read = files.filter { isRead($0.path) }
        let total = read.reduce(0) { $0 + $1.size }
        var done = 0
        var entries: [ManifestEntry] = []
        for file in read {
            guard scale.report(.hashing, done: done, total: total) else { throw CancellationError() }
            entries.append(try entry(file))
            done += file.size
        }
        return entries
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

// MARK: - The converter's kinds, as the contract's

extension AppleImportRefusal {
    /// The converter's refusal as the contract's kind; nil for `cancelled`, which is no refusal but
    /// `CoreFailure.cancelled`.
    init?(_ error: AppleImportError) {
        switch error {
        case .notVersion3(let found): self = .notVersion3(found: found)
        case .noKeyTextIndex: self = .noKeyTextIndex
        case .malformedInfoPlist(let fault): self = .malformedInfoPlist(detail: "\(fault)")
        case .unsupported(let what): self = .unsupported(detail: "\(what)")
        case .boundExceeded(let bound): self = .boundExceeded(AppleImportBound(bound))
        case .corrupt(let where_): self = .corrupt(detail: "\(where_)")
        case .unsafeResourceName(let name), .unsafeOutputName(let name): self = .unsafeName(name: name)
        case .symbolicLink(let path): self = .symbolicLink(path: "Contents/Resources/\(path)")
        case .outputExists(let file): self = .unwritable(file: file, code: Int(EEXIST))
        case .unreadable(let file, let code): self = .unreadable(file: file, code: code)
        case .unwritable(let file, let code): self = .unwritable(file: file, code: code)
        case .noEntries: self = .noEntries
        case .cancelled: return nil
        }
    }
}

extension AppleImportBound {
    init(_ bound: Bound) {
        switch bound {
        case .sourceFile(let name, let limit): self = .sourceFile(name: name, limit: UInt64(limit))
        case .inflatedBlock(let claimed): self = .inflatedBlock(claimed: UInt64(max(0, claimed)))
        case .decompression(let limit): self = .decompression(limit: UInt64(limit))
        case .output(let limit): self = .output(limit: UInt64(limit))
        case .keyLength(let units): self = .keyLength(units: UInt64(units))
        }
    }
}
