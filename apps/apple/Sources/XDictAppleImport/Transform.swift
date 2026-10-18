import Foundation

// Apple entry XML -> plain HTML, as a single streaming pass over a strict XML tokenizer.
// Behaviour matches the spike's Python reference (kept outside this repository as an oracle) so outputs can be compared.
// A fault is an `EntryFault`: its detail is for the conversion's report, and the caller refuses the entry by kind,
// `AppleImportError.corrupt(.entry)` or `.corrupt(.links)` (ADR-0011 decision 11).

let dNS = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
let xhtmlNS = "http://www.w3.org/1999/xhtml"
let xmlNS = "http://www.w3.org/XML/1998/namespace"
let xmlnsNS = "http://www.w3.org/2000/xmlns/"
/// XHTML front matter: dropped (with content) in the XHTML namespace only.
private let dropTags: Set<String> = ["head", "meta", "link", "script", "title", "base"]
/// Elements that run or embed foreign content: dropped in any namespace an entry can legally use.
private let activeTags: Set<String> = ["script", "iframe", "object", "embed", "applet"]
private let unwrapTags: Set<String> = ["html", "body"]
/// libxml2's HTML "empty" elements (checked against the pinned lxml): serialized without an end
/// tag, and their content is not serialized at all.
private let voidTags: Set<String> = [
    "area", "base", "basefont", "br", "col", "frame", "hr", "img", "input", "isindex", "link", "meta", "param",
]
/// libxml2 writes these attributes bare (`<td nowrap>`), whatever their value.
private let booleanAttrs: Set<String> = [
    "checked", "compact", "declare", "defer", "disabled", "ismap", "multiple", "nohref", "noresize", "noshade",
    "nowrap", "readonly", "selected",
]
/// Attributes with a function in plain HTML; the rest is editorial metadata unless the CSS selects it.
let htmlAttrs: Set<String> = [
    "id", "class", "href", "src", "alt", "title", "lang", "style", "width", "height",
    "colspan", "rowspan", "align", "valign", "border", "frame", "rules", "size",
    "cellpadding", "cellspacing", "summary", "scope", "headers", "start", "type",
]
let linkPlaceholder = "apple2mdx-link:"
/// libxml2's default element nesting limit (without XML_PARSE_HUGE).
private let maxDepth = 256

/// Why an entry could not be transformed: a detail for the report, never shown as a refusal's words.
struct EntryFault: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class Stats {
    var counts: [String: Int] = [:]
    func bump(_ key: String, _ n: Int = 1) { counts[key, default: 0] += n }
    func merge(_ other: Stats) { for (k, v) in other.counts { counts[k, default: 0] += v } }
}

struct LinkRef {
    let id: String
    var fallback: String
    let anchor: String
}

struct ParsedArticle {
    let id: String
    let key: String
    var html: [UInt8]
    let address: Address
    var links: [LinkRef]
    /// href prefix standing in for each link until all keys are known; occurs exactly once per link in `html`.
    var placeholder: String = linkPlaceholder
}

func isPythonSpace(_ u: Unicode.Scalar) -> Bool {
    u.properties.isWhitespace || (0x1c...0x1f).contains(u.value)
}

/// Collapse whitespace runs to single spaces and trim (Python's " ".join(s.split())).
func cleanKey(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for u in s.unicodeScalars {
        if isPythonSpace(u) {
            pendingSpace = !out.isEmpty
        } else {
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(u)
        }
    }
    return String(out)
}

private func pythonStrip(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while let l = scalars.last, isPythonSpace(l) { scalars.removeLast() }
    var start = 0
    while start < scalars.count, isPythonSpace(scalars[start]) { start += 1 }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: scalars[start...])
    return String(v)
}

/// A constant pattern, so it compiles; were it ever not to, every link is refused as unparsable, loudly.
private let linkRegex: NSRegularExpression? = {
    let pattern =
        "^x-dictionary:r:(?<id>[^:#]+)(?::(?<dict>[^:#]*))?"
        + "(?:#xpointer\\(//\\*\\[@id='(?<anchor>[^']+)'\\]\\))?(?::(?<kw>.*))?$"
    return try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
}()

// MARK: serialization (libxml2's HTML writer, as reached through lxml)

private let amp = Array("&amp;".utf8), lt = Array("&lt;".utf8), gt = Array("&gt;".utf8), cr = Array("&#13;".utf8)

