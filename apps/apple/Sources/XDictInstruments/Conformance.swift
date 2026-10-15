import Foundation
import XDictClient
import XDictContract

/// **`conformance/`'s fixtures answered through the contract**, as the bindings' suites answer them through their
/// binding (`conformance/README.md`), compared the same way (`subset`). The scenario's steps run in its order against
/// the service behind `client`; what the contract cannot ask is named in `notThroughTheContract`, and what it asks
/// another way in `askedAnotherWay`, so nothing of `expected.json` is skipped silently: a key this scenario does not
/// know fails it.
public struct ConformanceScenario: Sendable {
    let client: ServiceClient
    /// `Tools/build-fixtures.sh`'s directory: `tiny/`, `matrix/`, `slow/`.
    let fixtures: URL
    /// An empty directory of the scenario's own, for the copy `byteSource` opens beside the original.
    let scratch: URL

    public init(client: ServiceClient, fixtures: URL, scratch: URL) {
        self.client = client
        self.fixtures = fixtures
        self.scratch = scratch
    }

    /// Steps of `tiny/` that no client of the contract can take, and why.
    static let notThroughTheContract: [String: String] = [
        "newWrongProtocol": "the service makes its core with its own protocol; a client cannot ask for another",
        "byteSource.shortRead": "a source here is a descriptor the service reads; none returns a byte too few",
        "errors.notFound": "the contract carries no path, so there is no absent file to name",
        "lifecycle.foreignHandle": "one service runs one core; a restarted service's handle is the kill check's",
        "lifecycle.panic": "selfTestPanic is not an operation of the contract",
    ]

    /// Steps taken another way, and how.
    static let askedAnotherWay: [String: String] = [
        "byteSource": "the same MDX bytes copied to a second file with its own sidecar, sent as handles",
        "suggestions (limit over 100)": "refused by the contract (suggestLimitOutOfRange) before the core's own cap",
        "errors.cancelled": "slow/heavy.mdx imported with a cancel sent right behind it",
        "errors.sourceChanged": "the second package's sidecar rewritten in place, equal in size, after it opened",
    ]

    /// The keys each part of `tiny/expected.json` may hold.
    static let known: [String: Set<String>] = [
        "": ["comment", "view", "versions", "newWrongProtocol", "openBeforeImport", "import", "open", "lookups",
             "suggestions", "entries", "links", "resources", "health", "byteSource", "errors", "lifecycle", "lineages"],
        "byteSource": ["comment", "name", "identity", "sidecar", "import", "open", "resourceFromPath", "resourceFromSource",
                       "shortRead"],
        "errors": ["comment", "unsupported", "malformed", "notFound", "cancelled", "sourceChanged"],
        "lifecycle": ["afterClose", "closeTwice", "foreignHandle", "panic"],
        "lineages": ["comment", "file", "newLineage", "unknownEdition", "unknownLineage", "notALineage", "import", "before",
                     "join", "afterJoin", "joinAgain", "split", "afterSplit", "splitToNew", "splitToNewAgain",
                     "joinUnknownEdition", "lineageOfUnknownEdition", "joinUnknownLineage", "splitNotALineage",
                     "splitIntoAnother"],
    ]

    /// Comparisons made, and the first difference of each that failed.
    struct Comparisons {
        var count = 0
        var failures: [String] = []

        mutating func compare(_ name: String, _ expected: Any?, _ actual: Any) {
            count += 1
            if let failure = subset(expected ?? NSNull(), actual, name) { failures.append(failure) }
        }

        mutating func fail(_ why: String) {
            count += 1
            failures.append(why)
        }

        func record(_ name: String, into findings: inout Findings) {
            let shown = failures.prefix(12).joined(separator: "; ")
            findings.check(name, failures.isEmpty && count > 0, failures.isEmpty
                ? "\(count) comparisons agree"
                : "\(failures.count) of \(count) differ: \(shown)\(failures.count > 12 ? "; …" : "")")
        }
    }

    public func run() async -> Findings {
        var findings = Findings()
        var tiny = Comparisons()
        await self.tiny(&tiny)
        tiny.record("conformance.tiny", into: &findings)
        var matrix = Comparisons()
        await self.matrix(&matrix)
        matrix.record("conformance.matrix", into: &findings)
        findings.fact("conformance.notThroughTheContract", Self.notThroughTheContract.keys.sorted().joined(separator: ", "))
        findings.fact("conformance.askedAnotherWay", Self.askedAnotherWay.keys.sorted().joined(separator: ", "))
        return findings
    }

    // MARK: - Reading

    static func object(at url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    static func uint32(_ value: Any?) -> UInt32? { (value as? NSNumber)?.uint32Value }
    static func uint64(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value }

    /// Every key of `expected` that this scenario does not know, by its path.
    static func unknownKeys(_ expected: [String: Any]) -> [String] {
        var unknown = Set(expected.keys).subtracting(known[""] ?? []).map { $0 }
        for part in ["byteSource", "errors", "lifecycle", "lineages"] {
            let keys = Set((expected[part] as? [String: Any])?.keys.map { $0 } ?? [])
            unknown += keys.subtracting(known[part] ?? []).map { "\(part).\($0)" }
        }
        return unknown.sorted()
    }
}
