import Foundation
import Testing
import XDictContract
import XDictInstruments

/// **The `library.health` comparison can fail** (AGENTS.md: a check that cannot fail is not a check): the expected file
/// reads, the same reports agree, and a count, a file name, a missing report and an extra folder each differ.
struct LibraryHealthTests {
    static let file = Data("""
        {"oed": {"entries": 9, "findings": [["missingFile", 4, "oed.css"], ["repaired", 2, null]]},
         "peu": {"entries": 3, "findings": []}}
        """.utf8)

    static func health(_ entries: UInt64, _ findings: [HealthFinding]) -> Health {
        Health(version: 1, entries: entries, findings: findings, classes: [])
    }

    @Test func theComparisonAgreesAndDisagreesWhereItShould() throws {
        let expected = try #require(LibraryHealth.expected(Self.file))
        let oed = Self.health(9, [HealthFinding(kind: .missingFile, count: 4, name: "oed.css", examples: []),
                                  HealthFinding(kind: .repaired, count: 2, name: nil, examples: [])])
        #expect(LibraryHealth.mismatches(expected: expected, got: ["oed": oed, "peu": Self.health(3, [])]).isEmpty)
        let counted = Self.health(9, [HealthFinding(kind: .missingFile, count: 5, name: "oed.css", examples: []),
                                      HealthFinding(kind: .repaired, count: 2, name: nil, examples: [])])
        #expect(LibraryHealth.mismatches(expected: expected, got: ["oed": counted, "peu": Self.health(3, [])]).count == 1)
        let named = Self.health(9, [HealthFinding(kind: .missingFile, count: 4, name: "oed.js", examples: []),
                                    HealthFinding(kind: .repaired, count: 2, name: nil, examples: [])])
        #expect(LibraryHealth.mismatches(expected: expected, got: ["oed": named, "peu": Self.health(3, [])]).count == 1)
        #expect(LibraryHealth.mismatches(expected: expected, got: ["oed": oed]) == ["peu: no report"])
        #expect(LibraryHealth.mismatches(expected: expected, got: ["oed": oed, "peu": Self.health(3, []), "x": oed])
                == ["x: not expected"])
        #expect(LibraryHealth.expected(Data("{\"oed\": {\"entries\": 1, \"findings\": [[\"x\"]]}}".utf8)) == nil)
    }
}
