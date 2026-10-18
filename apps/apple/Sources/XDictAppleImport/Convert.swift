import Foundation

// An Apple *.dictionary snapshot -> an MDX + MDD pair (ADR-0011 decision 2), as the spike's Python reference does it
// (kept outside this repository as the oracle).

/// The stylesheet's name in the MDD and in every entry's link: fixed, never derived from the output's name, so the
/// output's bytes do not depend on what it is called (ADR-0011 decision 6).
let stylesheetName = "apple.css"

/// A constant pattern; `nil` only if it does not compile, which is refused as a stylesheet fault, never a trap.
private func regex(_ p: String) throws -> NSRegularExpression {
    guard let re = try? NSRegularExpression(pattern: p) else { throw AppleImportError.corrupt(.stylesheet("pattern")) }
    return re
}

func readCSS(_ url: URL, name: String, limit: Int) throws -> String {
    let d = try readBounded(url, limit: limit, name: name)
    if d.count >= 2, (d[0] == 0xff && d[1] == 0xfe) || (d[0] == 0xfe && d[1] == 0xff) {
        guard let s = String(data: Data(d), encoding: .utf16) else { throw AppleImportError.corrupt(.stylesheet(name)) }
        return s
    }
    var bytes = d
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
    guard let s = String(validating: bytes, as: UTF8.self) else { throw AppleImportError.corrupt(.stylesheet(name)) }
    return s
}

private func sub(_ re: NSRegularExpression, _ template: String, in s: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
}

func adaptCSS(_ css: String, extra: String, name: String) throws -> String {
    var s = css
    s = sub(try regex("@namespace\\s+d\\s+url\\([^)]*\\)\\s*;"), "", in: s)
    s = sub(try regex("\\[d\\\\:([A-Za-z0-9_-]+)"), "[data-d-$1", in: s)
    s = sub(try regex("\\[d\\|([A-Za-z0-9_-]+)"), "[data-d-$1", in: s)
    if try regex("d\\\\:|\\bd\\|").firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
        throw AppleImportError.corrupt(.stylesheet(name))
    }
    return s + "\n" + extra
}

let fallbackCSS = """

/* added by apple2mdx: readers without ui-serif / CanvasText / -webkit-link */
body { font-family: ui-serif, Georgia, "Times New Roman", serif; color: CanvasText; }
a, a:hover { color: #1a5fb4; }
@media (prefers-color-scheme: dark) { a, a:hover { color: #78aeed; } }

"""

/// **The human account of a conversion**: counts, notes, and the detail of a refused entry. Kept apart from the
/// refusal itself, which is a kind (`AppleImportError`); nothing parses these lines.
public final class Report {
    public private(set) var lines: [String] = []
    private let echo: Bool
    public init(echo: Bool = false) { self.echo = echo }
    func say(_ s: String) {
        lines.append(s)
        if echo { print(s) }
    }
}

/// Files below `Contents/Resources` that belong in the MDD: symbolic links are refused, not followed; an empty file is
/// left out (the core's reader could not tell it from the next record, `MDictWriter.swift`).
func collectResources(res: URL, skipTop: Set<String>, stats: Stats) throws -> [MDictItem] {
    let fm = FileManager.default
    let root = res.resolvingSymlinksInPath()
    var found: [(rel: [String], url: URL, size: Int)] = []
    func walk(_ dir: URL, _ rel: [String]) throws {
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: dir.path).sorted() } catch {
            throw AppleImportError.unreadable(file: rel.joined(separator: "/"), code: (error as NSError).code)
        }
        for name in names {
            if rel.isEmpty, name.hasSuffix(".lproj") { continue }  // localisation folders are not packed
            let url = dir.appendingPathComponent(name)
            let path = rel + [name]
            let attrs: [FileAttributeKey: Any]
            do { attrs = try fm.attributesOfItem(atPath: url.path) } catch {
                throw AppleImportError.unreadable(file: path.joined(separator: "/"), code: (error as NSError).code)
            }
            let kind = attrs[.type] as? FileAttributeType
            if kind == .typeSymbolicLink { throw AppleImportError.symbolicLink(path.joined(separator: "/")) }
            if kind == .typeDirectory {
                try walk(url, path)
            } else if kind == .typeRegular {
                found.append((path, url, (attrs[.size] as? Int) ?? 0))
            }
        }
    }
    try walk(root, [])
    found.sort { $0.rel.joined(separator: "/") < $1.rel.joined(separator: "/") }
    var items: [MDictItem] = []
    var seen: Set<[UInt8]> = []
    for f in found {
        guard let first = f.rel.first else { continue }
        let top = f.rel.count == 1
        if first.hasSuffix(".lproj") || (top && skipTop.contains(first)) { continue }
        if top, first.lowercased().hasSuffix(".xsl") {
            stats.bump("xsl resource not packed")
            continue
        }
        if f.size == 0 {
            stats.bump("empty resource not packed")
            continue
        }
        let key = "\\" + f.rel.joined(separator: "\\")
        guard !f.rel.contains(where: { $0.contains("\\") || $0.contains("\0") }), seen.insert(Array(key.utf8)).inserted else {
            throw AppleImportError.corrupt(.resourceKey(key))
        }
        items.append(MDictItem(key: key, file: f.url, name: f.rel.joined(separator: "/")))
    }
    return items
}

