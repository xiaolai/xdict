import Foundation
import Testing
import XDictTestSupport

/// **A document's finish is acknowledged only for the lookup the entry view was asked to show** (plan-capture WI-4
/// rule 3, settling the refutation's objection 3): `entryFinished` took the model's *current* query for the finished
/// document's, so a stale document that finished in the gap before a newer lookup's entry request was credited to the
/// newer term. The app target runs no test, so the composition is read off the code; the rule itself is
/// `PresentedEntryTests` and the acknowledgement's own rules are `PresentationAcksTests`.
struct DocumentDrawWiringTests {
    static let anywhere = "Sources/XDict/LookupAnywhere.swift"
    static let window = "Sources/XDictUI/SearchWindowState.swift"

    @Test func theFinishIsAcknowledgedOnlyForThePresentedLookup() throws {
        let text = try String(contentsOf: Manifest.package.appending(path: Self.anywhere), encoding: .utf8)
        let body = try #require(Self.function("entryFinished", in: text), "entryFinished was not found")
        #expect(body.contains("drew(query:"), "the premise: entryFinished still acknowledges a finished document")
        #expect(body.contains("showsPresentedLookup"), "a finished document was acknowledged without asking whose it was")
    }

    @Test func theWindowRecordsTheLookupItHandedTheView() throws {
        let text = try String(contentsOf: Manifest.package.appending(path: Self.window), encoding: .utf8)
        #expect(Self.recordedAsks(text) == 2,
                "the scan read \(Self.recordedAsks(text)) recorded asks, wanted one each in present and presentPage")
        #expect(Self.unguardedAsks(text) == 0, "an ask was recorded for a show that never reached WebKit")
        // The lookup identity travels with the value: the shown entry's own lookup against the one shown now.
        let shown = try #require(Self.body(of: "var showsPresentedLookup", in: text),
                                 "showsPresentedLookup was not found")
        #expect(shown.contains("shown.lookup == model.lookup?.serial"),
                "the shown entry's own lookup was not compared with the lookup shown now")
    }

    @Test func anAskForAShowThatFailedIsNamed() {
        #expect(Self.unguardedAsks("if done { presentedEntry.asked(serial: shown.serial) }\n") == 0)
        #expect(Self.unguardedAsks("presentedEntry.asked(serial: shown.serial)\n") == 1)
    }

    static func function(_ name: String, in text: String) -> String? { body(of: "func \(name)(", in: text) }

    /// A declaration (`func foo(`, `var bar`) to its balanced closing brace, comments and strings blanked first.
    static func body(of declaration: String, in text: String) -> String? {
        let code = SourceScan.codeOnly(text)
        guard let start = code.range(of: declaration) else { return nil }
        var depth = 0
        var began = false
        var index = start.lowerBound
        while index < code.endIndex {
            if code[index] == "{" { depth += 1; began = true }
            if code[index] == "}" {
                depth -= 1
                if began, depth == 0 { return String(code[start.lowerBound...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    static func recordedAsks(_ text: String) -> Int {
        SourceScan.codeOnly(text).matches(of: /presentedEntry\.asked\(serial: shown\.serial, lookup: shown\.lookup\)/).count
    }

    /// An ask not on the line of an `if done { … }`.
    static func unguardedAsks(_ text: String) -> Int {
        SourceScan.codeOnly(text).split(separator: "\n").filter {
            $0.contains("presentedEntry.asked(") && !$0.contains("if done")
        }.count
    }
}
