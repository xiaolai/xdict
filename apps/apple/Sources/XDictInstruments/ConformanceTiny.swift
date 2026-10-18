import Foundation
import XDictClient
import XDictContract

extension ConformanceScenario {
    typealias P = Projection

    /// `tiny/`, in the README's order: versions, open before import, import, open, then each question in the view.
    func tiny(_ c: inout Comparisons) async {
        let dir = fixtures.appending(path: "tiny")
        guard let x = Self.object(at: dir.appending(path: "expected.json")) else {
            return c.fail("tiny/expected.json could not be read")
        }
        for key in Self.unknownKeys(x) { c.fail("tiny/expected.json holds \(key), which this scenario does not know") }
        guard let view = x["view"] as? [String: Any], view["baseUrl"] as? String == RenderContext.baseURL,
              let ceiling = Self.uint64(view["maxBodyBytes"]) else {
            return c.fail("the view is not the contract's base with a ceiling: \(x["view"] ?? "none")")
        }
        let render = RenderContext(maxBodyBytes: ceiling)

        c.compare("versions", x["versions"], P.outcome(await client.call(.versions)) { d -> Any in
            if case .versions(let v) = d.answer { return P.versions(v) } else { return "\(d.answer)" }
        })
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [dir.appending(path: "tiny.mdd")],
                                           sidecars: [dir.appending(path: "tiny.css")])
        c.compare("openBeforeImport", x["openBeforeImport"], Self.opened(await client.open(package)))
        let imported = await client.importPackage(package)
        c.compare("import", x["import"], Self.imported(imported))
        let opened = await client.open(package)
        c.compare("open", x["open"], Self.opened(opened))
        guard case .success(let i) = imported, case .success(.ready(let dict, _, _)) = opened else {
            return c.fail("tiny did not import and open, so nothing else was asked")
        }
        await questions(x, dict: dict, edition: i.edition, render: render, &c)
        await displayOptions(x, dir: dir, tiny: dict, &c)
        let second = await byteSource(x, dir: dir, first: dict, render: render, &c)
        await errors(x, dir: dir, second: second, render: render, &c)
        await lifecycle(x, dict: dict, second: second, &c)
        await lineages(x, dir: dir, tiny: i, &c)
    }

    static func opened(_ outcome: Result<Opened, ClientFailure>) -> Any {
        switch outcome {
        case .success(let opened): P.opened(opened)
        case .failure(let why): P.failure(why)
        }
    }

    static func imported(_ outcome: Result<Imported, ClientFailure>) -> Any {
        switch outcome {
        case .success(let imported): P.imported(imported)
        case .failure(let why): P.failure(why)
        }
    }

    /// Lookups, suggestions, entries, links and resources, each case as `expected.json` lists it.
    private func questions(_ x: [String: Any], dict: DictId, edition: Edition, render: RenderContext,
                           _ c: inout Comparisons) async {
        var generations: [UInt32?] = []
        for (n, q) in ((x["lookups"] as? [[String: Any]]) ?? []).enumerated() {
            let continued = (q["generation"] as? [String: Any]).flatMap { Self.uint32($0["of"]) }
                .flatMap { generations.indices.contains(Int($0)) ? generations[Int($0)] : nil }
            let options = LookupOptions(limit: Self.uint32(q["limit"]) ?? 0, offset: Self.uint32(q["offset"]) ?? 0,
                                        mode: q["mode"] as? String == "link" ? .link : .reader, generation: continued)
            let got = await client.call(.lookup(query: q["query"] as? String ?? "", dicts: [dict], options: options))
            if case .success(let d) = got, case .page(let page) = d.answer { generations.append(page.generation) } else {
                generations.append(nil)
            }
            c.compare("lookups[\(n)]", q["error"].map { ["error": $0] } ?? q["page"], P.outcome(got) { d -> Any in
                if case .page(let page) = d.answer { return P.page(page) } else { return "\(d.answer)" }
            })
        }
        for (n, q) in ((x["suggestions"] as? [[String: Any]]) ?? []).enumerated() {
            let limit = Self.uint32(q["limit"]) ?? 0
            let got = await client.call(.suggest(prefix: q["prefix"] as? String ?? "", dicts: [dict], limit: limit))
            let actual = P.outcome(got) { d -> Any in
                if case .suggestions(let keys) = d.answer { return keys } else { return "\(d.answer)" }
            }
            if limit > Limits.maxSuggestions {
                // Asked another way: the contract refuses before the core's own cap (MAX_SUGGEST) is reached.
                let refused: ClientOutcome = .failure(.wire(.refused(.suggestLimitOutOfRange(requested: limit,
                                                                                              ceiling: Limits.maxSuggestions))))
                if got != refused { c.fail("suggestions[\(n)]: expected the contract's refusal, found \(actual)") } else { c.count += 1 }
            } else {
                c.compare("suggestions[\(n)]", q["error"].map { ["error": $0] } ?? q["keys"], actual)
            }
        }
        for (n, q) in ((x["entries"] as? [[String: Any]]) ?? []).enumerated() {
            let e = q["entry"] as? [String: Any] ?? [:]
            let ref = EntryRef(edition: (q["edition"] as? String).map(Edition.init) ?? edition, key: e["key"] as? String ?? "",
                               occurrence: Self.uint32(e["occurrence"]) ?? 0)
            let view = Self.uint64(q["maxBodyBytes"]).map { RenderContext(maxBodyBytes: $0) } ?? render
            let got = P.outcome(await client.call(.entry(dict: dict, entry: ref, render: view))) { d -> Any in
                if case .entry(let entry) = d.answer { return P.entry(entry, html: d.payload) } else { return "\(d.answer)" }
            }
            if let needle = q["cspContains"] as? String {
                let csp = (got as? [String: Any])?["csp"] as? String ?? ""
                if csp.contains(needle) { c.count += 1 } else { c.fail("entries[\(n)].csp lacks \(needle): \(csp)") }
            }
            c.compare("entries[\(n)]", q["error"].map { ["error": $0] } ?? q["result"], got)
        }
        let origin = LinkOrigin.entry(entry: EntryRef(edition: edition, key: "run", occurrence: 0))
        for (n, q) in ((x["links"] as? [[String: Any]]) ?? []).enumerated() {
            let got = await client.call(.link(dict: dict, url: q["url"] as? String ?? "", origin: origin, render: render))
            c.compare("links[\(n)]", q["link"], P.outcome(got) { d -> Any in
                if case .link(let link) = d.answer { return P.link(link) } else { return "\(d.answer)" }
            })
        }
        for (n, q) in ((x["resources"] as? [[String: Any]]) ?? []).enumerated() {
            // ADR-0010 Q3: a case may ask for the dictionary's own style.
            let styled = RenderContext(maxBodyBytes: render.maxBodyBytes, originalStyle: q["originalStyle"] as? Bool ?? false)
            let got = await client.call(.resource(dict: dict, path: q["path"] as? String ?? "", render: styled))
            c.compare("resources[\(n)]", q["resource"], Self.resource(got))
        }
        c.compare("health", x["health"], Projection.outcome(await client.submitHealth(dict).outcome()) { d -> Any in
            if case .health(let health) = d.answer { return Projection.health(health) }
            return "\(d.answer)"
        })
    }

    static func resource(_ outcome: ClientOutcome) -> Any {
        Projection.outcome(outcome) { d -> Any in
            if case .resource(let resource) = d.answer { return Projection.resource(resource, bytes: d.payload) }
            return "\(d.answer)"
        }
    }
}
