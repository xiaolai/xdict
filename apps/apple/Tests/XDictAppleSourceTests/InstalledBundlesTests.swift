import Foundation
import Testing
import XDictAppleSource
import XDictContract
import XDictTestSupport

/// **The Apple dictionaries installed on this Mac, found under a synthetic AssetsV2 tree** (ADR-0011 decisions 1 and
/// 11; plan WI-5): every `<asset>/AssetData/*.dictionary`, named from its `Info.plist`, sized, its languages read;
/// one XDict will not convert listed with its refusal, never hidden; nothing outside the layout offered.
struct InstalledBundlesTests {
    let root: URL

    init() throws {
        root = try SyntheticAppleBundle.tempDir().appending(path: "AssetsV2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// One asset holding one bundle written with `plist`.
    @discardableResult
    func asset(_ asset: String, _ name: String, plist: Data? = nil) throws -> URL {
        let data = root.appending(path: "\(asset).asset/AssetData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var overrides = SyntheticAppleBundle.Overrides()
        overrides.plist = try plist ?? SyntheticAppleBundle.plist(displayName: name, identifier: "com.apple.dictionary.\(name)")
        return try SyntheticAppleBundle.make(in: data, name: name, overrides)
    }

    @Test func everyBundleIsFoundWithItsNamesVersionSizeAndLanguages() throws {
        let oxford = try asset("a1", "Oxford", plist: SyntheticAppleBundle.plist(
            bundleVersion: "2.5.1", displayName: "Oxford Dictionary of English", identifier: "com.apple.dictionary.NOAD",
            languages: ("en_US", "en_US")))
        try asset("a2", "Chinese", plist: SyntheticAppleBundle.plist(
            displayName: "Chinese–English", identifier: "com.apple.dictionary.zh_CN-en", languages: ("zh_CN", "en_GB")))
        let found = InstalledBundles.discover(root: root)
        #expect(found.map(\.displayName) == ["Chinese–English", "Oxford Dictionary of English"])
        let first = try #require(found.last)
        #expect(first.identifier == "com.apple.dictionary.NOAD" && first.version == "2.5.1")
        #expect(first.url.standardizedFileURL == oxford.standardizedFileURL)
        let size = try Snapshot.scan(oxford, bounds: .production).reduce(0) { $0 + UInt64($1.size) }
        #expect(first.bytes == size && size > 0)
        #expect(first.searchLanguage == "en" && first.explanationLanguage == "en" && first.refusal == nil)
        #expect(found.first?.searchLanguage == "zh-Hans" && found.first?.explanationLanguage == "en")
    }

    @Test func theNameFallsBackToTheBundleNameThenTheFolder() throws {
        var info = try #require(try PropertyListSerialization.propertyList(
            from: SyntheticAppleBundle.plist(identifier: "x.one"), format: nil) as? [String: Any])
        info["CFBundleDisplayName"] = nil
        info["CFBundleName"] = "Short Name"
        try asset("a1", "One", plist: PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        info["CFBundleName"] = nil
        info["CFBundleIdentifier"] = "x.two"
        try asset("a2", "Two", plist: PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        #expect(InstalledBundles.discover(root: root).map(\.displayName) == ["Short Name", "Two"])
    }

    /// The system "Apple Dictionary" (no `KeyText.index`), a format other than 3 and a damaged property list are listed,
    /// each with the refusal the sheet words: the reader sees why, rather than a dictionary missing.
    @Test func refusedKindsAreListedWithTheirReasonNotHidden() throws {
        try asset("a1", "Apple", plist: SyntheticAppleBundle.plist(keyTextIndex: false, displayName: "Apple Dictionary",
                                                                   identifier: "com.apple.dictionary.AppleDictionary"))
        try asset("a2", "Old", plist: SyntheticAppleBundle.plist(version: 1, displayName: "Old", identifier: "x.old"))
        try asset("a3", "Broken", plist: Data("not a plist".utf8))
        try asset("a4", "Good")
        let found = Dictionary(uniqueKeysWithValues: InstalledBundles.discover(root: root).map { ($0.displayName, $0) })
        #expect(found.count == 4)
        #expect(found["Apple Dictionary"]?.refusal == .noKeyTextIndex)
        #expect(found["Old"]?.refusal == .notVersion3(found: 1))
        guard case .malformedInfoPlist = found["Broken"]?.refusal else {
            Issue.record("a damaged Info.plist is refused: \(String(describing: found["Broken"]?.refusal))")
            return
        }
        #expect(found["Good"]?.refusal == nil)
    }

    @Test func aBundleOverTheBoundsIsListedRefusedWithTheBound() throws {
        try asset("a1", "Big")
        let found = InstalledBundles.discover(root: root, bounds: SnapshotBounds(files: 2, bytes: 512 << 20))
        #expect(found.first?.refusal == .boundExceeded(.fileCount(limit: 2)))
    }

    /// Only the layout is offered (ADR-0011 decision 11: the trusted location is the admission): a bundle beside the
    /// assets, one not in `AssetData`, and a link to a bundle elsewhere are not.
    @Test func onlyAssetDataBundlesAreOfferedNeverThroughALink() throws {
        try asset("a1", "Good")
        let stray = root.appending(path: "a2.asset")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try SyntheticAppleBundle.make(in: stray, name: "Stray")
        try SyntheticAppleBundle.make(in: root, name: "Beside")
        let elsewhere = try SyntheticAppleBundle.tempDir()
        let real = try SyntheticAppleBundle.make(in: elsewhere, name: "Elsewhere")
        let data = root.appending(path: "a3.asset/AssetData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "Linked.dictionary"), withDestinationURL: real)
        #expect(InstalledBundles.discover(root: root).map(\.displayName) == ["Good"])
    }

    @Test func twoAssetsOfOneIdentifierGiveTheLaterVersion() throws {
        try asset("a1", "One", plist: SyntheticAppleBundle.plist(bundleVersion: "2.9", displayName: "Old", identifier: "x.d"))
        try asset("a2", "One", plist: SyntheticAppleBundle.plist(bundleVersion: "2.10", displayName: "New", identifier: "x.d"))
        #expect(InstalledBundles.discover(root: root).map(\.displayName) == ["New"])
    }

    @Test func noTreeIsNoBundles() {
        #expect(InstalledBundles.discover(root: root.appending(path: "absent")).isEmpty)
    }
}
