// The conformance scenario (conformance/README.md) through the UniFFI Swift binding.
// Usage: conformance <fixture dir written by conformance-fixtures> <expected.json>
// Exits 1 with every mismatch printed, 0 when all agree.

import Foundation

// MARK: - Results as the suites compare them: the serde shape of xdict-core's types

func j(_ v: Versions) -> [String: Any] {
    ["protocol": v.protocol, "core": v.core, "indexFormat": v.indexFormat, "normalization": v.normalization]
}

func j(_ i: DictInfo) -> [String: Any] {
    ["title": i.title, "description": i.description, "formatVersion": i.formatVersion, "keys": i.keys]
}

func j(_ e: EntryRef) -> [String: Any] { ["edition": e.edition, "key": e.key, "occurrence": e.occurrence] }

func j(_ p: Problem) -> [String: Any] {
    switch p {
    case let .volumeUnreadable(name, error): return ["type": "volumeUnreadable", "name": name, "error": j(error)]
    }
}

func j(_ i: Imported) -> [String: Any] {
    ["edition": i.edition, "lineage": i.lineage, "info": j(i.info), "problems": i.problems.map(j)]
}

func j(_ r: ImportReason) -> String {
    switch r {
    case .new: return "new"
    case .changed: return "changed"
    case .indexMissing: return "indexMissing"
    case .indexOutdated: return "indexOutdated"
    case .noIdentity: return "noIdentity"
    }
}

func j(_ o: Opened) -> [String: Any] {
    switch o {
    case let .ready(dict, edition, info): return ["type": "ready", "dict": dict, "edition": edition, "info": j(info)]
    case let .needsImport(reason): return ["type": "needsImport", "reason": j(reason)]
    }
}

func j(_ h: How) -> [String: Any] {
    switch h {
    case .exact: return ["type": "exact"]
    case .folded: return ["type": "folded"]
    case .unmarked: return ["type": "unmarked"]
    case let .redirect(chain): return ["type": "redirect", "chain": chain]
    }
}

func j(_ p: HitProblem) -> [String: Any] {
    switch p {
    case let .danglingRedirect(from, target): return ["type": "danglingRedirect", "from": from, "target": target]
    case let .redirectLoop(chain): return ["type": "redirectLoop", "chain": chain]
    }
}

func j(_ h: Hit) -> [String: Any] {
    ["dict": h.dict, "entry": j(h.entry), "headword": h.headword, "how": j(h.how), "problems": h.problems.map(j)]
}

func j(_ p: Page) -> [String: Any] {
    ["hits": p.hits.map(j), "total": p.total, "generation": p.generation, "problems": p.problems.map(j)]
}

func j(_ e: Entry) -> [String: Any] { ["entry": j(e.entry), "html": e.html, "csp": e.csp, "lossyBytes": e.lossyBytes] }

func j(_ b: BlockReason) -> [String: Any] {
    switch b {
    case let .remote(url): return ["type": "remote", "url": url]
    case .script: return ["type": "script"]
    case let .unknownScheme(scheme): return ["type": "unknownScheme", "scheme": scheme]
    }
}

func j(_ l: Link) -> [String: Any] {
    switch l {
    case let .lookup(query, anchor): return ["type": "lookup", "query": query, "anchor": anchor ?? NSNull()]
    case let .resource(path): return ["type": "resource", "path": path]
    case let .sound(path): return ["type": "sound", "path": path]
    case let .speak(text): return ["type": "speak", "text": text]
    case let .anchor(name): return ["type": "anchor", "name": name]
    case let .blocked(why): return ["type": "blocked", "why": j(why)]
    }
}

func j(_ r: Resource) -> [String: Any] {
    switch r {
    case let .found(path, mime, bytes):
        return ["type": "found", "path": path, "mime": mime, "text": String(decoding: bytes, as: UTF8.self)]
    case let .missing(path): return ["type": "missing", "path": path]
    }
}

func j(_ f: Feature) -> [String: Any] {
    switch f {
    case let .formatVersion(version): return ["type": "formatVersion", "version": version]
    case .resourceLibraryV3: return ["type": "resourceLibraryV3"]
    case .registrationCode: return ["type": "registrationCode"]
    case let .encryptionFlags(flags): return ["type": "encryptionFlags", "flags": flags]
    case .lzoInV3: return ["type": "lzoInV3"]
    case let .compressionType(code): return ["type": "compressionType", "code": code]
    case let .blockEncryption(code): return ["type": "blockEncryption", "code": code]
    case let .encoding(name): return ["type": "encoding", "name": name]
    }
}

func j(_ l: Limit) -> String {
    switch l {
    case .file: return "file"
    case .page: return "page"
    case .body: return "body"
    }
}

func j(_ m: Missing) -> String {
    switch m {
    case .file: return "file"
    case .entry: return "entry"
    }
}

func j(_ k: IoKind) -> String {
    switch k {
    case .notFound: return "notFound"
    case .permissionDenied: return "permissionDenied"
    case .shortRead: return "shortRead"
    case .outOfMemory: return "outOfMemory"
    case .other: return "other"
    }
}

