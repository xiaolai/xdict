import Foundation
import XDictClient
import XDictContract

extension ConformanceScenario {
    /// **The display options each open dictionary declares** (`displayOptions` in `tiny/expected.json`; ADR-0013): tiny's
    /// own (none), then each case's dictionary imported with its sidecars and asked, through the contract, for its
    /// options and the CSS a shell applies, compared with the core's own answer exactly.
    func displayOptions(_ x: [String: Any], dir: URL, tiny: DictId, _ c: inout Comparisons) async {
        guard let n = x["displayOptions"] as? [String: Any], let cases = n["cases"] as? [[String: Any]] else {
            return c.fail("tiny/expected.json has no displayOptions to ask")
        }
        c.compare("displayOptions.tiny", n["tiny"], await Self.options(client.call(.displayOptions(dict: tiny))))
        for (index, entry) in cases.enumerated() {
            guard let file = entry["mdx"] as? String else { c.fail("displayOptions.cases[\(index)] names no mdx"); continue }
            let sidecars = ((entry["sidecars"] as? [String]) ?? []).map { dir.appending(path: $0) }
            let package = DictionaryPackage.of(mdx: dir.appending(path: file), volumes: [], sidecars: sidecars)
            guard case .success = await client.importPackage(package),
                  case .success(.ready(let dict, _, _)) = await client.open(package) else {
                c.fail("displayOptions.cases[\(index)]: \(file) did not import and open")
                continue
            }
            c.compare("displayOptions.cases[\(index)]", entry["result"], await Self.options(client.call(.displayOptions(dict: dict))))
        }
    }

    private static func options(_ outcome: ClientOutcome) -> Any {
        Projection.outcome(outcome) { delivered -> Any in
            guard case .displayOptions(let answer) = delivered.answer else { return "\(delivered.answer)" }
            return [
                "version": answer.version,
                "options": answer.options.map { option -> [String: Any] in
                    ["id": option.id, "attribute": option.attribute, "values": option.values,
                     "defaultValue": option.defaultValue]
                },
                "css": answer.css,
            ] as [String: Any]
        }
    }
}
