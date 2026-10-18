import Foundation
import Testing
import XDictAppleSource
import XDictContract
import XDictTestSupport

/// The source revision's manifest; `XDictTestSupport` has a `Manifest` of its own (SwiftPM's).
private typealias SourceManifest = XDictAppleSource.Manifest

/// **The app's copy into the shared container, and the launch sweep** (ADR-0011 decisions 4 and 9): byte for byte into
/// `staging/<uuid>/`, bounded, a link refused and nothing left behind by a failed copy; at launch every staging folder
/// goes, and an output folder no entry names once it is older than a day.
struct SnapshotCopyTests {
    let base: URL
    let root: URL

    init() throws {
        base = try SyntheticAppleBundle.tempDir()
        root = base.appending(path: "AppleImports")
    }

    func bundle() throws -> URL {
        var overrides = SyntheticAppleBundle.Overrides()
        overrides.resources = ["Images/a.png": Data([1, 2, 3])]
        return try SyntheticAppleBundle.make(in: base, overrides)
    }

    @Test func theCopyIsByteForByteInItsOwnStagingFolder() throws {
        let source = try bundle()
        let id = try SnapshotCopy.copy(source, into: root)
        let copy = root.appending(path: "staging/\(id.uuidString)")
        let original = try Snapshot.scan(source, bounds: .production)
        let copied = try Snapshot.scan(copy, bounds: .production)
        #expect(original.map(\.path) == copied.map(\.path) && !original.isEmpty)
        for (a, b) in zip(original, copied) { #expect(try Data(contentsOf: a.url) == Data(contentsOf: b.url), "\(a.path)") }
        #expect(try SourceManifest.revision(of: source) == SourceManifest.revision(of: copy))
    }

    @Test func aLinkInTheBundleIsRefusedAndNothingIsLeft() throws {
        let source = try bundle()
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "Contents/Resources/link").path,
                                                   withDestinationPath: "/etc/hosts")
        #expect(throws: AppleImportRefusal.symbolicLink(path: "Contents/Resources/link")) {
            try SnapshotCopy.copy(source, into: root)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "staging").path)) ?? []).isEmpty)
    }

    @Test func aBundleOverTheBoundsIsRefusedBeforeAByteIsCopied() throws {
        let source = try bundle()
        #expect(throws: AppleImportRefusal.boundExceeded(.snapshotBytes(limit: 10))) {
            try SnapshotCopy.copy(source, into: root, bounds: SnapshotBounds(files: 512, bytes: 10))
        }
        #expect(throws: AppleImportRefusal.boundExceeded(.fileCount(limit: 1))) {
            try SnapshotCopy.copy(source, into: root, bounds: SnapshotBounds(files: 1, bytes: 512 << 20))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "staging/\(UUID().uuidString)").path))
    }

    @Test func aLinkInPlaceOfTheBundleIsRefused() throws {
        let source = try bundle()
        let link = base.appending(path: "Linked.dictionary")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: AppleImportRefusal.stagingNotAFolder) { try SnapshotCopy.copy(link, into: root) }
    }

    // MARK: - The sweep (decision 9)

    func output(_ id: UUID = UUID(), age: TimeInterval) throws -> UUID {
        let folder = root.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("m".utf8).write(to: folder.appending(path: "dictionary.mdx"))
        let date = Date(timeIntervalSinceNow: -age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        return id
    }

    @Test func theSweepRemovesStagingAndOldUnnamedOutputsOnly() throws {
        let staged = try SnapshotCopy.copy(try bundle(), into: root)
        let named = try output(age: 3 * AppleImportSweep.maxAge)
        let oldUnnamed = try output(age: 2 * AppleImportSweep.maxAge)
        let youngUnnamed = try output(age: 60)
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-conversion"), withIntermediateDirectories: true)
        let report = AppleImportSweep.sweep(root, referenced: [named])
        #expect(report.staging == [staged.uuidString])
        #expect(report.outputs == [oldUnnamed] && report.young == [youngUnnamed])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["not-a-conversion", named.uuidString, youngUnnamed.uuidString, "staging"].sorted())
    }

    /// The control: a sweep that removed nothing would pass a test that only looked for what is kept.
    @Test func theSameFolderNamedIsKeptAndUnnamedIsRemoved() throws {
        let id = try output(age: 2 * AppleImportSweep.maxAge)
        #expect(AppleImportSweep.sweep(root, referenced: [id]).outputs.isEmpty)
        #expect(AppleImportSweep.sweep(root, referenced: []).outputs == [id])
    }
}
