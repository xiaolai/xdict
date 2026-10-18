import Foundation

// MDX / MDD writer, format 2.0, zlib blocks, unencrypted. Written from the MIT-licensed writemdict format description
// (block layout, checksums, header fields), as `core/xdict-mdx` is. Records are written in the core reader's order
// (`KeyOrder`). What it writes is checked by the core's reader, not by a reader of its own (ADR-0011 decision 3).

struct MDictItem {
    enum Payload {
        case bytes([UInt8])  // MDX: the HTML text without terminator
        case file(URL, name: String)  // MDD: read, bounded, only when its record block is built
    }

    let key: String
    let payload: Payload

    init(key: String, data: [UInt8]) {
        self.key = key
        payload = .bytes(data)
    }

    init(key: String, file: URL, name: String) {
        self.key = key
        payload = .file(file, name: name)
    }

    func load(limit: Int) throws -> [UInt8] {
        switch payload {
        case .bytes(let b): return b
        case .file(let u, let name): return try readBounded(u, limit: limit, name: name)
        }
    }
}

/// Largest key (in encoded bytes for MDX, UTF-16 units for MDD) the 16-bit index lengths can describe.
let maxKeyLength = 0xFFFF

/// A key must survive the NUL-terminated key table unchanged.
func validateKey(_ key: String, isMDD: Bool) throws {
    guard !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value == 0 }) else {
        throw AppleImportError.corrupt(isMDD ? .resourceKey(key) : .recordKey(key))
    }
    let size = isMDD ? key.utf16.count : key.utf8.count
    guard size <= maxKeyLength else { throw AppleImportError.boundExceeded(.keyLength(units: size)) }
}

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
private func be64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((UInt64(v) >> UInt64(56 - 8 * $0)) & 0xff) } }
private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

/// A compressed block: type 2 (zlib), Adler-32 of the plain data, the zlib stream.
private func block(_ plain: [UInt8]) throws -> [UInt8] {
    [2, 0, 0, 0] + be32(adler32(plain)) + (try zlibCompress(plain))
}

private func escapeAttribute(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#x27;")
}

/// **The header names no date** (ADR-0011 decision 6): the same snapshot writes the same bytes on any day, in any time
/// zone. `CreationDate` is optional in the format, and the core's reader does not read it (`xdict-mdx/src/header.rs`).
private func header(isMDD: Bool, title: String, description: String) -> [UInt8] {
    let text: String
    if isMDD {
        text = "<Library_Data GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"No\" "
            + "Encoding=\"\" Format=\"\" KeyCaseSensitive=\"No\" Stripkey=\"No\" "
            + "Description=\"\(escapeAttribute(description))\" Title=\"\(escapeAttribute(title))\" RegisterBy=\"\" />\r\n\0"
    } else {
        text = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"No\" "
            + "Encoding=\"UTF-8\" Format=\"Html\" Stripkey=\"Yes\" Compact=\"Yes\" Compat=\"Yes\" "
            + "KeyCaseSensitive=\"No\" Description=\"\(escapeAttribute(description))\" Title=\"\(escapeAttribute(title))\" "
            + "DataSourceFormat=\"106\" StyleSheet=\"\" Left2Right=\"Yes\" RegisterBy=\"\" />\r\n\0"
    }
    var units: [UInt8] = []
    for u in text.utf16 { units += [UInt8(u & 0xff), UInt8(u >> 8)] }
    var out = be32(UInt32(units.count)) + units
    let a = adler32(units)  // little-endian for the header
    out += [UInt8(a & 0xff), UInt8((a >> 8) & 0xff), UInt8((a >> 16) & 0xff), UInt8(a >> 24)]
    return out
}