/// `&`, `<`, `>` and a literal CR become references; everything else is written as is.
private func entityEncode(_ s: ArraySlice<UInt8>, into out: inout [UInt8]) {
    for c in s {
        switch c {
        case 0x26: out += amp
        case 0x3c: out += lt
        case 0x3e: out += gt
        case 0x0d: out += cr
        default: out.append(c)
        }
    }
}

private let hexDigits = Array("0123456789ABCDEF".utf8)

private func appendAttribute(name: String, value: String, parent: String, to out: inout [UInt8]) {
    out.append(0x20)
    out += Array(name.utf8)
    let lname = name.lowercased()
    if booleanAttrs.contains(lname) { return }
    var encoded: [UInt8] = []
    entityEncode(Array(value.utf8)[...], into: &encoded)
    let isURI = lname == "href" || lname == "src" || lname == "action" || (lname == "name" && parent.lowercased() == "a")
    if isURI {
        var start = 0
        while start < encoded.count, [0x20, 0x09, 0x0a, 0x0d].contains(encoded[start]) { start += 1 }
        var escaped: [UInt8] = []
        for b in encoded[start...] {
            if b <= 0x20 || b == 0x7f || b >= 0x80 {
                escaped += [0x25, hexDigits[Int(b >> 4)], hexDigits[Int(b & 15)]]
            } else {
                escaped.append(b)
            }
        }
        encoded = escaped
    }
    out += [0x3d]
    var quote: UInt8 = 0x22
    var escapeDouble = false
    if encoded.contains(0x22) {
        if encoded.contains(0x27) { escapeDouble = true } else { quote = 0x27 }
    }
    out.append(quote)
    for c in encoded {
        if c == 0x22, escapeDouble { out += Array("&quot;".utf8) } else { out.append(c) }
    }
    out.append(quote)
}

/// True for a URL whose scheme can run script (browsers ignore whitespace/control bytes in it).
/// Attributes whose value is a URL the reader may follow or load.
let urlAttributes: Set<String> = ["href", "src", "xlink:href", "action", "formaction", "data", "poster", "background", "codebase", "cite", "longdesc", "usemap", "profile", "manifest"]

func isUnsafeURL(_ url: String) -> Bool {
    var squeezed = ""
    for u in url.unicodeScalars where u.value > 0x20 && u.value != 0x7f { squeezed.unicodeScalars.append(u) }
    let s = squeezed.lowercased()
    let unsafe = s.hasPrefix("javascript:") || s.hasPrefix("vbscript:") || s.hasPrefix("data:")
    return unsafe && !s.hasPrefix("data:image/")
}

// MARK: XML names (XML 1.0 fifth edition, as libxml2 applies them)

private func isNameStart(_ v: UInt32) -> Bool {
    switch v {
    case 0x3a, 0x41...0x5a, 0x5f, 0x61...0x7a, 0xc0...0xd6, 0xd8...0xf6, 0xf8...0x2ff, 0x370...0x37d, 0x37f...0x1fff,
         0x200c...0x200d, 0x2070...0x218f, 0x2c00...0x2fef, 0x3001...0xd7ff, 0xf900...0xfdcf, 0xfdf0...0xfffd,
         0x10000...0xeffff:
        return true
    default:
        return false
    }
}

private func isNameChar(_ v: UInt32) -> Bool {
    isNameStart(v) || v == 0x2d || v == 0x2e || (0x30...0x39).contains(v) || v == 0xb7 || (0x300...0x36f).contains(v)
        || (0x203f...0x2040).contains(v)
}

/// Splits a QName; each part must be an NCName (a Name without ":").
private func splitQName(_ bytes: [UInt8]) throws -> (prefix: [UInt8]?, local: [UInt8]) {
    func valid(_ part: ArraySlice<UInt8>) -> Bool {
        guard !part.isEmpty else { return false }
        var first = true
        for u in String(decoding: part, as: UTF8.self).unicodeScalars {
            if u.value == 0x3a { return false }
            if first ? !isNameStart(u.value) : !isNameChar(u.value) { return false }
            first = false
        }
        return true
    }
    let shown = String(decoding: bytes, as: UTF8.self)
    if let c = bytes.firstIndex(of: 0x3a) {
        let p = bytes[..<c], l = bytes[(c + 1)...]
        guard valid(p), valid(l) else { throw EntryFault("invalid XML name \(shown.debugDescription)") }
        return (Array(p), Array(l))
    }
    guard valid(bytes[...]) else { throw EntryFault("invalid XML name \(shown.debugDescription)") }
    return (nil, bytes)
}

private let xmlPrefix = Array("xml".utf8), xmlnsPrefix = Array("xmlns".utf8)

// MARK: transformer

