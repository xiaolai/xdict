import Foundation
import Testing
import XDictAppleSource
@testable import XDictService
import XDictTestSupport

/// **The source revision is a versioned manifest hash** (ADR-0011 decision 7): for each file the converter reads, in
/// canonical name order, its name, name length, size and SHA-256. So it names the bytes and how they are split into
/// files, not the order they were listed in; and a change to a file the converter never reads (`*.lproj`, the code
/// signature) offers no update.
struct AppleImportManifestTests {
    static func entry(_ name: String, _ bytes: String) -> ManifestEntry {
        ManifestEntry(name: name, size: UInt64(bytes.utf8.count), sha256: XDictAppleSource.Manifest.sha256(Array(bytes.utf8)))
    }

    @Test func theOrderFilesAreListedInChangesNothing() throws {
        let a = [Self.entry("Contents/Info.plist", "p"), Self.entry("Contents/Resources/Body.data", "b")]
        #expect(try XDictAppleSource.Manifest.revision(a) == XDictAppleSource.Manifest.revision(a.reversed()))
    }

    @Test func aRenamedFileChangesTheRevision() throws {
        let a = [Self.entry("Contents/Resources/a.css", "x")]
        let b = [Self.entry("Contents/Resources/b.css", "x")]
        #expect(try XDictAppleSource.Manifest.revision(a) != XDictAppleSource.Manifest.revision(b))
    }

    /// Two entries of one name cannot both be what the converter reads: refused, never one silently chosen.
    @Test func duplicateNamesAreRefused() {
        let twice = [Self.entry("Contents/Resources/a.css", "x"), Self.entry("Contents/Resources/a.css", "y")]
        #expect(throws: ManifestFault.duplicateName("Contents/Resources/a.css")) { try XDictAppleSource.Manifest.revision(twice) }
    }

    /// Canonically equivalent names are different names: compared by their UTF-8 bytes, as the converter keys them.
    @Test func namesAreComparedByTheirBytes() throws {
        let composed = [Self.entry("Contents/Resources/\u{E9}.css", "x")]
        let decomposed = [Self.entry("Contents/Resources/e\u{301}.css", "x")]
        #expect(try XDictAppleSource.Manifest.revision(composed) != XDictAppleSource.Manifest.revision(decomposed))
    }

    /// The same bytes split differently across files are a different snapshot: each name, length and size is hashed.
    @Test func theSameBytesSplitDifferentlyAreAnotherRevision() throws {
        let one = [Self.entry("Contents/Resources/a", "ab"), Self.entry("Contents/Resources/b", "c")]
        let other = [Self.entry("Contents/Resources/a", "a"), Self.entry("Contents/Resources/b", "bc")]
        #expect(try XDictAppleSource.Manifest.revision(one) != XDictAppleSource.Manifest.revision(other))
        let joined = [Self.entry("Contents/Resources/ab", "")]
        let split = [Self.entry("Contents/Resources/a", ""), Self.entry("Contents/Resources/b", "")]
        #expect(try XDictAppleSource.Manifest.revision(joined) != XDictAppleSource.Manifest.revision(split))
    }

    @Test func theRevisionIsVersioned() throws {
        let revision = try XDictAppleSource.Manifest.revision([Self.entry("Contents/Info.plist", "p")])
        #expect(revision.hasPrefix("m\(XDictAppleSource.Manifest.version):") && revision.dropFirst(3).allSatisfy(\.isHexDigit))
    }

    // MARK: - Over a staged snapshot

    static func revision(_ edit: (URL) throws -> Void) throws -> (before: String, after: String) {
        let staging = try AppleStaging()
        let id = try staging.stage { root in
            try SyntheticAppleBundle.make(in: root, SyntheticAppleBundle.Overrides())
        }
        let folder = staging.folder(id)
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents/Resources/en.lproj"),
                                                withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: "Contents/Resources/en.lproj/InfoPlist.strings"))
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents/_CodeSignature"),
                                                withIntermediateDirectories: true)
        try Data("s".utf8).write(to: folder.appending(path: "Contents/_CodeSignature/CodeResources"))
        let before = try AppleImports.sourceRevision(of: folder, bounds: .production).get()
        try edit(folder)
        return (before, try AppleImports.sourceRevision(of: folder, bounds: .production).get())
    }

    @Test func aLocalisationChangeOffersNothing() throws {
        let (before, after) = try Self.revision { folder in
            try Data("changed".utf8).write(to: folder.appending(path: "Contents/Resources/en.lproj/InfoPlist.strings"))
            try Data("x".utf8).write(to: folder.appending(path: "Contents/Resources/en.lproj/More.strings"))
        }
        #expect(before == after)
    }

    @Test func aSignatureChangeOffersNothing() throws {
        let (before, after) = try Self.revision { folder in
            try Data("resigned".utf8).write(to: folder.appending(path: "Contents/_CodeSignature/CodeResources"))
        }
        #expect(before == after)
    }

    @Test func aChangeToAFileTheConverterReadsIsANewRevision() throws {
        let (before, after) = try Self.revision { folder in
            try Data("body { color: red }".utf8).write(to: folder.appending(path: "Contents/Resources/DefaultStyle.css"))
        }
        #expect(before != after)
    }
}
