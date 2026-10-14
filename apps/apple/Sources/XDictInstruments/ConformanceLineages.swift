import Foundation
import XDictClient
import XDictContract

extension ConformanceScenario {
    /// **The reader's joins and splits** (`lineages` in `tiny/expected.json`; ADR-0002 decision 3), through the contract:
    /// a rebuilt file imported, joined to tiny's lineage and joined again (idempotent), split back to the lineage it had,
    /// split to a lineage the client minted and split so again (a retried split is the same split), then the refusals.
    /// Each lineage answered is compared as a label, `tiny` or `rebuilt`, since the service mints them at random.
    func lineages(_ x: [String: Any], dir: URL, tiny: Imported, _ c: inout Comparisons) async {
        guard let n = x["lineages"] as? [String: Any], let file = n["file"] as? String,
              let minted = n["newLineage"] as? String, let unknownEdition = n["unknownEdition"] as? String,
              let unknownLineage = n["unknownLineage"] as? String, let notALineage = n["notALineage"] as? String
        else { return c.fail("tiny/expected.json has no lineages to ask") }
        let outcome = await client.importPackage(DictionaryPackage.of(mdx: dir.appending(path: file), volumes: [], sidecars: []))
        guard case .success(let rebuilt) = outcome else { return c.fail("lineages: \(file) did not import: \(outcome)") }
        func label(_ value: Any) -> Any {
            guard let id = value as? String else { return value }
            return id == tiny.lineage.rawValue ? "tiny" : id == rebuilt.lineage.rawValue ? "rebuilt" : id
        }
        var projected = P.imported(rebuilt)
        projected["lineage"] = label(rebuilt.lineage.rawValue)
        c.compare("lineages.import", n["import"], projected)

        func ask(_ operation: ServiceOperation) async -> Any {
            label(P.outcome(await client.call(operation)) { delivered -> Any in
                guard case .lineage(let id) = delivered.answer else { return "\(delivered.answer)" }
                return id?.rawValue ?? NSNull()
            })
        }
        let edition = rebuilt.edition
        let join = ServiceOperation.joinLineage(edition: edition, lineage: tiny.lineage)
        let splitBack = ServiceOperation.splitLineage(edition: edition, newLineage: rebuilt.lineage)
        let splitToNew = ServiceOperation.splitLineage(edition: edition, newLineage: LineageId(rawValue: minted))
        c.compare("lineages.before", n["before"], await ask(.lineageOf(edition: edition)))
        c.compare("lineages.join", n["join"], await ask(join))
        c.compare("lineages.afterJoin", n["afterJoin"], await ask(.lineageOf(edition: edition)))
        c.compare("lineages.joinAgain", n["joinAgain"], await ask(join))
        c.compare("lineages.split", n["split"], await ask(splitBack))
        c.compare("lineages.afterSplit", n["afterSplit"], await ask(.lineageOf(edition: edition)))
        c.compare("lineages.splitToNew", n["splitToNew"], await ask(splitToNew))
        c.compare("lineages.splitToNewAgain", n["splitToNewAgain"], await ask(splitToNew))
        c.compare("lineages.joinUnknownEdition", n["joinUnknownEdition"],
                  await ask(.joinLineage(edition: Edition(rawValue: unknownEdition), lineage: tiny.lineage)))
        c.compare("lineages.lineageOfUnknownEdition", n["lineageOfUnknownEdition"],
                  await ask(.lineageOf(edition: Edition(rawValue: unknownEdition))))
        c.compare("lineages.joinUnknownLineage", n["joinUnknownLineage"],
                  await ask(.joinLineage(edition: edition, lineage: LineageId(rawValue: unknownLineage))))
        c.compare("lineages.splitNotALineage", n["splitNotALineage"],
                  await ask(.splitLineage(edition: edition, newLineage: LineageId(rawValue: notALineage))))
        c.compare("lineages.splitIntoAnother", n["splitIntoAnother"],
                  await ask(.splitLineage(edition: tiny.edition, newLineage: rebuilt.lineage)))
    }
}
