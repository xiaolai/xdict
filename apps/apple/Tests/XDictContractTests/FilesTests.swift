import Foundation
import Testing
import XDictContract

/// Files as the contract carries them: by handle and metadata, never by path; their identity as the core compares it;
/// and the rule the service's byte sources answer `identity()` by (spike 1, `measurements/2026-10-14-macos-xpc`).
struct FilesTests {
    // MARK: - The identity rule, its four cases

    static let atOpen = FileIdentity(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 6)
    /// The same file after its ctime moved: what a rename-over (nlink 1 → 0) or an equal-size rewrite does to it.
    static let touched = FileIdentity(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 7)
    /// Another file at the path: what a swapped folder leaves there while the held inode is untouched.
    static let elsewhere = FileIdentity(device: 1, inode: 11, size: 100, mtimeNs: 5, ctimeNs: 6)

    /// The held descriptor moved since open: its own word, whatever the path says — the file itself changed.
    @Test func aDescriptorThatMovedSinceOpenIsReportedAsItIs() {
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.touched, token: .present(Self.atOpen)) == Self.touched)
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.touched, token: .missing) == Self.touched)
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: nil, token: .present(Self.atOpen)) == nil,
                "a descriptor fstat cannot read any more is a change too")
    }

    /// The descriptor is as it was, but the path now names another file: the token, so the core sees the change
    /// (case d, the swapped folder, which fstat alone missed).
    @Test func aTokenThatDiffersFromOpenIsReported() {
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.atOpen, token: .present(Self.elsewhere)) == Self.elsewhere)
    }

    /// Nothing at the path: no identity, which the core reads as a change from the one recorded at open
    /// (`source.rs`: an identity at open and another now, `None` included, is `SourceChanged`). So the app must
    /// re-resolve a moved file's bookmark before it sends `missing`, or a moved folder looks like a change.
    @Test func aMissingFileIsTreatedAsChanged() {
        let reported = IdentityRule.reported(atOpen: Self.atOpen, held: Self.atOpen, token: .missing)
        #expect(reported == nil)
        #expect(reported != Self.atOpen, "the core compares this with the identity at open")
    }

    /// Unchanged both ways, or no token yet: fstat, which equals the identity at open.
    @Test func anUnchangedFileIsReportedByFstat() {
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.atOpen, token: .present(Self.atOpen)) == Self.atOpen)
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.atOpen, token: nil) == Self.atOpen)
    }

    // MARK: - The order of observations (Codex objection 3)

    static let file = UUID(uuidString: "3A4B5C6D-7E8F-4091-A2B3-C4D5E6F70819") ?? UUID()

    /// **The race**: request R1 carries token A (observed first), is delayed; the folder is swapped; R2 carries token
    /// B (observed later) and merges first; then R1 merges. A must not replace B, or R2's identity check would read A,
    /// equal to the identity at open, and miss the swap.
    @Test func anOlderTokenArrivingLateNeverReplacesANewerOne() {
        let tokenA = FileToken(file: Self.file, observed: 1, state: .present(Self.atOpen))
        let tokenB = FileToken(file: Self.file, observed: 2, state: .present(Self.elsewhere))
        let afterR2 = TokenLedger.merging([tokenB], into: [:])
        let afterR1 = TokenLedger.merging([tokenA], into: afterR2)
        #expect(afterR1[Self.file] == tokenB)
        // What R2's identity check then reads: B, so the core sees the change.
        #expect(IdentityRule.reported(atOpen: Self.atOpen, held: Self.atOpen, token: afterR1[Self.file]?.state) == Self.elsewhere)
        // In their own order, the newer replaces the older.
        #expect(TokenLedger.merging([tokenB], into: TokenLedger.merging([tokenA], into: [:]))[Self.file] == tokenB)
    }

    /// One observation sent twice (a retried request) changes nothing; each file's order is its own.
    @Test func anEqualObservationKeepsTheOneHeldAndFilesAreApart() {
        let held = FileToken(file: Self.file, observed: 5, state: .present(Self.atOpen))
        let again = FileToken(file: Self.file, observed: 5, state: .missing)
        #expect(TokenLedger.merging([again], into: [Self.file: held])[Self.file] == held)
        let other = UUID()
        let merged = TokenLedger.merging([FileToken(file: other, observed: 1, state: .missing)], into: [Self.file: held])
        #expect(merged[Self.file] == held)
        #expect(merged[other] == FileToken(file: other, observed: 1, state: .missing))
    }

    // MARK: - FileIdentity(stat:)

    /// `st_dev` is an `Int32`; Rust's `MetadataExt::dev()` widens it with `as u64`, which sign-extends. Both Swift
    /// sides must widen it the same way or a device above 2³¹ compares unequal to itself across them.
    @Test func theDeviceIsSignExtendedAsRustWidensIt() {
        var info = stat()
        info.st_dev = -2
        #expect(FileIdentity(stat: info).device == UInt64.max - 1)
        info.st_dev = 16_777_231
        #expect(FileIdentity(stat: info).device == 16_777_231)
    }

    /// Times as the core makes them: `seconds × 10⁹ + nanoseconds`, saturating rather than wrapping.
    @Test func timesAreNanosecondsSaturatingAsTheCoresAre() {
        var info = stat()
        info.st_mtimespec = timespec(tv_sec: 1_760_000_000, tv_nsec: 123_456_789)
        info.st_ctimespec = timespec(tv_sec: -1, tv_nsec: 500)
        #expect(FileIdentity(stat: info).mtimeNs == 1_760_000_000_123_456_789)
        #expect(FileIdentity(stat: info).ctimeNs == -999_999_500)
        info.st_mtimespec = timespec(tv_sec: .max, tv_nsec: 1)
        info.st_ctimespec = timespec(tv_sec: .min, tv_nsec: 0)
        #expect(FileIdentity(stat: info).mtimeNs == .max)
        #expect(FileIdentity(stat: info).ctimeNs == .min)
    }

    /// On a real file: what `stat` of the path and `fstat` of a handle give agree, as the app's token and the
    /// service's own reading must.
    @Test func aPathAndItsHandleGiveOneIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "xdict-identity-\(UUID().uuidString)")
        try Data("hold".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var byPath = stat()
        try #require(stat(file.path, &byPath) == 0)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var byHandle = stat()
        try #require(fstat(handle.fileDescriptor, &byHandle) == 0)
        #expect(FileIdentity(stat: byPath) == FileIdentity(stat: byHandle))
        #expect(FileIdentity(stat: byPath).size == 4)
        #expect(FileIdentity(stat: byPath).inode == UInt64(byPath.st_ino))
    }

    // MARK: - Naming the files of a package

    /// What the convenience constructors make is valid: an MDX and its volumes named by their ids, a sidecar by its
    /// path in the package.
    @Test func aPackageBuiltByItsConstructorsIsValid() {
        #expect(Fixtures.package.problem == nil)
        #expect(Fixtures.package.files[0].name == Fixtures.mdxID.uuidString)
        #expect(Fixtures.package.files[3].name == "styles/Tiny.css")
    }

    /// **A sidecar is named by its path in the package** — the core finds it by comparing that name with the resource
    /// path asked for (`core.rs` `find_resource`), so a sidecar named by a UUID is never found.
    @Test func aSidecarNamedByAUUIDIsRefused() {
        let id = UUID()
        for name in [id.uuidString, UUID().uuidString, id.uuidString.lowercased()] {
            let package = PackageSpec(files: [.mdx(id: Fixtures.mdxID), FileSpec(id: id, name: name, role: .sidecar, order: 0)])
            #expect(package.problem == .sidecarNotAPackagePath(file: id), "\(name)")
        }
    }

    /// And by a canonical path inside it, as the core resolves one: relative, `/`-separated, no empty, `.` or `..`
    /// segment. An absolute path, or one climbing out, is a place on disk, not a name in the package.
    @Test func aSidecarNamedByAPathOutsideThePackageIsRefused() {
        for name in ["", "/Users/someone/Tiny.css", "../Tiny.css", "styles/../Tiny.css", "styles//Tiny.css",
                     "./Tiny.css", "styles\\Tiny.css", "styles/"] {
            let package = PackageSpec(files: [.mdx(id: Fixtures.mdxID), .sidecar(id: Fixtures.sidecarID, pathInPackage: name, order: 0)])
            #expect(package.problem == .sidecarNotAPackagePath(file: Fixtures.sidecarID), "\(name.debugDescription)")
        }
    }

    /// **An MDX or a volume is named by its id**, exactly as `UUID.uuidString` spells it: the core's registry keys a
    /// source location by its name, so a path (which moves) or another spelling of the id (a new location) would cost
    /// the reader a re-import.
    @Test func aVolumeOrMDXNamedOtherwiseThanByItsIDIsRefused() {
        let volume = Fixtures.volumeID
        for name in ["/Users/someone/Tiny.mdd", "Tiny.mdd", volume.uuidString.lowercased(), UUID().uuidString] {
            let package = PackageSpec(files: [.mdx(id: Fixtures.mdxID), FileSpec(id: volume, name: name, role: .mdd, order: 0)])
            #expect(package.problem == .notNamedByID(file: volume), "\(name)")
        }
        let mdx = PackageSpec(files: [FileSpec(id: Fixtures.mdxID, name: "Tiny.mdx", role: .mdx, order: 0)])
        #expect(mdx.problem == .notNamedByID(file: Fixtures.mdxID))
    }

    @Test func aPackageHasExactlyOneMDX() {
        #expect(PackageSpec(files: [.volume(id: Fixtures.volumeID, order: 0)]).problem == .mdxCount(found: 0))
        #expect(PackageSpec(files: [.mdx(id: Fixtures.mdxID), .mdx(id: Fixtures.volumeID)]).problem == .mdxCount(found: 2))
    }

    @Test func eachRolesOrderRunsFromZeroWithoutAGap() {
        let gap = PackageSpec(files: [.mdx(id: Fixtures.mdxID), .volume(id: Fixtures.volumeID, order: 0),
                                      .volume(id: Fixtures.secondVolumeID, order: 2)])
        #expect(gap.problem == .orderNotContiguous(role: .mdd))
        let twice = PackageSpec(files: [.mdx(id: Fixtures.mdxID), .volume(id: Fixtures.volumeID, order: 0),
                                        .volume(id: Fixtures.secondVolumeID, order: 0)])
        #expect(twice.problem == .orderNotContiguous(role: .mdd))
        let sidecar = PackageSpec(files: [.mdx(id: Fixtures.mdxID), .sidecar(id: Fixtures.sidecarID, pathInPackage: "a.css", order: 1)])
        #expect(sidecar.problem == .orderNotContiguous(role: .sidecar))
        let mdx = PackageSpec(files: [FileSpec(id: Fixtures.mdxID, name: Fixtures.mdxID.uuidString, role: .mdx, order: 1)])
        #expect(mdx.problem == .orderNotContiguous(role: .mdx))
        // Out of order in the list is fine: the list pairs files with handles; `order` places each within its role.
        let shuffled = PackageSpec(files: [.volume(id: Fixtures.secondVolumeID, order: 1), .mdx(id: Fixtures.mdxID),
                                           .volume(id: Fixtures.volumeID, order: 0)])
        #expect(shuffled.problem == nil)
    }

    @Test func aFileListedTwiceIsRefused() {
        let package = PackageSpec(files: [.mdx(id: Fixtures.mdxID), .volume(id: Fixtures.mdxID, order: 0)])
        #expect(package.problem == .duplicateFile(Fixtures.mdxID))
    }

    /// **There is no slot for a path.** A file on the wire is its id, its name in the core, its role and its order;
    /// the bytes come only through the handle sent beside it.
    @Test func aFileSpecCarriesNoLocation() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixtures.package)) as? [String: Any]
        let files = try #require(json?["files"] as? [[String: Any]])
        #expect(files.count == 4)
        for file in files { #expect(Set(file.keys) == ["id", "name", "role", "order"]) }
        #expect(Set(json?.keys ?? [:].keys) == ["files"])
    }
}