private struct Open {
    var qname: [UInt8]
    var outName: String?  // nil: unwrapped or suppressed, nothing written
    var isVoid = false
    var suppresses = false
    var linkIndex: Int?
    var bindings: [(prefix: [UInt8], previous: String?)] = []
}

struct EntryTransformer {
    /// nil keeps every attribute (used by tests); otherwise attributes outside HTML are kept only if listed.
    var cssAttrs: Set<String>?

    func transform(_ xml: ArraySlice<UInt8>, address: Address, stats: Stats) throws -> ParsedArticle {
        // Only a leading BOM is encoding noise; one inside the text is content (U+FEFF is a legal XML char).
        var bytes = Array(xml)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard String(validating: bytes, as: UTF8.self) != nil else { throw EntryFault("entry is not valid UTF-8") }
        try checkXMLCharacters(bytes)

        // The placeholder prefix must not occur anywhere in the entry's own text.
        var attempt = 0
        while true {  // every failed attempt means the text really contains that prefix, so this ends
            defer { attempt += 1 }
            let prefix = attempt == 0 ? linkPlaceholder : "apple2mdx-link\(attempt):"
            let local = Stats()
            var article = try transformOnce(bytes, address: address, stats: local, linkPrefix: prefix)
            let found = countOccurrences(of: Array(prefix.utf8), in: article.html)
            if found == article.links.count {
                article.placeholder = prefix
                stats.merge(local)
                return article
            }
            if found < article.links.count { throw EntryFault("\(article.id): link placeholders lost in serialization") }
        }
    }

    /// What an emitted element finally looks like: attributes renamed and filtered, a PDF `<img>` turned
    /// into a link, dictionary links replaced by numbered placeholders (recorded in `links`).
    private func finalAttributes(
        _ resolved: [(ns: String, local: [UInt8], prefixed: Bool, value: String)], element: String, rootID: String,
        linkPrefix: String, stats: Stats, links: inout [LinkRef]
    ) throws -> (name: String, attrs: [(String, String)], innerText: String?, linkIndex: Int?, voidAtStart: Bool) {
        // plain attributes keep their place; namespaced ones are renamed and moved to the end
        var final: [(String, String)] = []
        var renamed: [(String, String)] = []
        for a in resolved {
            let l = String(decoding: a.local, as: UTF8.self)
            if !a.prefixed {
                final.append((l, a.value))
            } else if a.ns == dNS {
                renamed.append(("data-d-" + l, a.value))
            } else if a.ns == xhtmlNS || a.ns == xmlNS {
                renamed.append((l, a.value))
            } else {
                throw EntryFault("unexpected attribute namespace \(a.ns) on \(l)")
            }
        }
        for (n, v) in renamed {
            if let at = final.firstIndex(where: { Array($0.0.utf8) == Array(n.utf8) }) { final[at].1 = v } else { final.append((n, v)) }
        }
        // event handlers and script URLs never survive, whatever the stylesheet selects
        var kept: [(String, String)] = []
        for (n, v) in final {
            let ln = n.lowercased()
            if ln.hasPrefix("on") {
                stats.bump("event-handler attributes dropped")
            } else if urlAttributes.contains(ln) && isUnsafeURL(v) {
                stats.bump("unsafe URL attributes dropped")
            } else {
                kept.append((n, v))
            }
        }
        final = kept
        if let keep = cssAttrs {
            let before = final.count
            final.removeAll { !htmlAttrs.contains($0.0) && !keep.contains($0.0) }
            stats.bump("metadata attributes dropped", before - final.count)
        }
        var name = element
        let voidAtStart = voidTags.contains(name.lowercased())  // content of an empty element is never kept
        var innerText: String?
        if name == "img", let src = final.first(where: { $0.0 == "src" })?.1, src.lowercased().hasSuffix(".pdf") {
            let alt = final.first { $0.0 == "alt" }?.1 ?? ""
            innerText = alt.isEmpty ? src : alt
            final.removeAll { ["src", "alt", "width", "height", "style"].contains($0.0) }
            if let at = final.firstIndex(where: { $0.0 == "href" }) { final[at].1 = src } else { final.append(("href", src)) }
            name = "a"
            stats.bump("pdf <img> turned into link")
        }
        var linkIndex: Int?
        if name == "a", let at = final.firstIndex(where: { $0.0 == "href" }), final[at].1.hasPrefix("x-dictionary:") {
            let href = final[at].1
            let index = links.count
            if href.hasPrefix("x-dictionary:d:") {  // by search term, not by entry id
                links.append(LinkRef(id: "", fallback: String(href.dropFirst("x-dictionary:d:".count)), anchor: ""))
            } else {
                let range = NSRange(href.startIndex..., in: href)
                guard let m = linkRegex?.firstMatch(in: href, options: [], range: range) else {
                    throw EntryFault("\(rootID): unparsable link \(href)")
                }
                func group(_ g: String) -> String {
                    let gr = m.range(withName: g)
                    guard gr.location != NSNotFound, let rr = Range(gr, in: href) else { return "" }
                    return String(href[rr])
                }
                let kw = group("kw")
                let titleAttr = final.first { $0.0 == "title" }?.1 ?? ""
                links.append(LinkRef(id: group("id"), fallback: kw.isEmpty ? titleAttr : kw, anchor: group("anchor")))
                linkIndex = index
            }
            final[at].1 = "\(linkPrefix)\(index)"
        }
        return (name, final, innerText, linkIndex, voidAtStart)
    }

