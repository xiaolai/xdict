import Foundation

// Reader for Apple Dictionary Services bundles (*.dictionary), format 3 (`IDXDictionaryVersion` 3), written from the
// installed bundles as observed. Every structural assumption is checked and refused as a kind (`AppleImportError`);
// every file is read bounded (`readBounded`), every block inflated against one budget (`DecompressionBudget`).

struct Address: Hashable {
    let section: Int
    let chunk: Int
}

struct AppleArticle {
    let address: Address
    let xml: ArraySlice<UInt8>
}

struct Lexeme {
    let priority: Int
    let keyword: String
}

struct Properties {
    let bodyCompression: Int
    let bodyHasSections: Bool
    let keytextCompression: Int
    let hasFixedFlag: Bool
    let variableFields: [String]
    /// Where `DCSKeyword` is among `variableFields`.
    let keywordIndex: Int
    let cssName: String?
    let displayName: String
    let copyright: String
}

private let headerSize = 0x40

private struct Cursor {
    let bytes: [UInt8]
    let fault: (Int) -> Corruption

    func i32(_ p: Int) throws -> Int {
        guard p >= 0, p + 4 <= bytes.count else { throw AppleImportError.corrupt(fault(p)) }
        let v = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
        return Int(Int32(bitPattern: v))
    }

    func u16(_ p: Int, bound: Int) throws -> Int {
        guard p >= 0, p + 2 <= min(bound, bytes.count) else { throw AppleImportError.corrupt(fault(p)) }
        return Int(bytes[p]) | Int(bytes[p + 1]) << 8
    }
}

/// A bundle-supplied file name must be a plain relative path below Resources.
func checkResourceName(_ name: String) throws {
    guard !name.isEmpty, !name.contains("\0"), !name.contains("\\") else { throw AppleImportError.unsafeResourceName(name) }
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    guard !name.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
        throw AppleImportError.unsafeResourceName(name)
    }
}

/// `Contents/Resources`, refused if it (or an ancestor inside the bundle) resolves outside the bundle.
func resourcesRoot(bundle: URL) throws -> URL {
    let root = bundle.appendingPathComponent("Contents/Resources").resolvingSymlinksInPath()
    let base = bundle.resolvingSymlinksInPath()
    guard root.path.hasPrefix(base.path + "/") else { throw AppleImportError.symbolicLink("Contents/Resources") }
    return root
}

/// `Contents/Resources/<name>`, refusing anything that resolves (symlinks included) outside Resources.
func resourceURL(bundle: URL, name: String) throws -> URL {
    try checkResourceName(name)
    let root = try resourcesRoot(bundle: bundle)
    let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/") else { throw AppleImportError.symbolicLink(name) }
    return url
}

private func plistDict(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
    guard let v = parent[key] else { return [:] }
    guard let d = v as? [String: Any] else { throw AppleImportError.malformedInfoPlist(.field(key)) }
    return d
}

/// Names of a field list; positions matter, so nothing may be skipped or repeated.
private func fieldNames(_ fields: [String: Any], _ key: String) throws -> [String] {
    guard let v = fields[key] else { return [] }
    guard let entries = v as? [Any] else { throw AppleImportError.malformedInfoPlist(.field(key)) }
    var names: [String] = []
    for e in entries {
        guard let d = e as? [String: Any], let n = d["IDXDataFieldName"] as? String, !n.isEmpty else {
            throw AppleImportError.malformedInfoPlist(.field(key))
        }
        names.append(n)
    }
    // exact scalar identity (Swift String == would treat canonically equivalent names as equal)
    guard Set(names.map { Array($0.utf8) }).count == names.count else { throw AppleImportError.malformedInfoPlist(.field(key)) }
    return names
}

private func compressionType(_ d: [String: Any]) throws -> Int {
    guard let v = d["HeapDataCompressionType"] else { return 0 }
    guard let n = v as? Int else { throw AppleImportError.malformedInfoPlist(.field("HeapDataCompressionType")) }
    return n
}