private func validateName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
          !name.unicodeScalars.contains(where: { $0.value == 0 }) else {
        throw AppleImportError.unsafeOutputName(name)
    }
}

/// **Converts the bundle snapshot at `snapshot` into `<name>.mdx` and `<name>.mdd` in `outDir`** (ADR-0011 decisions 2
/// and 4). `snapshot` is the bundle's copy in the service's own container: the folder holding `Contents/`. Nothing in
/// `outDir` is replaced: a file already there of either name is refused before any work. Everything is built in a
/// staging folder inside `outDir` and moved into place only once both files are whole; a refusal leaves nothing.
///
/// The same snapshot writes the same bytes whatever `name` is, on any date, in any time zone (ADR-0011 decision 6).
public func convert(snapshot: URL, into outDir: URL, name: String, bounds: Bounds = .production,
                    report rep: Report = Report()) throws(AppleImportError) {
    do {
        try convertSnapshot(snapshot, into: outDir, name: name, bounds: bounds, report: rep)
    } catch let error as AppleImportError {
        throw error
    } catch {
        // Foundation's own failures (a folder not created, a move refused): the output could not be written.
        throw AppleImportError.unwritable(file: name, code: (error as NSError).code)
    }
}

private func convertSnapshot(_ bundle: URL, into outDir: URL, name: String, bounds: Bounds, report rep: Report) throws {
    try validateName(name)
    let names = ["\(name).mdx", "\(name).mdd"]
    for file in names {
        var st = stat()
        if lstat(outDir.appendingPathComponent(file).path, &st) == 0 { throw AppleImportError.outputExists(file: file) }
    }
    let stats = Stats()
    let props = try loadProperties(bundle: bundle, bounds: bounds)
    rep.say("bundle: \(props.displayName)")

    let budget = DecompressionBudget(limit: bounds.decompressedBytes)
    let raw = try readBody(bundle: bundle, props: props, bounds: bounds, budget: budget)
    let keytext = try readKeyText(bundle: bundle, props: props, bounds: bounds, budget: budget)
    rep.say("body entries: \(raw.count); articles with keys: \(keytext.count)")

    let res = try resourcesRoot(bundle: bundle)
    let (css, cssAttrs) = try loadStylesheet(bundle: bundle, props: props, limit: bounds.sourceFileBytes)
    rep.say("attributes selected by CSS (kept): \(cssAttrs.subtracting(htmlAttrs).sorted())")

    let transformer = EntryTransformer(cssAttrs: cssAttrs)
    var articles: [ParsedArticle] = []
    articles.reserveCapacity(raw.count)
    for a in raw {
        do {
            articles.append(try transformer.transform(a.xml, address: a.address, stats: stats))
        } catch let fault as EntryFault {
            rep.say("entry at section \(a.address.section), offset \(a.address.chunk): \(fault)")
            throw AppleImportError.corrupt(.entry(section: a.address.section, chunk: a.address.chunk))
        }
    }
    guard !articles.isEmpty else { throw AppleImportError.noEntries }
    var keyByID: [[UInt8]: String] = [:]
    for a in articles {
        guard keyByID.updateValue(a.key, forKey: Array(a.id.utf8)) == nil else { throw AppleImportError.corrupt(.duplicateEntryID(a.id)) }
    }
    let bodyAddresses = Set(articles.map { $0.address })
    let stray = keytext.keys.filter { !bodyAddresses.contains($0) }
    guard stray.isEmpty else { throw AppleImportError.corrupt(.strayKeys(count: stray.count)) }
    rep.say("entries without any KeyText key (kept, keyed by title/id): \(articles.filter { keytext[$0.address] == nil }.count)")

    let linkTag = Array("<link rel=\"stylesheet\" type=\"text/css\" href=\"\(stylesheetName)\">".utf8)
    let (items, redirects) = try buildRecords(articles: articles, keytext: keytext, keyByID: keyByID, linkTag: linkTag,
                                              stats: stats, report: rep)
    let all = items + redirects
    for it in all { try validateKey(it.key, isMDD: false) }
    rep.say("mdx records: \(items.count) articles + \(redirects.count) redirects = \(all.count)")

    // references must land on real keys
    let keys = Set(all.map { Array($0.key.utf8) })
    let dangling = redirects.filter {
        guard case .bytes(let b) = $0.payload else { return true }
        return !keys.contains(Array(b.dropFirst(8)))
    }
    guard dangling.isEmpty else { throw AppleImportError.corrupt(.danglingRedirects(count: dangling.count)) }

    let fm = FileManager.default
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    // The staging folder's name is random, and names nothing written: no byte of the output depends on it.
    let stage = outDir.appendingPathComponent(".xdict-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: stage) }

    // Title and description come from the bundle alone, never from `name` (ADR-0011 decision 6).
    let description = props.copyright.isEmpty ? props.displayName : props.copyright
    let meter = OutputMeter(limit: bounds.outputBytes)
    try writeMDict(items: all, isMDD: false, title: props.displayName, description: description,
                   to: stage.appendingPathComponent(names[0]), fileLimit: bounds.sourceFileBytes, meter: meter)

    // resources -> MDD
    let skipTop: Set<String> = ["Body.data", "KeyText.data", "KeyText.index", "EntryID.data", "EntryID.index", "fbm.css",
                                props.cssName ?? ""]
    var files = try collectResources(res: res, skipTop: skipTop, stats: stats)
    guard !files.contains(where: { $0.key == "\\\(stylesheetName)" }) else { throw AppleImportError.corrupt(.resourceKey("\\\(stylesheetName)")) }
    files.append(MDictItem(key: "\\\(stylesheetName)", data: Array(css.utf8)))
    try writeMDict(items: files, isMDD: true, title: props.displayName, description: description,
                   to: stage.appendingPathComponent(names[1]), fileLimit: bounds.sourceFileBytes, meter: meter)
    rep.say("mdd resources: \(files.count)")

    for (k, v) in stats.counts.sorted(by: { $0.key < $1.key }) { rep.say("note: \(k): \(v)") }
    let unresolved = stats.counts["link: id not in dictionary, fell back to keyword", default: 0]
        + stats.counts["link: target id unknown and no keyword", default: 0]
    rep.say("links: \(articles.reduce(0) { $0 + $1.links.count }) total, \(unresolved) not resolved by id")

    try publish(stage: stage, outDir: outDir, names: names)
}

/// Moves the finished files into place, each by a rename that refuses to replace anything (`RENAME_EXCL`); if one
/// fails, the ones already moved are taken back, so the output folder holds both or neither.
private func publish(stage: URL, outDir: URL, names: [String]) throws {
    var moved: [URL] = []
    for file in names {
        let target = outDir.appendingPathComponent(file)
        guard renamex_np(stage.appendingPathComponent(file).path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            for done in moved { unlink(done.path) }
            if code == EEXIST { throw AppleImportError.outputExists(file: file) }
            throw AppleImportError.unwritable(file: file, code: Int(code))
        }
        moved.append(target)
    }
}

/// The selected stylesheet (plus fbm.css, folded in) adapted for plain HTML, and the attribute names it selects on.
private func loadStylesheet(bundle: URL, props: Properties, limit: Int) throws -> (css: String, attrs: Set<String>) {
    let res = try resourcesRoot(bundle: bundle)
    let cssName = props.cssName ?? "DefaultStyle.css"
    var css = try adaptCSS(try readCSS(try resourceURL(bundle: bundle, name: cssName), name: cssName, limit: limit),
                           extra: fallbackCSS, name: cssName)
    if FileManager.default.fileExists(atPath: res.appendingPathComponent("fbm.css").path) {
        css += "\n/* front/back matter */\n"
            + (try adaptCSS(try readCSS(try resourceURL(bundle: bundle, name: "fbm.css"), name: "fbm.css", limit: limit),
                            extra: "", name: "fbm.css"))
    }
    var attrs = Set<String>()
    let attrRe = try regex("\\[\\s*([A-Za-z_][\\w:-]*)")
    for m in attrRe.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let range = Range(m.range(at: 1), in: css) else { continue }
        attrs.insert(String(css[range]))
    }
    return (css, attrs)
}