    private func transformOnce(_ bytes: [UInt8], address: Address, stats: Stats, linkPrefix: String) throws -> ParsedArticle {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var links: [LinkRef] = []
        var stack: [Open] = []
        var scope: [[UInt8]: String] = [xmlPrefix: xmlNS]
        var suppress = 0
        var rootID = ""
        var rootTitle = ""
        var rootClosed = false
        var activeLinks: [(index: Int, text: [UInt8])] = []
        var xmlIDs: Set<String> = []  // xml:id values must be unique NCNames (libxml2 enforces this)
        var i = 0
        let n = bytes.count

        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }

        /// Name of the nearest element that is actually written (the parent in the flattened tree).
        func nearestEmitted() -> String? {
            for e in stack.reversed() { if let n = e.outName { return n } }
            return nil
        }

        func text(_ t: [UInt8]) throws {
            if stack.isEmpty {
                guard t.allSatisfy(isWS) else { throw EntryFault("text outside the root element") }
                return
            }
            if suppress > 0 { return }
            let parent = nearestEmitted()?.lowercased()
            if parent == "style" {
                // raw text is not entity-encoded, so a "<" (reachable through CDATA) must not survive:
                // "</style>" would end the element early.  "\3c " is the CSS escape for "/".
                for (k, b) in t.enumerated() {
                    out.append(b)
                    if b == 0x3c, k + 1 < t.count, t[k + 1] == 0x2f { out.append(0x5c) }  // "</" -> "<\/"
                }
            } else if parent == "script" {
                out += t  // raw-text elements are not entity-encoded
            } else {
                entityEncode(t[...], into: &out)
            }
            for j in activeLinks.indices { activeLinks[j].text += t }
        }

        func uri(of prefix: [UInt8]?, forAttribute: Bool) throws -> String {
            guard let p = prefix else { return forAttribute ? "" : (scope[[]] ?? "") }
            guard let u = scope[p] else {
                throw EntryFault("undeclared namespace prefix \(String(decoding: p, as: UTF8.self))")
            }
            return u
        }