func loadProperties(bundle: URL, bounds: Bounds = .production) throws -> Properties {
    let data: [UInt8]
    do {
        data = try readBounded(bundle.appendingPathComponent("Contents/Info.plist"), limit: bounds.infoPlistBytes, name: "Info.plist")
    } catch AppleImportError.unreadable(_, let code) where code == Int(ENOENT) {
        throw AppleImportError.malformedInfoPlist(.missing)
    }
    let parsed: Any
    do { parsed = try PropertyListSerialization.propertyList(from: Data(data), format: nil) } catch {
        throw AppleImportError.malformedInfoPlist(.unparsable)
    }
    guard let info = parsed as? [String: Any] else { throw AppleImportError.malformedInfoPlist(.notADictionary) }
    // ADR-0011 decision 11: format 3 is the only one these bundles are known in; anything else is refused by kind.
    // A `Bool` is not a version, though Foundation would bridge `true` to 1.
    let version = info["IDXDictionaryVersion"].flatMap { $0 is Bool ? nil : $0 as? Int }
    guard version == 3 else { throw AppleImportError.notVersion3(found: version) }
    guard let rawIndexes = info["IDXDictionaryIndexes"] as? [Any] else { throw AppleImportError.malformedInfoPlist(.indexes) }
    let indexes = try rawIndexes.map { e -> [String: Any] in
        guard let d = e as? [String: Any] else { throw AppleImportError.malformedInfoPlist(.indexes) }
        return d
    }
    func index(_ path: String) -> [String: Any]? { indexes.first { ($0["IDXIndexPath"] as? String) == path } }
    guard let keytext = index("KeyText.index") else { throw AppleImportError.noKeyTextIndex }
    guard let body = index("Body.data") else { throw AppleImportError.malformedInfoPlist(.indexes) }
    let fields = try plistDict(keytext, "IDXIndexDataFields")
    let fixed = try fieldNames(fields, "IDXFixedDataFields")
    let variable = try fieldNames(fields, "IDXVariableDataFields")
    guard let external = fields["IDXExternalDataFields"] as? [Any], external.count == 1,
          let external0 = external.first as? [String: Any] else {
        throw AppleImportError.malformedInfoPlist(.field("IDXExternalDataFields"))
    }

    let bodyCompression = try compressionType(body)
    let keytextCompression = try compressionType(try plistDict(keytext, "TrieAuxiliaryDataOptions"))
    guard bodyCompression == 0 || bodyCompression == 2 else { throw AppleImportError.unsupported(.bodyCompression(bodyCompression)) }
    guard keytextCompression == 0 || keytextCompression == 3 else {
        throw AppleImportError.unsupported(.keyTextCompression(keytextCompression))
    }
    guard fixed.isEmpty || fixed == ["DCSPrivateFlag"] else { throw AppleImportError.unsupported(.fixedFields(fixed)) }
    guard let keywordIndex = variable.firstIndex(of: "DCSKeyword") else { throw AppleImportError.unsupported(.noKeywordField) }

    var cssName: String?
    if let v = info["DCSDictionaryCSS"] {
        guard let n = v as? String else { throw AppleImportError.malformedInfoPlist(.field("DCSDictionaryCSS")) }
        try checkResourceName(n)
        cssName = n
    }
    return Properties(
        bodyCompression: bodyCompression,
        bodyHasSections: bodyCompression == 2 && (external0["IDXDataSize"] as? Int) == 8,
        keytextCompression: keytextCompression,
        hasFixedFlag: !fixed.isEmpty,
        variableFields: variable,
        keywordIndex: keywordIndex,
        cssName: cssName,
        displayName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "",
        copyright: info["DCSDictionaryCopyright"] as? String ?? ""
    )
}

private func dataWindow(_ c: Cursor) throws -> (start: Int, limit: Int) {
    guard c.bytes.count >= headerSize + 12 else { throw AppleImportError.corrupt(c.fault(0)) }
    let limit = try c.i32(headerSize)
    let marker = (try c.i32(headerSize + 4), try c.i32(headerSize + 8))
    let start = (marker.0 == 0 && marker.1 == -1) ? 0x20 : 0x04
    guard limit > start, headerSize + limit <= c.bytes.count else { throw AppleImportError.corrupt(c.fault(headerSize)) }
    return (start, limit)
}