func j(_ e: CoreError) -> [String: Any] {
    switch e {
    case let .Unsupported(feature, detail): return ["type": "unsupported", "feature": j(feature), "detail": detail]
    case let .Malformed(detail): return ["type": "malformed", "detail": detail]
    case let .TooLarge(limit, detail): return ["type": "tooLarge", "limit": j(limit), "detail": detail]
    case let .NotFound(what, detail): return ["type": "notFound", "what": j(what), "detail": detail]
    case let .Io(kind, detail): return ["type": "io", "kind": j(kind), "detail": detail]
    case let .StaleHandle(detail): return ["type": "staleHandle", "detail": detail]
    case let .EditionMismatch(detail): return ["type": "editionMismatch", "detail": detail]
    case let .SourceChanged(detail): return ["type": "sourceChanged", "detail": detail]
    case let .Cancelled(detail): return ["type": "cancelled", "detail": detail]
    case let .Incompatible(core, client, detail):
        return ["type": "incompatible", "core": core, "client": client, "detail": detail]
    case let .Internal(detail): return ["type": "internal", "detail": detail]
    }
}

/// A call's outcome: its value, or `["error": …]`.
func outcome(_ call: () throws -> Any) -> Any {
    do { return try call() } catch let e as CoreError { return ["error": j(e)] } catch {
        return ["error": ["type": "notACoreError", "detail": "\(error)"]]
    }
}

// MARK: - Comparison

func number(_ v: Any) -> NSNumber? {
    switch v {
    case let n as NSNumber: return n
    case let n as UInt64: return NSNumber(value: n)
    case let n as UInt32: return NSNumber(value: n)
    case let n as UInt8: return NSNumber(value: n)
    case let n as Int: return NSNumber(value: n)
    default: return nil
    }
}

func subset(_ expected: Any, _ actual: Any, _ at: String) -> String? {
    if let e = expected as? [String: Any] {
        guard let a = actual as? [String: Any] else { return "\(at): expected an object, found \(actual)" }
        for (key, value) in e where key != "comment" {
            guard let found = a[key] else { return "\(at).\(key): missing in \(a)" }
            if let failure = subset(value, found, "\(at).\(key)") { return failure }
        }
        return nil
    }
    if let e = expected as? [Any] {
        guard let a = actual as? [Any], a.count == e.count else { return "\(at): expected \(e), found \(actual)" }
        for (i, pair) in zip(e, a).enumerated() {
            if let failure = subset(pair.0, pair.1, "\(at)[\(i)]") { return failure }
        }
        return nil
    }
    if expected is NSNull { return actual is NSNull ? nil : "\(at): expected null, found \(actual)" }
    if let e = expected as? String, let a = actual as? String { return e == a ? nil : "\(at): expected \(e), found \(a)" }
    if let e = number(expected), let a = number(actual) { return e == a ? nil : "\(at): expected \(e), found \(a)" }
    return "\(at): expected \(expected), found \(actual)"
}

// MARK: - A source the shell implements

final class Bytes: ByteSource, @unchecked Sendable {
    let bytes: Data
    let ident: FileIdentity?
    let short: Bool
    init(_ bytes: Data, _ ident: FileIdentity?, short: Bool = false) {
        self.bytes = bytes
        self.ident = ident
        self.short = short
    }
    func size() -> UInt64 { UInt64(bytes.count) }
    func readAt(offset: UInt64, len: UInt32) throws -> Data {
        let start = Int(offset)
        let end = min(start + Int(len), bytes.count) - (short ? 1 : 0)
        return bytes.subdata(in: start..<end)
    }
    func identity() -> FileIdentity? { ident }
}

// MARK: - The scenario

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: conformance <fixture dir> <expected.json>")
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let x = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
var failures: [String] = []
func check(_ name: String, _ expected: Any?, _ actual: Any) {
    if let failure = subset(expected ?? NSNull(), actual, name) { failures.append(failure) }
}
func at(_ name: String) -> Location { .path(path: dir.appendingPathComponent(name).path) }
let viewSpec = x["view"] as! [String: Any]
func view(_ max: UInt64? = nil) -> View {
    View(baseUrl: viewSpec["baseUrl"] as! String, skin: nil,
         maxBodyBytes: max ?? (viewSpec["maxBodyBytes"] as! NSNumber).uint64Value)
}
func config(_ client: UInt32) -> Config { Config(dataDir: nil, cacheDir: nil, clientProtocol: client, entropy: Data()) }
func int(_ v: Any?) -> UInt32? { (v as? NSNumber)?.uint32Value }

check("versions", x["versions"], j(versions()))
let wrong = x["newWrongProtocol"] as! [String: Any]
check("newWrongProtocol", wrong["error"], (outcome { _ = try Core(config: config(int(wrong["client"])!)); return "made" } as? [String: Any])?["error"] ?? "made")