        func open(qname: [UInt8], attrs: [(name: [UInt8], value: String)], selfClose: Bool) throws {
            guard stack.count < maxDepth else { throw EntryFault("Excessive depth in document: \(maxDepth)") }
            let (prefix, localBytes) = try splitQName(qname)
            var entry = Open(qname: qname, outName: nil)

            // namespace declarations first: they apply to the element's own name and its attributes
            var declared: Set<[UInt8]> = []
            var plain: [(prefix: [UInt8]?, local: [UInt8], value: String)] = []
            var seenNames: Set<[UInt8]> = []
            for (rawName, value) in attrs {
                guard seenNames.insert(rawName).inserted else {
                    throw EntryFault("attribute \(String(decoding: rawName, as: UTF8.self)) redefined")
                }
                let (p, l) = try splitQName(rawName)
                let isDefaultDecl = p == nil && l == xmlnsPrefix
                if isDefaultDecl || p == xmlnsPrefix {
                    let bound: [UInt8] = isDefaultDecl ? [] : l
                    if p == xmlnsPrefix {
                        guard bound != xmlnsPrefix else { throw EntryFault("redefinition of the xmlns prefix is forbidden") }
                        guard !value.isEmpty else { throw EntryFault("xmlns:\(String(decoding: bound, as: UTF8.self)): empty namespace") }
                        if bound == xmlPrefix {
                            guard value == xmlNS else { throw EntryFault("xml namespace prefix mapped to wrong URI") }
                        } else if value == xmlNS {
                            throw EntryFault("the xml namespace may only be bound to the xml prefix")
                        }
                    } else if value == xmlNS {
                        throw EntryFault("the xml namespace may only be bound to the xml prefix")
                    }
                    guard value != xmlnsNS else { throw EntryFault("reuse of the xmlns namespace name is forbidden") }
                    guard declared.insert(bound).inserted else { throw EntryFault("namespace declaration repeated") }
                    entry.bindings.append((bound, scope[bound]))
                    scope[bound] = value
                } else {
                    plain.append((p, l, value))
                }
            }
            let ns = try uri(of: prefix, forAttribute: false)
            // every attribute prefix must resolve, and no expanded name may repeat, inside dropped subtrees too
            var expanded: Set<[UInt8]> = []
            var resolved: [(ns: String, local: [UInt8], prefixed: Bool, value: String)] = []
            for a in plain {
                let u = try uri(of: a.prefix, forAttribute: true)
                var key = Array(u.utf8)
                key.append(0)
                key += a.local
                guard expanded.insert(key).inserted else {
                    throw EntryFault("namespaced attribute \(String(decoding: a.local, as: UTF8.self)) redefined")
                }
                if u == xmlNS, a.local == Array("id".utf8) {
                    let id = a.value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
                    let scalars = id.unicodeScalars
                    guard let first = scalars.first, first.value != 0x3a, isNameStart(first.value),
                          scalars.allSatisfy({ $0.value != 0x3a && isNameChar($0.value) })
                    else { throw EntryFault("xml:id value \(a.value.debugDescription) is not an NCName") }
                    guard xmlIDs.insert(id).inserted else { throw EntryFault("xml:id \(id.debugDescription) already defined") }
                }
                resolved.append((u, a.local, a.prefix != nil, a.value))
            }

            let local = String(decoding: localBytes, as: UTF8.self)
            let lname = local.lowercased()
            let qnameText = String(decoding: qname, as: UTF8.self)
            if stack.isEmpty {
                guard ns == dNS, local == "entry" else { throw EntryFault("root is not d:entry (\(qnameText))") }
                entry.outName = "div"
                for a in resolved where !a.prefixed && a.local == Array("id".utf8) { rootID = a.value }
                for a in resolved where a.ns == dNS && a.local == Array("title".utf8) { rootTitle = a.value }
            } else if suppress > 0 {
                // inside a dropped subtree or a void element: only keep the structure balanced
            } else if (ns.isEmpty || ns == xhtmlNS) && (activeTags.contains(lname) || (ns == xhtmlNS && dropTags.contains(local))) {
                suppress += 1
                entry.suppresses = true
                stats.bump("dropped <\(lname)>")
            } else if ns == dNS || (ns == xhtmlNS && unwrapTags.contains(local)) {
                entry.outName = nil
            } else if ns == xhtmlNS {
                entry.outName = local
            } else if ns.isEmpty {
                entry.outName = qnameText
            } else {
                throw EntryFault("unexpected namespace \(ns) on <\(local)>")
            }

            if let outName = entry.outName, suppress == 0 || stack.isEmpty {
                let r = try finalAttributes(resolved, element: outName, rootID: rootID, linkPrefix: linkPrefix, stats: stats, links: &links)
                if r.name != outName { entry.outName = r.name }
                if let li = r.linkIndex, links[li].fallback.isEmpty {
                    entry.linkIndex = li  // the link text names the target
                    activeLinks.append((li, []))
                }
                out.append(0x3c)
                out += Array(r.name.utf8)
                for (n, v) in r.attrs { appendAttribute(name: n, value: v, parent: r.name, to: &out) }
                out.append(0x3e)
                entry.isVoid = voidTags.contains(r.name.lowercased())
                if r.voidAtStart {
                    entry.suppresses = true
                    suppress += 1
                }
                if let t = r.innerText {
                    entityEncode(Array(t.utf8)[...], into: &out)
                    for j in activeLinks.indices { activeLinks[j].text += Array(t.utf8) }
                }
            }
            stack.append(entry)
            if selfClose { try close(stack.removeLast()) }
        }

        func close(_ e: Open) throws {
            if let li = e.linkIndex, let at = activeLinks.lastIndex(where: { $0.index == li }) {
                let t = String(decoding: activeLinks[at].text, as: UTF8.self)
                links[li].fallback = pythonStrip(t)
                activeLinks.remove(at: at)
            }
            if let name = e.outName, !e.isVoid { out += Array("</\(name)>".utf8) }
            if e.suppresses { suppress -= 1 }
            for b in e.bindings.reversed() {
                if let p = b.previous { scope[b.prefix] = p } else { scope.removeValue(forKey: b.prefix) }
            }
            if stack.isEmpty { rootClosed = true }
        }