func readBody(bundle: URL, props: Properties, bounds: Bounds = .production,
              budget: DecompressionBudget = DecompressionBudget(limit: Bounds.production.decompressedBytes),
              steps: Steps? = nil) throws -> [AppleArticle] {
    let raw = try readBounded((try resourcesRoot(bundle: bundle)).appendingPathComponent("Body.data"),
                              limit: bounds.sourceFileBytes, name: "Body.data")
    let c = Cursor(bytes: raw) { .body(offset: $0) }
    let (start, limit) = try dataWindow(c)
    var out: [AppleArticle] = []
    var section = start
    let windowEnd = headerSize + limit
    try raw.withUnsafeBufferPointer { buf in
        while section < limit {
            // Before each section is inflated: where a cancellation stops a conversion (ADR-0011 decision 5).
            try steps?.reading(done: section - start, total: limit - start)
            let pos = headerSize + section
            guard pos + 8 <= raw.count else { throw AppleImportError.corrupt(.body(offset: pos)) }
            let jump = try c.i32(pos)
            let size = try c.i32(pos + 4)
            let end = pos + 4 + jump
            guard jump > 8, end <= windowEnd, size == jump - 4 else { throw AppleImportError.corrupt(.body(offset: pos)) }
            let buffer: [UInt8]
            if props.bodyCompression != 0 {
                let rawLen = try c.i32(pos + 8)
                buffer = try zlibInflate(buf, from: pos + 12, to: end, expected: rawLen, budget: budget, corrupt: .body(offset: pos))
            } else {
                buffer = Array(raw[(pos + 8)..<end])
            }
            var p = 0
            let bc = Cursor(bytes: buffer) { _ in .body(offset: pos) }
            while p < buffer.count {
                let n = try bc.i32(p)
                guard n > 0, p + 4 + n <= buffer.count else { throw AppleImportError.corrupt(.body(offset: pos)) }
                let xml = buffer[(p + 4)..<(p + 4 + n)]
                guard xml.starts(with: Array("<d:entry".utf8)) else { throw AppleImportError.corrupt(.entry(section: section, chunk: p)) }
                out.append(AppleArticle(address: Address(section: section, chunk: p), xml: xml))
                p += 4 + n
            }
            section += jump + 4
        }
    }
    guard section == limit else { throw AppleImportError.corrupt(.body(offset: headerSize + section)) }
    return out
}

func readKeyText(bundle: URL, props: Properties, bounds: Bounds = .production,
                 budget: DecompressionBudget = DecompressionBudget(limit: Bounds.production.decompressedBytes)) throws -> [Address: [Lexeme]] {
    let raw = try readBounded((try resourcesRoot(bundle: bundle)).appendingPathComponent("KeyText.data"),
                              limit: bounds.sourceFileBytes, name: "KeyText.data")
    let c = Cursor(bytes: raw) { .keyText(offset: $0) }
    let (start, limit) = try dataWindow(c)

    var buffer: [UInt8]
    var offset: Int
    var end: Int
    if props.keytextCompression != 0 {
        let windowEnd = headerSize + limit
        var pos = headerSize + start
        guard pos + 4 <= windowEnd else { throw AppleImportError.corrupt(.keyText(offset: pos)) }
        let sectionLen = try c.i32(pos)
        guard sectionLen >= 0 else { throw AppleImportError.corrupt(.keyText(offset: pos)) }
        pos += 4
        var nextPos = pos
        buffer = []
        try raw.withUnsafeBufferPointer { buf in
            while pos < windowEnd {
                guard pos + 8 <= windowEnd else { throw AppleImportError.corrupt(.keyText(offset: pos)) }
                let comp = try c.i32(pos)
                let rawLen = try c.i32(pos + 4)
                // Apple's files keep stale bytes after the terminator (megabytes in Croatian, Korean); ignored.
                if comp == 0 && rawLen == 0 { break }
                guard comp >= 4, pos + 8 + comp - 4 <= windowEnd else { throw AppleImportError.corrupt(.keyText(offset: pos)) }
                buffer += try zlibInflate(buf, from: pos + 8, to: pos + 8 + comp - 4, expected: rawLen, budget: budget,
                                          corrupt: .keyText(offset: pos))
                nextPos += max(sectionLen, comp + 4)
                guard nextPos <= windowEnd, !raw[(pos + 8 + comp - 4)..<nextPos].contains(where: { $0 != 0 }) else {
                    throw AppleImportError.corrupt(.keyText(offset: pos))
                }
                pos = nextPos
            }
        }
        offset = 0
        end = buffer.count
    } else {
        buffer = Array(raw[headerSize...])
        offset = start
        end = limit
    }

    // Offsets into the inflated text name no place in the file; a fault there is reported at the window's start.
    let b = Cursor(bytes: buffer) { _ in .keyText(offset: headerSize + start) }
    var out: [Address: [Lexeme]] = [:]
    while offset < end {
        offset = try readKeyRecord(b, at: offset, end: end, props: props, into: &out)
    }
    return out
}

