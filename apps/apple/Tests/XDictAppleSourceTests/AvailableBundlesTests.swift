import Foundation
import Testing
import XDictAppleSource
import XDictContract
import XDictTestSupport

/// **What Dictionary.app knows is available on this Mac** (plan-setup-v2 WI-3; ADR-0011 decision 1, amended): the
/// `asset:/…` names of the preference, less the ones already installed, sorted — and a list that could not be read is
/// not an empty one. The fixture is a literal array, never Apple's data, so the rules are the test's and not this Mac's.
struct AvailableBundlesTests {
    static func bundle(_ name: String, folder: String? = nil) -> InstalledBundle {
        InstalledBundle(url: URL(filePath: "/x/\(folder ?? name).dictionary"), identifier: "com.apple.dictionary.\(name)",
                        displayName: name, version: "1", bytes: 0, searchLanguage: nil, explanationLanguage: nil,
                        refusal: nil)
    }

    /// **Only the `asset:` entries are candidates**: a path is already on this Mac, and anything named is offered by the
    /// name macOS shows, without its extension.
    @Test func onlyTheAssetEntriesAreOffered() {
        let entries = ["/System/Library/AssetsV2/a.asset/AssetData/Oxford.dictionary",
                       "asset:/Assamese - English.dictionary",
                       "asset:/Bulgarian.dictionary",
                       "/Users/x/Library/Dictionaries/Mine.dictionary",
                       "asset:/not a dictionary", "asset:/"]
        let found = AvailableBundles.known(entries: entries, installed: [])
        #expect(found?.map(\.name) == ["Assamese - English", "Bulgarian"])
        #expect(found?.map(\.id) == ["Assamese - English", "Bulgarian"], "the name is the row's identity")
    }

    /// **What is installed is not offered again**, whether it matches by the name macOS shows or by its folder's name:
    /// Dictionary.app's list keeps both spellings, and matching one of them is enough.
    @Test func anInstalledDictionaryIsNotOfferedAgain() {
        let entries = ["asset:/Oxford Dictionary of English.dictionary", "asset:/Bulgarian.dictionary",
                       "asset:/bulgarian.dictionary"]
        let installed = [Self.bundle("Oxford Dictionary of English", folder: "noad"), Self.bundle("Bulgarian", folder: "bg")]
        #expect(AvailableBundles.known(entries: entries, installed: installed) == [])
        let folderMatch = AvailableBundles.known(entries: ["asset:/noad.dictionary"], installed: installed)
        #expect(folderMatch == [], "the folder's own name is the second spelling")
        // And a name that matches neither is still offered: the rule drops what is here, not what looks similar.
        let different = AvailableBundles.known(entries: ["asset:/Oxford.dictionary"], installed: installed)
        #expect(different?.map(\.name) == ["Oxford"], "a dictionary whose name only begins like another's")
    }

    /// One name twice is one row: Dictionary.app appends to that list, and it is never rewritten from scratch.
    @Test func theSameNameTwiceIsOneRow() {
        let entries = ["asset:/Bulgarian.dictionary", "asset:/Bulgarian.dictionary", "asset:/ bulgarian .dictionary"]
        #expect(AvailableBundles.known(entries: entries, installed: [])?.map(\.name) == ["Bulgarian"])
    }

    /// **A list that could not be read is nil, not empty** (plan-setup-v2 WI-3 item 4): the sheet must be able to say
    /// "could not read" rather than draw a section that looks like nothing exists.
    @Test func anUnreadableListIsNotAnEmptyOne() {
        #expect(AvailableBundles.known(entries: nil, installed: []) == nil)
        #expect(AvailableBundles.known(entries: [], installed: []) == [])
    }

    /// **The rescan a finished download relies on** (plan-setup-v2 WI-3 item 3): the same preference read against a
    /// directory that has changed. A bundle that arrives under the AssetsV2 path leaves the available list and appears
    /// among the installed ones, which is what the sheet's two-second poll shows without a relaunch.
    @Test func aDownloadMovesTheEntryWithoutARelaunch() throws {
        let root = try SyntheticAppleBundle.tempDir().appending(path: "AssetsV2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = ["asset:/Assamese - English.dictionary", "asset:/Bulgarian.dictionary"]

        let before = try #require(AvailableBundles.known(entries: entries, installed: InstalledBundles.discover(root: root)))
        #expect(before.map(\.name) == ["Assamese - English", "Bulgarian"])
        #expect(InstalledBundles.discover(root: root).isEmpty)

        // The reader downloaded Bulgarian in Dictionary.app: macOS installs it under the AssetsV2 path.
        let data = root.appending(path: "b1.asset/AssetData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var overrides = SyntheticAppleBundle.Overrides()
        overrides.plist = try SyntheticAppleBundle.plist(displayName: "Bulgarian", identifier: "com.apple.dictionary.bg")
        try SyntheticAppleBundle.make(in: data, name: "Bulgarian", overrides)

        let installed = InstalledBundles.discover(root: root)
        #expect(installed.map(\.displayName) == ["Bulgarian"])
        let after = try #require(AvailableBundles.known(entries: entries, installed: installed))
        #expect(after.map(\.name) == ["Assamese - English"], "the downloaded one is installed now, not available")
    }
}