        while i < n {
            if bytes[i] != 0x3c {  // text
                var j = i
                while j < n, bytes[j] != 0x3c { j += 1 }
                guard !bytes[i..<j].containsSequence("]]>") else { throw EntryFault("Sequence ']]>' not allowed in content") }
                try text(try decodeText(bytes[i..<j]))
                i = j
                continue
            }
            if bytes.starts(at: i, with: "<!--") {
                guard let e = bytes.find("-->", from: i + 4) else { throw EntryFault("unterminated comment") }
                i = e + 3
            } else if bytes.starts(at: i, with: "<![CDATA[") {
                guard let e = bytes.find("]]>", from: i + 9) else { throw EntryFault("unterminated CDATA") }
                try text(normalizeNewlines(bytes[(i + 9)..<e]))
                i = e + 3
            } else if bytes.starts(at: i, with: "<?") {
                guard let e = bytes.find("?>", from: i + 2) else { throw EntryFault("unterminated PI") }
                i = e + 2
            } else if bytes.starts(at: i, with: "<!") {
                throw EntryFault("DOCTYPE/declarations are not supported")
            } else if bytes.starts(at: i, with: "</") {
                var j = i + 2
                while j < n, !isWS(bytes[j]), bytes[j] != 0x3e { j += 1 }
                let name = Array(bytes[(i + 2)..<j])
                while j < n, isWS(bytes[j]) { j += 1 }
                guard j < n, bytes[j] == 0x3e else { throw EntryFault("malformed end tag </\(String(decoding: name, as: UTF8.self))") }
                i = j + 1
                guard let top = stack.popLast(), top.qname == name else {
                    throw EntryFault("mismatched end tag </\(String(decoding: name, as: UTF8.self))>")
                }
                try close(top)
            } else {
                // start tag
                var j = i + 1
                while j < n, !isWS(bytes[j]), bytes[j] != 0x2f, bytes[j] != 0x3e { j += 1 }
                let qname = Array(bytes[(i + 1)..<j])
                guard !qname.isEmpty else { throw EntryFault("empty tag name") }
                var attrs: [(name: [UInt8], value: String)] = []
                var selfClose = false
                let needSpace = true
                while true {
                    let before = j
                    while j < n, isWS(bytes[j]) { j += 1 }
                    guard j < n else { throw EntryFault("unterminated start tag <\(String(decoding: qname, as: UTF8.self))") }
                    if bytes[j] == 0x3e { j += 1; break }
                    if bytes[j] == 0x2f, j + 1 < n, bytes[j + 1] == 0x3e { selfClose = true; j += 2; break }
                    guard j > before || !needSpace else { throw EntryFault("whitespace required between attributes") }
                    var k2 = j
                    while k2 < n, !isWS(bytes[k2]), bytes[k2] != 0x3d, bytes[k2] != 0x3e, bytes[k2] != 0x2f { k2 += 1 }
                    let aname = Array(bytes[j..<k2])
                    j = k2
                    while j < n, isWS(bytes[j]) { j += 1 }
                    guard j < n, bytes[j] == 0x3d else {
                        throw EntryFault("attribute \(String(decoding: aname, as: UTF8.self)) without value in <\(String(decoding: qname, as: UTF8.self))>")
                    }
                    j += 1
                    while j < n, isWS(bytes[j]) { j += 1 }
                    guard j < n, bytes[j] == 0x22 || bytes[j] == 0x27 else {
                        throw EntryFault("unquoted attribute \(String(decoding: aname, as: UTF8.self))")
                    }
                    let q = bytes[j]
                    j += 1
                    var e = j
                    while e < n, bytes[e] != q { e += 1 }
                    guard e < n else { throw EntryFault("unterminated attribute value") }
                    attrs.append((aname, try decodeAttribute(bytes[j..<e])))
                    j = e + 1
                }
                i = j
                guard !rootClosed else { throw EntryFault("content after the root element") }
                try open(qname: qname, attrs: attrs, selfClose: selfClose)
            }
        }
        guard stack.isEmpty, rootClosed else { throw EntryFault("unbalanced entry XML") }
        guard !rootID.isEmpty else { throw EntryFault("entry without id") }
        let key = cleanKey(rootTitle).isEmpty ? rootID : cleanKey(rootTitle)
        return ParsedArticle(id: rootID, key: key, html: out, address: address, links: links, placeholder: linkPrefix)
    }
}

