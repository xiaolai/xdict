import Foundation
import Testing
import XDictClient
import XDictContract

/// **The app cannot turn the core's strip list off.** `Config.stripOffForTests` exists for the hostile battery's lab alone
/// (`XDictEntryLab --disable-layer strip`); the service makes its core without it, and nothing the app sends over the
/// contract names it. Through the real service: the battery's `ok-xdict` entry, whose inline script only reports, comes
/// back without that script, and its image stays; a comment (S2) goes too.
struct StripTests {
    @Test func theServiceStripsAnEntrysScriptsWhateverTheAppAsks() async throws {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: "hostile")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "hostile.mdx").path),
                     "no hostile fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "hostile.mdx"),
                                           volumes: [dir.appending(path: "hostile.mdd")], sidecars: [])
        guard case .success(let imported) = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the hostile fixture did not import and open")
            return
        }
        func html(_ key: String) async -> String {
            let ref = EntryRef(edition: imported.edition, key: key, occurrence: 0)
            let delivered = await client.call(.entry(dict: dict, entry: ref, render: RenderContext(maxBodyBytes: 1 << 20)))
            guard case .success(let d) = delivered, case .entry = d.answer else {
                Issue.record("no entry \(key): \(delivered)")
                return ""
            }
            return String(decoding: d.payload ?? Data(), as: UTF8.self)
        }
        let ok = await html("ok-xdict")
        #expect(ok.contains("ok.svg"), "the entry did not come back: \(ok.prefix(300))")
        #expect(!ok.contains("R('ok','inline')"), "the service kept a script the strip list drops")
        // S2: the battery's textarea case hides its payload behind a comment; the service drops the comment whole.
        let hidden = await html("img~textarea")
        #expect(hidden.contains("<textarea"), "the entry did not come back: \(hidden.prefix(300))")
        #expect(!hidden.contains("<!--"), "the service kept a comment the strip list drops: \(hidden.prefix(300))")
    }
}
