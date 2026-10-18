import Foundation
import XDictAppleImport
import XDictAppleSource
import XDictContract

// **Apple's dictionaries are converted here, in the service, and nowhere else** (ADR-0011 decision 3): a bundle is
// untrusted binary input (ADR-0001), so the converter is linked into this process alone (`ModuleBoundaryTests`). The
// app stages a snapshot in the app-group container both share (decision 4); the service resolves it by UUID, bounds it,
// hashes what the converter reads (decision 7: `Snapshot` and `Manifest`, in `XDictAppleSource`, which the app shares to
// compare an installed bundle), converts it and publishes the pair into a folder of its own (decision 9). Whatever the
// outcome, the staging folder is removed; a refused or cancelled conversion leaves nothing.

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
            let revision = try Manifest.revision(try Manifest.entries(of: files) { scale.report(.hashing, done: $0, total: $1) })
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
            return .success(try Manifest.revision(try Manifest.entries(of: files)))
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
