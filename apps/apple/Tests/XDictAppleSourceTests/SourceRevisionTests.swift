import Foundation
import Testing
import XDictAppleSource
import XDictTestSupport

/// The source revision's manifest; `XDictTestSupport` has a `Manifest` of its own (SwiftPM's).
private typealias SourceManifest = XDictAppleSource.Manifest

/// **Which changes to an installed bundle change its source revision** (ADR-0011 decision 7; plan WI-5): what the
/// converter reads — the body, an image — does; a localisation (`*.lproj`) or the code signature does not, so Apple
/// re-signing or re-translating a bundle offers nothing.
struct SourceRevisionTests {
    static func change(_ edit: (URL) throws -> Void) throws -> (before: String, after: String) {
        let base = try SyntheticAppleBundle.tempDir()
        var overrides = SyntheticAppleBundle.Overrides()
        overrides.resources = ["Images/a.png": Data([1, 2, 3]), "en.lproj/InfoPlist.strings": Data("a".utf8)]
        let bundle = try SyntheticAppleBundle.make(in: base, overrides)
        let before = try SourceManifest.revision(of: bundle)
        try edit(bundle)
        return (before, try SourceManifest.revision(of: bundle))
    }

    @Test func anImageChangeIsANewRevision() throws {
        let (before, after) = try Self.change { bundle in
            try Data([9]).write(to: bundle.appending(path: "Contents/Resources/Images/a.png"))
        }
        #expect(before != after && SourceManifest.isRevision(before) && SourceManifest.isRevision(after))
    }

    @Test func aLocalisationOnlyChangeIsTheSameRevision() throws {
        let (before, after) = try Self.change { bundle in
            try Data("changed".utf8).write(to: bundle.appending(path: "Contents/Resources/en.lproj/InfoPlist.strings"))
            try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/_CodeSignature"),
                                                    withIntermediateDirectories: true)
            try Data("s".utf8).write(to: bundle.appending(path: "Contents/_CodeSignature/CodeResources"))
        }
        #expect(before == after)
    }

    @Test func aRevisionIsRecognisedOnlyInItsOwnShape() {
        let good = "m1:" + String(repeating: "a", count: 64)
        #expect(SourceManifest.isRevision(good))
        #expect(!SourceManifest.isRevision("m2:" + String(repeating: "a", count: 64)))
        #expect(!SourceManifest.isRevision("m1:" + String(repeating: "A", count: 64)))
        #expect(!SourceManifest.isRevision("m1:" + String(repeating: "a", count: 63)))
        #expect(!SourceManifest.isRevision(""))
    }
}