/// One primary record per article, and a `@@@LINK=` redirect for every other search key.
private func buildRecords(
    articles: [ParsedArticle], keytext: [Address: [Lexeme]], keyByID: [[UInt8]: String], linkTag: [UInt8], stats: Stats,
    report rep: Report
) throws -> (items: [MDictItem], redirects: [MDictItem]) {
    var redirects: [MDictItem] = []
    for a in articles {
        // Swift's String == / Set use Unicode canonical equivalence; MDict keys are compared by code
        // points, so exact UTF-8 bytes are the identity here.
        var seen: Set<[UInt8]> = [Array(a.key.utf8)]
        let lex = (keytext[a.address] ?? []).enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }
        for (_, l) in lex {
            let k = cleanKey(l.keyword)
            if k.isEmpty || seen.contains(Array(k.utf8)) { continue }
            seen.insert(Array(k.utf8))
            redirects.append(MDictItem(key: k, data: Array("@@@LINK=\(a.key)".utf8)))
        }
    }
    var allKeys = Set(articles.map { Array($0.key.utf8) })
    for r in redirects { allKeys.insert(Array(r.key.utf8)) }
    var items: [MDictItem] = []
    items.reserveCapacity(articles.count)
    for a in articles {
        let body: [UInt8]
        do { body = try patchLinks(a, keyByID: keyByID, keys: allKeys, stats: stats) } catch let fault as EntryFault {
            rep.say("links of \(a.id): \(fault)")
            throw AppleImportError.corrupt(.links(entryID: a.id))
        }
        guard body.contains(where: { !($0 == 0x20 || $0 == 0x0a) }) else { throw AppleImportError.corrupt(.emptyEntry(a.key)) }
        items.append(MDictItem(key: a.key, data: linkTag + body))
    }
    return (items, redirects)
}
