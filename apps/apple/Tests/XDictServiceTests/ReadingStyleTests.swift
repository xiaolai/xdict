import Foundation
import Testing
import XDictClient
import XDictContract

/// **The reading style's report through the real service** (ADR-0010, owner's decision of 2026-10-17; contract 4): the
/// service reads the dictionary's sheets and computes the report; the client only receives it.
struct ReadingStyleTests {
    @Test func theServiceReportsAnOpenDictionarysReadingStyle() async throws {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "tiny.mdx").path),
                     "no tiny fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [dir.appending(path: "tiny.mdd")],
                                           sidecars: [dir.appending(path: "tiny.css")])
        guard case .success = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the tiny fixture did not import and open")
            return
        }
        let outcome = await client.call(.readingStyle(dict: dict))
        guard case .success(let delivered) = outcome, case .readingStyle(let style) = delivered.answer else {
            Issue.record("no reading style: \(outcome)")
            return
        }
        // tiny.css is `.tiny { color: black !important }`: one sheet read, its colour made a palette
        // token (the declaration replaced whole, so no `!important` is counted), no font kept.
        #expect(style.version > 0)
        #expect(style.sheets == ["tiny.css"])
        #expect(style.skipped.isEmpty && style.fonts.isEmpty)
        #expect(style.changes.colour == 1 && style.changes.important == 0, "\(style.changes)")
        #expect(style.basePx > 0)
    }
}
