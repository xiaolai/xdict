import Foundation
import XDictClient
import XDictContract

/// **The contract's answers in the shape `conformance/` writes them**: the serde shape of `xdict-core`'s types, as every
/// binding's suite projects them (`core/xdict-ffi/tests/swift/main.swift` from the binding's types; this from the
/// contract's, after the service converted them). An entry's HTML and a resource's bytes, which travel as the reply's
/// payload, are put back where the suites expect them: `html`, and `text` as UTF-8.
enum Projection {
    static func versions(_ v: Versions) -> [String: Any] {
        ["protocol": v.protocolVersion, "core": v.core, "indexFormat": v.indexFormat, "normalization": v.normalization]
    }

    static func info(_ i: DictInfo) -> [String: Any] {
        ["title": i.title, "description": i.description, "formatVersion": i.formatVersion, "keys": i.keys]
    }

    static func ref(_ e: EntryRef) -> [String: Any] {
        ["edition": e.edition.rawValue, "key": e.key, "occurrence": e.occurrence]
    }

    static func imported(_ i: Imported) -> [String: Any] {
        ["edition": i.edition.rawValue, "lineage": i.lineage.rawValue, "info": info(i.info), "problems": i.problems.map { problem in
            switch problem {
            case .volumeUnreadable(let name, let error): ["type": "volumeUnreadable", "name": name, "error": core(error)]
            }
        }]
    }

    static func opened(_ o: Opened) -> [String: Any] {
        switch o {
        case .ready(let dict, let edition, let i): ["type": "ready", "dict": dict.rawValue, "edition": edition.rawValue, "info": info(i)]
        case .needsImport(let reason): ["type": "needsImport", "reason": reason.rawValue]
        }
    }

    static func how(_ h: How) -> [String: Any] {
        switch h {
        case .exact: ["type": "exact"]
        case .folded: ["type": "folded"]
        case .unmarked: ["type": "unmarked"]
        case .redirect(let chain): ["type": "redirect", "chain": chain]
        }
    }

    static func hitProblem(_ p: HitProblem) -> [String: Any] {
        switch p {
        case .danglingRedirect(let from, let target): ["type": "danglingRedirect", "from": from, "target": target]
        case .redirectLoop(let chain): ["type": "redirectLoop", "chain": chain]
        case .redirectLimit(let chain): ["type": "redirectLimit", "chain": chain]
        }
    }

    static func page(_ p: Page) -> [String: Any] {
        ["hits": p.hits.map { hit -> [String: Any] in
            ["dict": hit.dict.rawValue, "entry": ref(hit.entry), "headword": hit.headword, "how": how(hit.how),
             "problems": hit.problems.map(hitProblem)]
        }, "total": p.total, "generation": p.generation, "problems": p.problems.map(hitProblem)]
    }

    static func entry(_ e: Entry, html: Data?) -> [String: Any] {
        ["entry": ref(e.entry), "html": String(decoding: html ?? Data(), as: UTF8.self), "csp": e.csp, "lossyBytes": e.lossyBytes]
    }

    static func link(_ l: Link) -> [String: Any] {
        switch l {
        case .lookup(let query, let anchor): ["type": "lookup", "query": query, "anchor": anchor ?? NSNull()]
        case .resource(let path): ["type": "resource", "path": path]
        case .sound(let path): ["type": "sound", "path": path]
        case .speak(let text): ["type": "speak", "text": text]
        case .anchor(let name): ["type": "anchor", "name": name]
        case .blocked(.remote(let url)): ["type": "blocked", "why": ["type": "remote", "url": url]]
        case .blocked(.script): ["type": "blocked", "why": ["type": "script"]]
        case .blocked(.unknownScheme(let scheme)): ["type": "blocked", "why": ["type": "unknownScheme", "scheme": scheme]]
        }
    }

    static func health(_ h: Health) -> [String: Any] {
        ["version": h.version, "entries": h.entries,
         "findings": h.findings.map { f -> [String: Any] in
             ["kind": f.kind.rawValue, "count": f.count, "name": f.name ?? NSNull(),
              "examples": f.examples.map { ["key": $0.key, "text": $0.text] }]
         },
         "classes": h.classes.map { ["name": $0.name, "count": $0.count] }]
    }

    static func resource(_ r: Resource, bytes: Data?) -> [String: Any] {
        switch r {
        case .found(let path, let mime): ["type": "found", "path": path, "mime": mime, "text": String(decoding: bytes ?? Data(), as: UTF8.self)]
        case .missing(let path): ["type": "missing", "path": path]
        }
    }
}