/// One KeyText record: `[jump][nforms]` followed by its lexemes. Every read stays inside the record;
/// returns the offset of the next record.
private func readKeyRecord(_ b: Cursor, at offset: Int, end: Int, props: Properties, into out: inout [Address: [Lexeme]]) throws -> Int {
    let corrupt = AppleImportError.corrupt(b.fault(offset))
    let nvar = props.variableFields.count
    let jump = try b.i32(offset)
    let recordEnd = offset + 4 + jump
    guard jump > 0, recordEnd <= end else { throw corrupt }
    var p = offset + 4
    if props.keytextCompression == 0 { p += 4 }
    let nforms = try b.u16(p, bound: recordEnd)
    p += 2
    var nextLexeme = 0
    for _ in 0..<nforms {
        p += 2
        if nextLexeme != 0 { p = nextLexeme }
        var small = 0
        while small == 0 {
            small = try b.u16(p, bound: recordEnd)
            p += 2
        }
        nextLexeme = p + small
        guard nextLexeme <= recordEnd, p + (props.bodyHasSections ? 8 : 4) <= nextLexeme else { throw corrupt }
        let chunk: Int, section: Int
        if props.bodyHasSections {
            chunk = try b.i32(p)
            section = try b.i32(p + 4)
            p += 8
        } else {
            section = try b.i32(p)
            chunk = 0
            p += 4
        }
        var priority = 0
        if props.hasFixedFlag {
            guard p + 2 <= nextLexeme else { throw corrupt }
            var flag = try b.u16(p, bound: nextLexeme)
            p += 2
            guard flag < 0x40 else { throw corrupt }
            if flag >= 0x20 { flag -= 0x20 }
            priority = (flag - flag % 2) / 2
        }
        var values: [String] = []
        while p < nextLexeme {
            let n = try b.u16(p, bound: nextLexeme)
            p += 2
            if n == 0 {
                values.append("")
                continue
            }
            guard p + n <= nextLexeme, n % 2 == 0, let value = decodeUTF16LE(b.bytes[p..<(p + n)]) else { throw corrupt }
            values.append(value)
            p += n
        }
        guard p == nextLexeme, values.count <= nvar else { throw corrupt }
        let kw = props.keywordIndex < values.count ? values[props.keywordIndex] : ""
        out[Address(section: section, chunk: chunk), default: []].append(Lexeme(priority: priority, keyword: kw))
    }
    guard p == recordEnd else { throw corrupt }
    return recordEnd
}

/// Strict UTF-16LE decoding: an odd length or unpaired surrogate is nil, never U+FFFD.
func decodeUTF16LE(_ bytes: ArraySlice<UInt8>) -> String? {
    guard bytes.count % 2 == 0 else { return nil }
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var i = bytes.startIndex
    while i < bytes.endIndex {
        units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
        i += 2
    }
    return String(validating: units, as: UTF16.self)
}
