import Foundation
import Testing
import XDictLibrary

/// **Packages as the core expects them, found in what the reader chose** (plan-macos-v1 WI-5, L2): an MDX, its volumes
/// `x.mdd`, `x.1.mdd`, `x.2.mdd`… in that order, the other files of its folder as sidecars, a missing volume named, and
/// nothing taken from outside the folder the reader chose (ADR-0009, refutation row 7). On files of the test's own: the
/// finder only reads names and links, never a dictionary's bytes.
struct PackageFinderTests {
    @Test func volumesAreOrderedByNumberNotByName() throws {
        let dir = try Scratch()
        try dir.files("x.mdx", "x.10.mdd", "x.2.mdd", "x.mdd", "x.1.mdd")
        for n in 3...9 { try dir.files("x.\(n).mdd") }
        let found = PackageFinder.find(in: [dir.url])
        let package = try #require(found.packages.first)
        #expect(found.packages.count == 1 && found.problems.isEmpty)
        #expect(package.volumes.map(\.fileName) == ["x.mdd"] + (1...10).map { "x.\($0).mdd" })
        #expect(package.notes.isEmpty)
    }

    @Test func aGapInTheVolumesIsReportedAndTheRestKeepTheirOrder() throws {
        let dir = try Scratch()
        try dir.files("gap.mdx", "gap.mdd", "gap.2.mdd", "gap.4.mdd")
        let package = try #require(PackageFinder.find(in: [dir.url]).packages.first)
        #expect(package.volumes.map(\.fileName) == ["gap.mdd", "gap.2.mdd", "gap.4.mdd"])
        #expect(package.notes == [.missingVolume(fileName: "gap.1.mdd"), .missingVolume(fileName: "gap.3.mdd")])
    }

    @Test func aMissingFirstVolumeIsReported() throws {
        let dir = try Scratch()
        try dir.files("d.mdx", "d.1.mdd")
        let package = try #require(PackageFinder.find(in: [dir.url]).packages.first)
        #expect(package.notes == [.missingVolume(fileName: "d.mdd")])
    }

    @Test func sidecarsAreTheOtherFilesOfTheFolderThatBelongToIt() throws {
        let dir = try Scratch()
        try dir.files("a.mdx", "a.mdd", "a.css", "b.mdx", "b.js", "shared.ttf", ".DS_Store", "notes.txt")
        let found = PackageFinder.find(in: [dir.url])
        let a = try #require(found.packages.first { $0.mdx.lastPathComponent == "a.mdx" })
        let b = try #require(found.packages.first { $0.mdx.lastPathComponent == "b.mdx" })
        #expect(a.sidecars.map(\.pathInPackage).sorted() == ["a.css", "notes.txt", "shared.ttf"])
        #expect(b.sidecars.map(\.pathInPackage).sorted() == ["b.js", "notes.txt", "shared.ttf"])
        #expect(a.volumes.map(\.fileName) == ["a.mdd"] && b.volumes.isEmpty)
    }

    @Test func extensionsAndStemsAreMatchedWithoutCase() throws {
        let dir = try Scratch()
        try dir.files("LDOCE6.MDX", "ldoce6.mdd", "LDOCE6.1.MDD")
        let package = try #require(PackageFinder.find(in: [dir.url]).packages.first)
        #expect(package.volumes.map(\.fileName) == ["ldoce6.mdd", "LDOCE6.1.MDD"])
    }

    @Test func aChosenFileBringsItsCompanions() throws {
        let dir = try Scratch()
        try dir.files("one.mdx", "one.mdd", "one.css", "two.mdx")
        let fromMDX = PackageFinder.find(in: [dir.url.appending(path: "one.mdx")])
        #expect(fromMDX.packages.map(\.mdx.lastPathComponent) == ["one.mdx"])
        #expect(fromMDX.packages.first?.volumes.map(\.fileName) == ["one.mdd"])
        #expect(fromMDX.packages.first?.sidecars.map(\.pathInPackage) == ["one.css"])
        let fromVolume = PackageFinder.find(in: [dir.url.appending(path: "one.mdd")])
        #expect(fromVolume.packages.map(\.mdx.lastPathComponent) == ["one.mdx"])
    }

    @Test func aFileAndItsFolderChosenTogetherAreOnePackage() throws {
        let dir = try Scratch()
        try dir.files("one.mdx")
        let found = PackageFinder.find(in: [dir.url, dir.url.appending(path: "one.mdx")])
        #expect(found.packages.count == 1)
    }