let core = try Core(config: config(protocolVersion()))
check("openBeforeImport", x["openBeforeImport"], outcome { j(try core.open(location: at("tiny.mdx"))) })
let imported = try core.import(package: Package(mdx: at("tiny.mdx"), mdd: [at("tiny.mdd")], sidecars: [at("tiny.css")]), progress: nil)
check("import", x["import"], j(imported))
let opened = try core.open(location: at("tiny.mdx"))
check("open", x["open"], j(opened))
guard case let .ready(dict, _, _) = opened else { fatalError("not open") }

for (i, c) in (x["lookups"] as! [[String: Any]]).enumerated() {
    let options = LookupOptions(limit: int(c["limit"])!, offset: int(c["offset"])!, mode: .reader, generation: int(c["generation"]))
    let got = outcome { j(try core.lookup(query: c["query"] as! String, dicts: [dict], options: options)) }
    check("lookups[\(i)]", c["error"].map { ["error": $0] } ?? c["page"], got)
}
for (i, c) in (x["suggestions"] as! [[String: Any]]).enumerated() {
    check("suggestions[\(i)]", c["keys"], outcome { try core.suggest(prefix: c["prefix"] as! String, dicts: [dict], limit: int(c["limit"])!) })
}
for (i, c) in (x["entries"] as! [[String: Any]]).enumerated() {
    let e = c["entry"] as! [String: Any]
    let ref = EntryRef(edition: (c["edition"] as? String) ?? imported.edition, key: e["key"] as! String, occurrence: int(e["occurrence"])!)
    let got = outcome { j(try core.entry(dict: dict, entry: ref, view: view((c["maxBodyBytes"] as? NSNumber)?.uint64Value))) }
    if let needle = c["cspContains"] as? String, let entry = got as? [String: Any] {
        check("entries[\(i)].csp contains \(needle)", true, ((entry["csp"] as? String) ?? "").contains(needle))
    }
    check("entries[\(i)]", c["error"].map { ["error": $0] } ?? c["result"], got)
}
let origin = LinkOrigin.entry(entry: EntryRef(edition: imported.edition, key: "run", occurrence: 0))
for (i, c) in (x["links"] as! [[String: Any]]).enumerated() {
    check("links[\(i)]", c["link"], outcome { j(try core.link(dict: dict, url: c["url"] as! String, origin: origin, view: view())) })
}
for (i, c) in (x["resources"] as! [[String: Any]]).enumerated() {
    check("resources[\(i)]", c["resource"], outcome { j(try core.resource(dict: dict, path: c["path"] as! String, view: view())) })
}

let b = x["byteSource"] as! [String: Any]
let mdx = try Data(contentsOf: dir.appendingPathComponent("tiny.mdx"))
let idSpec = b["identity"] as! [String: Any]
let ident = FileIdentity(device: (idSpec["device"] as! NSNumber).uint64Value, inode: (idSpec["inode"] as! NSNumber).uint64Value,
                         size: (idSpec["size"] as! NSNumber).uint64Value, mtimeNs: (idSpec["mtimeNs"] as! NSNumber).int64Value,
                         ctimeNs: (idSpec["ctimeNs"] as! NSNumber).int64Value)
let copy = Location.source(name: b["name"] as! String, source: Bytes(mdx, ident))
let sidecarSpec = b["sidecar"] as! [String: Any]
let sidecar = Location.source(name: sidecarSpec["name"] as! String, source: Bytes(Data((sidecarSpec["text"] as! String).utf8), nil))
check("byteSource.import", b["import"], outcome { j(try core.import(package: Package(mdx: copy, mdd: [], sidecars: [sidecar]), progress: nil)) })
let second = try core.open(location: copy)
check("byteSource.open", b["open"], j(second))
guard case let .ready(secondDict, _, _) = second else { fatalError("not open") }
check("byteSource.resourceFromPath", b["resourceFromPath"], outcome { j(try core.resource(dict: dict, path: "tiny.css", view: view())) })
check("byteSource.resourceFromSource", b["resourceFromSource"], outcome { j(try core.resource(dict: secondDict, path: "tiny.css", view: view())) })
let short = Package(mdx: .source(name: "short.mdx", source: Bytes(mdx, nil, short: true)), mdd: [], sidecars: [])
check("byteSource.shortRead", b["shortRead"], outcome { j(try core.import(package: short, progress: nil)) })

let l = x["lifecycle"] as! [String: Any]
let page = LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)
try core.close(dict: secondDict)
check("lifecycle.afterClose", l["afterClose"], outcome { j(try core.lookup(query: "run", dicts: [secondDict], options: page)) })
check("lifecycle.closeTwice", l["closeTwice"], outcome { try core.close(dict: secondDict); return "ok" })
let other = try Core(config: config(protocolVersion()))
check("lifecycle.foreignHandle", l["foreignHandle"], outcome { j(try other.lookup(query: "run", dicts: [dict], options: page)) })
check("lifecycle.panic", l["panic"], outcome { try core.selfTestPanic(); return "returned" })

if failures.isEmpty {
    print("swift conformance: all agree")
} else {
    print("swift conformance: \(failures.count) failures")
    failures.forEach { print("  " + $0) }
    exit(1)
}