/// Writes `items` as a new MDX (or MDD) file at `url` and returns the order the records were written in. `fileLimit`
/// bounds each resource read; `meter` the bytes written, across files.
@discardableResult
func writeMDict(items: [MDictItem], isMDD: Bool, title: String, description: String, to url: URL,
                fileLimit: Int = Bounds.production.sourceFileBytes,
                meter: OutputMeter = OutputMeter(limit: Bounds.production.outputBytes)) throws -> [Int] {
    guard !items.isEmpty else { throw AppleImportError.noEntries }
    for it in items { try validateKey(it.key, isMDD: isMDD) }
    let order = KeyOrder.order(items.map(\.key), isMDD: isMDD)

    // record side first: offsets are cumulative over the sorted order
    struct Row {
        let keyBytes: [UInt8]
        let keyUnits: Int
        let offset: Int
    }
    let terminator: [UInt8] = isMDD ? [] : [0x0d, 0x0a, 0x00]
    var rows: [Row] = []
    rows.reserveCapacity(items.count)
    var recordBlocks: [[UInt8]] = []
    var recordIndex: [UInt8] = []
    var plain: [UInt8] = []
    var offset = 0
    let recordLimit = 65536
    func flushRecords() throws {
        guard !plain.isEmpty else { return }
        let b = try block(plain)
        recordIndex += be64(b.count) + be64(plain.count)
        recordBlocks.append(b)
        plain.removeAll(keepingCapacity: true)
    }
    for idx in order {
        let it = items[idx]
        let keyBytes: [UInt8]
        let units: Int
        if isMDD {
            var k: [UInt8] = []
            for u in it.key.utf16 { k += [UInt8(u & 0xff), UInt8(u >> 8)] }
            keyBytes = k
            units = k.count / 2
        } else {
            keyBytes = Array(it.key.utf8)
            units = keyBytes.count
        }
        rows.append(Row(keyBytes: keyBytes, keyUnits: units, offset: offset))
        let data = try it.load(limit: fileLimit)
        // The core's reader ends a record at the next larger start (`xdict-mdx/src/index.rs`, `record_ends`): an empty
        // one shares its start with the next and would read as that one's bytes. An MDX record has its terminator.
        guard !data.isEmpty || !terminator.isEmpty else { throw AppleImportError.corrupt(.emptyRecord(it.key)) }
        let recLen = data.count + terminator.count
        if !plain.isEmpty, plain.count + recLen > recordLimit { try flushRecords() }
        plain += data
        plain += terminator
        offset += recLen
    }
    try flushRecords()

    // key side
    let nul: [UInt8] = isMDD ? [0, 0] : [0]
    let keyLimit = 32768
    var keyBlocks: [[UInt8]] = []
    var keyIndexPlain: [UInt8] = []
    var cur: [UInt8] = []
    var curCount = 0
    var first: Row?
    var last: Row?
    func flushKeys() throws {
        guard curCount > 0, let f = first, let l = last else { return }
        let b = try block(cur)
        keyIndexPlain += be64(curCount) + be16(f.keyUnits) + f.keyBytes + nul + be16(l.keyUnits) + l.keyBytes + nul
        keyIndexPlain += be64(b.count) + be64(cur.count)
        keyBlocks.append(b)
        cur.removeAll(keepingCapacity: true)
        curCount = 0
        first = nil
        last = nil
    }
    for r in rows {
        let entryLen = 8 + r.keyBytes.count + nul.count
        if curCount > 0, cur.count + entryLen > keyLimit { try flushKeys() }
        cur += be64(r.offset) + r.keyBytes + nul
        if first == nil { first = r }
        last = r
        curCount += 1
    }
    try flushKeys()

    let keyIndexBlock = try block(keyIndexPlain)
    let keyBlocksSize = keyBlocks.reduce(0) { $0 + $1.count }
    let preamble = be64(keyBlocks.count) + be64(items.count) + be64(keyIndexPlain.count) + be64(keyIndexBlock.count) + be64(keyBlocksSize)

    // stream everything out; no second copy of the file is assembled in memory
    let file = try OutputFile(url, meter: meter)
    try file.put(header(isMDD: isMDD, title: title, description: description))
    try file.put(preamble + be32(adler32(preamble)))
    try file.put(keyIndexBlock)
    for b in keyBlocks { try file.put(b) }
    try file.put(be64(recordBlocks.count) + be64(items.count) + be64(recordIndex.count) + be64(recordBlocks.reduce(0) { $0 + $1.count }))
    try file.put(recordIndex)
    for b in recordBlocks { try file.put(b) }
    try file.finish()
    return order
}
