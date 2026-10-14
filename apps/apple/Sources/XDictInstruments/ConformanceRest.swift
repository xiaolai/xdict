import Foundation
import XDictClient
import XDictContract

extension ConformanceScenario {
    /// One edition at two locations, both open at once, each serving its own sidecar (ADR-0007 objection 1): the MDX's
    /// bytes copied to a second file beside a sidecar of the expectation's text. Returns the second handle.
    func byteSource(_ x: [String: Any], dir: URL, first: DictId, render: RenderContext, _ c: inout Comparisons) async -> DictId? {
        guard let b = x["byteSource"] as? [String: Any], let sidecar = b["sidecar"] as? [String: Any],
              let name = sidecar["name"] as? String, let text = sidecar["text"] as? String else {
            c.fail("byteSource is not as the scenario reads it")
            return nil
        }
        let copy = scratch.appending(path: "copy", directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: dir.appending(path: "tiny.mdx"), to: copy.appending(path: "tiny.mdx"))
            try Data(text.utf8).write(to: copy.appending(path: name))
        } catch {
            c.fail("byteSource: the copy could not be made: \(error)")
            return nil
        }
        let package = DictionaryPackage.of(mdx: copy.appending(path: "tiny.mdx"), sidecars: [copy.appending(path: name)])
        c.compare("byteSource.import", b["import"], Self.imported(await client.importPackage(package)))
        let opened = await client.open(package)
        c.compare("byteSource.open", b["open"], Self.opened(opened))
        guard case .success(.ready(let second, _, _)) = opened else { return nil }
        c.compare("byteSource.resourceFromPath", b["resourceFromPath"],
                  Self.resource(await client.call(.resource(dict: first, path: name, render: render))))
        c.compare("byteSource.resourceFromSource", b["resourceFromSource"],
                  Self.resource(await client.call(.resource(dict: second, path: name, render: render))))
        return second
    }

    /// The errors no other step provokes, each through the contract.
    func errors(_ x: [String: Any], dir: URL, second: DictId?, render: RenderContext, _ c: inout Comparisons) async {
        let e = x["errors"] as? [String: Any] ?? [:]
        for kind in ["unsupported", "malformed"] {
            let step = e[kind] as? [String: Any] ?? [:]
            let package = DictionaryPackage.of(mdx: dir.appending(path: step["file"] as? String ?? ""))
            c.compare("errors.\(kind)", ["error": step["error"] ?? NSNull()], Self.imported(await client.importPackage(package)))
        }
        // Asked another way: an import long enough (eight 4 MiB chunks) that a cancel sent right behind it, on the same
        // connection, finds it running and stops it at its next report.
        let heavy = DictionaryPackage.of(mdx: fixtures.appending(path: "slow/heavy.mdx"))
        let ticket = await client.submitImport(heavy)
        let cancel = await client.cancelImport(ticket)
        if cancel != .success(.stopping) { c.fail("errors.cancelled: the cancel found no running import: \(cancel)") }
        let cancelled = (e["cancelled"] as? [String: Any])?["error"] ?? NSNull()
        c.compare("errors.cancelled", ["error": cancelled], P.outcome(await ticket.outcome()) { "\($0.answer)" })
        // Asked another way: the second package's sidecar rewritten in place, equal in size, after it opened.
        guard let second else { return c.fail("errors.sourceChanged: no second package was open") }
        let changed = (e["sourceChanged"] as? [String: Any])?["error"] ?? NSNull()
        do {
            let sidecar = try FileHandle(forUpdating: scratch.appending(path: "copy/tiny.css"))
            try sidecar.seek(toOffset: 0)
            try sidecar.write(contentsOf: Data("B".utf8))
            try sidecar.close()
        } catch {
            return c.fail("errors.sourceChanged: the sidecar could not be rewritten: \(error)")
        }
        c.compare("errors.sourceChanged", ["error": changed],
                  Self.resource(await client.call(.resource(dict: second, path: "tiny.css", render: render))))
    }

    /// A closed handle is stale; closing it again is not an error.
    func lifecycle(_ x: [String: Any], dict: DictId, second: DictId?, _ c: inout Comparisons) async {
        let l = x["lifecycle"] as? [String: Any] ?? [:]
        guard let second else { return c.fail("lifecycle: no second package was open") }
        _ = await client.close(second)
        let page = LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)
        c.compare("lifecycle.afterClose", l["afterClose"],
                  P.outcome(await client.call(.lookup(query: "run", dicts: [second], options: page))) { "\($0.answer)" })
        c.compare("lifecycle.closeTwice", l["closeTwice"], P.outcome(await client.close(second)) { d -> Any in
            d.answer == .closed ? "ok" : "\(d.answer)"
        })
    }

    /// `matrix/`: every variant imported, opened and asked the same questions, `$word`, `$gloss` and `$version` replaced
    /// in the expectation's text with the variant's own.
    func matrix(_ c: inout Comparisons) async {
        let dir = fixtures.appending(path: "matrix")
        guard let template = try? String(contentsOf: dir.appending(path: "expected.json"), encoding: .utf8),
              let variants = (try? Data(contentsOf: dir.appending(path: "variants.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] else {
            return c.fail("matrix/expected.json or variants.json could not be read")
        }
        c.compare("matrix.variants", 32, variants.count)
        let render = RenderContext(maxBodyBytes: 1 << 20)
        for v in variants {
            let name = v["name"] as? String ?? ""
            let text = template.replacingOccurrences(of: "$word", with: v["word"] as? String ?? "")
                .replacingOccurrences(of: "$gloss", with: v["gloss"] as? String ?? "")
                .replacingOccurrences(of: "$version", with: v["version"] as? String ?? "")
            guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                c.fail("\(name): the expectation does not parse once replaced")
                continue
            }
            let package = DictionaryPackage.of(mdx: dir.appending(path: "\(name).mdx"))
            let imported = await client.importPackage(package)
            c.compare("\(name).import", m["import"], Self.imported(imported))
            let opened = await client.open(package)
            c.compare("\(name).open", m["open"], Self.opened(opened))
            guard case .success(let i) = imported, case .success(.ready(let dict, _, _)) = opened else { continue }
            for (n, q) in ((m["lookups"] as? [[String: Any]]) ?? []).enumerated() {
                let options = LookupOptions(limit: Self.uint32(q["limit"]) ?? 0, offset: Self.uint32(q["offset"]) ?? 0,
                                            mode: .reader, generation: nil)
                let got = await client.call(.lookup(query: q["query"] as? String ?? "", dicts: [dict], options: options))
                c.compare("\(name).lookups[\(n)]", q["page"], P.outcome(got) { d -> Any in
                    if case .page(let page) = d.answer { return P.page(page) } else { return "\(d.answer)" }
                })
            }
            for (n, q) in ((m["entries"] as? [[String: Any]]) ?? []).enumerated() {
                let e = q["entry"] as? [String: Any] ?? [:]
                let ref = EntryRef(edition: i.edition, key: e["key"] as? String ?? "", occurrence: Self.uint32(e["occurrence"]) ?? 0)
                let got = await client.call(.entry(dict: dict, entry: ref, render: render))
                c.compare("\(name).entries[\(n)]", q["result"], P.outcome(got) { d -> Any in
                    if case .entry(let entry) = d.answer { return P.entry(entry, html: d.payload) } else { return "\(d.answer)" }
                })
            }
            _ = await client.close(dict)
        }
    }
}
