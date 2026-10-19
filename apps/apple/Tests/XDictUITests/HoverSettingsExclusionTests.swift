import Foundation
import Testing
import XDictCapture
@testable import XDictUI

/// **"Never look up in" is how a reader turns hover off in XDict's own windows** (owner, 2026-10-19: no separate toggle).
/// The picker takes XDict itself like any app, by the identifier its bundle declares, and the row names it.
@MainActor
struct HoverSettingsExclusionTests {
    /// A stand-in XDict.app: a bundle declaring XDict's identifier, in a folder of the test's own.
    private func fakeXDict() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("XDict.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "ai.xdict.app", "CFBundlePackageType": "APPL",
                                   "CFBundleName": "XDict"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func xdictItselfCanBePickedListedByNameAndRemoved() throws {
        #expect(!HoverPolicy.shipped.excludes(app: "ai.xdict.app"), "hover would be off in XDict by default")
        let app = try fakeXDict()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let excluded = try #require(HoverSettings.excluding(appAt: app, from: .shipped))
        #expect(excluded.excludes(app: "ai.xdict.app"))
        #expect(HoverSettings.readersOwn(in: excluded) == ["ai.xdict.app"], "XDict was not listed as the reader's own")
        // Its display name: "XDict", with ".app" only where Finder shows extensions.
        let name = AppName.name(of: "ai.xdict.app", locate: { $0 == "ai.xdict.app" ? app : nil })
        #expect(name == "XDict" || name == "XDict.app", "the row would show \(name ?? "the identifier")")
        var removed = excluded
        removed.excludedApps.remove("ai.xdict.app")
        #expect(!removed.excludes(app: "ai.xdict.app"))
    }
}