// MARK: byte helpers

extension Array where Element == UInt8 {
    func starts(at i: Int, with s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= count else { return false }
        for k in 0..<u.count where self[i + k] != u[k] { return false }
        return true
    }
    func find(_ s: String, from: Int) -> Int? {
        let u = Array(s.utf8)
        guard count >= u.count, from <= count - u.count else { return nil }
        var i = from
        while i <= count - u.count {
            if self[i] == u[0], starts(at: i, with: s) { return i }
            i += 1
        }
        return nil
    }
}

extension ArraySlice where Element == UInt8 {
    func containsSequence(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard count >= u.count, let first = u.first else { return false }
        var i = startIndex
        while i <= endIndex - u.count {
            if self[i] == first, self[i..<(i + u.count)].elementsEqual(u) { return true }
            i += 1
        }
        return false
    }
}

func countOccurrences(of needle: [UInt8], in hay: [UInt8]) -> Int {
    guard !needle.isEmpty, hay.count >= needle.count else { return 0 }
    var n = 0
    var i = 0
    let last = hay.count - needle.count
    while i <= last {
        if hay[i] == needle[0], hay[i..<(i + needle.count)].elementsEqual(needle) {
            n += 1
            i += needle.count
        } else {
            i += 1
        }
    }
    return n
}

// MARK: character data

/// Every character must be a legal XML 1.0 Char; the UTF-8 is already known to be valid.
private func checkXMLCharacters(_ b: [UInt8]) throws {
    var i = 0
    while i < b.count {
        let c = b[i]
        if c < 0x20, c != 0x09, c != 0x0a, c != 0x0d {
            throw EntryFault("Invalid character: Char 0x\(String(c, radix: 16)) out of allowed range")
        }
        if c == 0xef, i + 2 < b.count, b[i + 1] == 0xbf, b[i + 2] == 0xbe || b[i + 2] == 0xbf {
            throw EntryFault("Invalid character U+FFFE/U+FFFF")
        }
        i += 1
    }
}

private func decodeReference(_ name: String) throws -> UInt32 {
    func digits(_ s: Substring, radix: Int) -> UInt32? {
        guard !s.isEmpty, s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || (radix == 16 && (($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x66)) }) else { return nil }
        return UInt32(s, radix: radix)
    }
    if name.hasPrefix("#x") {
        guard let v = digits(name.dropFirst(2), radix: 16) else { throw EntryFault("bad character reference &\(name);") }
        return v
    }
    if name.hasPrefix("#") {
        guard let v = digits(name.dropFirst(1), radix: 10) else { throw EntryFault("bad character reference &\(name);") }
        return v
    }
    switch name {
    case "amp": return 0x26
    case "lt": return 0x3c
    case "gt": return 0x3e
    case "quot": return 0x22
    case "apos": return 0x27
    default:
        if let v = htmlNamedEntities[name] { return v }
        throw EntryFault("unknown entity &\(name);")
    }
}

private func appendScalar(_ v: UInt32, to out: inout [UInt8]) throws {
    let legal = v == 0x09 || v == 0x0a || v == 0x0d || (0x20...0xd7ff).contains(v) || (0xe000...0xfffd).contains(v)
        || (0x10000...0x10ffff).contains(v)
    guard legal, let u = Unicode.Scalar(v) else {
        throw EntryFault("character reference to U+\(String(v, radix: 16)) is not allowed in XML")
    }
    out += Array(String(Character(u)).utf8)
}

/// XML end-of-line normalisation: CRLF and lone CR become LF.
private func normalizeNewlines(_ s: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == 0x0d {
            out.append(0x0a)
            i += 1
            if i < s.endIndex, s[i] == 0x0a { i += 1 }
        } else {
            out.append(s[i])
            i += 1
        }
    }
    return out
}

/// Text content: entity decoding with XML end-of-line normalisation.
private func decodeText(_ s: ArraySlice<UInt8>) throws -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == 0x26 {
            guard let semi = s[i...].firstIndex(of: 0x3b) else { throw EntryFault("unterminated entity") }
            let name = String(decoding: s[(i + 1)..<semi], as: UTF8.self)
            try appendScalar(try decodeReference(name), to: &out)
            i = semi + 1
        } else if c == 0x0d {
            out.append(0x0a)
            i += 1
            if i < s.endIndex, s[i] == 0x0a { i += 1 }
        } else {
            out.append(c)
            i += 1
        }
    }
    return out
}