    @Test func foldersAreSearchedBelowTheChosenOne() throws {
        let dir = try Scratch()
        try dir.files("corpus/a/a.mdx", "corpus/b/b.mdx", "corpus/b/b.mdd", "corpus/c/deeper/c.mdx")
        let found = PackageFinder.find(in: [dir.url.appending(path: "corpus")])
        #expect(found.packages.map(\.mdx.lastPathComponent).sorted() == ["a.mdx", "b.mdx", "c.mdx"])
    }

    @Test func whatIsNoDictionaryIsSaidAndNeverSkipped() throws {
        let dir = try Scratch()
        try dir.files("readme.txt", "stray.mdd", "empty/.keep")
        let found = PackageFinder.find(in: [dir.url.appending(path: "readme.txt"), dir.url.appending(path: "stray.mdd"),
                                            dir.url.appending(path: "empty")])
        #expect(found.packages.isEmpty)
        #expect(found.problems == [.notADictionaryFile(fileName: "readme.txt"),
                                   .volumesWithoutDictionary(fileNames: ["stray.mdd"]),
                                   .noDictionaryIn(folderName: "empty")])
    }

    @Test func aStrayVolumeInAChosenFolderIsSaid() throws {
        let dir = try Scratch()
        try dir.files("a.mdx", "orphan.mdd")
        let found = PackageFinder.find(in: [dir.url])
        #expect(found.packages.count == 1)
        #expect(found.problems == [.volumesWithoutDictionary(fileNames: ["orphan.mdd"])])
    }

    /// **A symbolic link out of the chosen folder is refused** (ADR-0009 refutation row 7): as a sidecar it is left out
    /// and named; as the MDX, the package is refused. A link that stays inside is followed.
    @Test func aLinkOutOfTheChosenFolderIsRefusedAndOneInsideIsFollowed() throws {
        let dir = try Scratch()
        try dir.files("chosen/d/d.mdx", "chosen/d/real.css", "outside/secret.css", "outside/far.mdx")
        try dir.link("chosen/d/d.css", to: "../../outside/secret.css")
        try dir.link("chosen/d/alias.css", to: "real.css")
        try dir.link("chosen/d/far.mdx", to: "../../outside/far.mdx")
        let found = PackageFinder.find(in: [dir.url.appending(path: "chosen")])
        let d = try #require(found.packages.first { $0.mdx.lastPathComponent == "d.mdx" })
        #expect(found.packages.count == 1, "the linked MDX outside is not a package: \(found.packages.map(\.mdx.path))")
        #expect(d.sidecars.map(\.pathInPackage).sorted() == ["alias.css", "real.css"])
        #expect(d.sidecars.first { $0.pathInPackage == "alias.css" }?.url.lastPathComponent == "real.css")
        #expect(d.notes == [.outsideChosenFolder(fileName: "d.css")])
        #expect(found.problems == [.outsideChosenFolder(fileName: "far.mdx")])
        // Every location the finder hands on is the file's own path: no link left in it to swap later.
        for url in [d.mdx] + d.sidecars.map(\.url) {
            #expect(url.path == realPath(url.path), "\(url.path) still holds a link")
        }
    }

    /// The package limit (`Limits.maxPackageFiles`): sidecars past it are left out, stylesheets and scripts kept first,
    /// and the number left out is named.
    @Test func sidecarsPastThePackageLimitAreNamedNotDropped() throws {
        let dir = try Scratch()
        try dir.files("big.mdx", "big.css", "big.js")
        for n in 0..<80 { try dir.files("image\(n).png") }
        let package = try #require(PackageFinder.find(in: [dir.url]).packages.first)
        #expect(1 + package.volumes.count + package.sidecars.count == 64)
        #expect(package.sidecars.prefix(2).map(\.pathInPackage) == ["big.css", "big.js"])
        #expect(package.notes == [.sidecarsOmitted(count: 82 - 63)])
    }
}

/// `realpath(3)`, asked directly rather than through the code under test.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A directory of the test's own, removed when the test ends.
final class Scratch {
    let url: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory.appending(path: "xdict-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The canonical path: `/var` is a link to `/private/var`, and the finder hands on canonical paths only.
        // (`resolvingSymlinksInPath` will not do: it strips `/private` again.)
        url = URL(fileURLWithPath: realPath(made.path) ?? made.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func files(_ names: String...) throws {
        for name in names {
            let file = url.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
    }

    func link(_ name: String, to target: String) throws {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target)
    }
}