/// Attribute values additionally turn literal tab/newline into spaces (before references are decoded).
private func decodeAttribute(_ s: ArraySlice<UInt8>) throws -> String {
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == 0x26 {
            guard let semi = s[i...].firstIndex(of: 0x3b) else { throw EntryFault("unterminated entity") }
            let name = String(decoding: s[(i + 1)..<semi], as: UTF8.self)
            try appendScalar(try decodeReference(name), to: &out)
            i = semi + 1
        } else if c == 0x0d {
            out.append(0x20)
            i += 1
            if i < s.endIndex, s[i] == 0x0a { i += 1 }
        } else if c == 0x0a || c == 0x09 {
            out.append(0x20)
            i += 1
        } else if c == 0x3c {
            throw EntryFault("'<' in attribute value")
        } else {
            out.append(c)
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: links

/// Fills in every link placeholder with its final `entry://` URL; links to nothing become plain `<span>`s.
func patchLinks(_ a: ParsedArticle, keyByID: [[UInt8]: String], keys: Set<[UInt8]>, stats: Stats) throws -> [UInt8] {
    let marker = Array("\"\(a.placeholder)".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(a.html.count + 64)
    var i = 0
    let h = a.html
    // '%' and '#' are the only characters with a meaning in the path of an entry:// URL
    func entryURL(_ target: String) -> String {
        "entry://" + target.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23")
    }
    var anchors: [Bool] = []  // open <a> elements, innermost last; true = this one became a <span>
    while i < h.count {
        if h[i] == 0x3c {
            if h.starts(at: i, with: "</a>") {
                let dead = anchors.popLast() ?? false
                out += Array((dead ? "</span>" : "</a>").utf8)
                i += 4
                continue
            }
            if h.starts(at: i, with: "<a"), i + 2 < h.count, h[i + 2] == 0x20 || h[i + 2] == 0x3e || h[i + 2] == 0x09 || h[i + 2] == 0x0a || h[i + 2] == 0x0d {
                anchors.append(false)
            }
        }
        guard h[i] == 0x22, h.starts(at: i, with: String(decoding: marker, as: UTF8.self)) else {
            out.append(h[i])
            i += 1
            continue
        }
        var j = i + marker.count
        var num = 0
        while j < h.count, h[j] >= 0x30, h[j] <= 0x39 {
            let (m, o1) = num.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int(h[j] - 0x30))
            guard !o1, !o2 else { throw EntryFault("\(a.id): corrupt link placeholder") }
            num = s
            j += 1
        }
        guard j < h.count, h[j] == 0x22, num < a.links.count else { throw EntryFault("\(a.id): corrupt link placeholder") }
        let l = a.links[num]
        var href: String
        if l.id.isEmpty {
            let target = cleanKey(l.fallback)
            if !keys.contains(Array(target.utf8)) {
                // Apple's own lookup returns nothing for these either, so the link is dead in the source:
                // keep the text, drop the link (<a ... href=...> becomes <span ...>).
                stats.bump("link: by search term, no such key (shown as plain text)")
                let hrefAttr = Array(" href=".utf8)
                guard out.count >= hrefAttr.count, out.suffix(hrefAttr.count).elementsEqual(hrefAttr) else {
                    throw EntryFault("\(a.id): cannot find the href of a dead link")
                }
                out.removeLast(hrefAttr.count)
                guard let at = out.lastIndex(of: 0x3c), out[at...].starts(with: Array("<a".utf8)) else {
                    throw EntryFault("\(a.id): cannot find the <a> of a dead link")
                }
                out.replaceSubrange(at..<(at + 2), with: Array("<span".utf8))
                guard !anchors.isEmpty else { throw EntryFault("\(a.id): dead link outside an <a>") }
                anchors[anchors.count - 1] = true
                i = j + 1
                continue
            }
            stats.bump("link: by search term")
            href = entryURL(target)
        } else if let target = keyByID[Array(l.id.utf8)] {
            href = entryURL(target)
            if !l.anchor.isEmpty, !target.utf8.contains(0x23) { href += "#" + l.anchor }
        } else {
            let target = cleanKey(l.fallback)
            if target.isEmpty {
                stats.bump("link: target id unknown and no keyword")
                href = "#"
            } else {
                stats.bump("link: id not in dictionary, fell back to keyword")
                href = entryURL(target)
            }
        }
        href = href.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        out.append(0x22)
        out += Array(href.utf8)
        out.append(0x22)
        i = j + 1
    }
    guard countOccurrences(of: marker, in: out) == 0 else {
        throw EntryFault("\(a.id): unpatched link placeholder")
    }
    return out
}
