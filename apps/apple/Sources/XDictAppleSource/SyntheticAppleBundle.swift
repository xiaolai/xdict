import Foundation
import zlib

/// **Tiny Apple dictionary bundles, written by a test or the E2E's Apple import instrument** (ADR-0011: no Apple content
/// in a fixture). The
/// layout is the one `XDictAppleImport` reads, as observed in Apple's bundles: a 0x40-byte header, the data window's
/// limit and its (0, -1) marker, then `Body.data`'s zlib sections of length-prefixed `<d:entry>` XML, and `KeyText.data`'s
/// records of UTF-16 lexemes pointing at them. Adopted from the dict2mdx spike's `SyntheticBundle.swift` (itself
/// mirroring its Python `synthetic_bundle.py`, which stays outside this repository).
public enum SyntheticAppleBundle {
    public static let dNS = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"

    public static func i32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: Int32(truncatingIfNeeded: v).littleEndian) { Array($0) } }
    public static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

    public struct CompressionFailed: Error {}

    /// A complete zlib stream of `data`, by the system's libz (the same stream format the converter inflates).
    public static func zlib(_ data: [UInt8]) throws -> [UInt8] {
        var size = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = out.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                compress2(dst.baseAddress, &size, src.baseAddress, uLong(src.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw CompressionFailed() }
        return Array(out.prefix(Int(size)))
    }

    public static func entry(_ id: String, _ title: String, _ body: String = "", extraAttrs: String = "") -> [UInt8] {
        Array("<d:entry xmlns:d=\"\(dNS)\" id=\"\(id)\" d:title=\"\(title)\" class=\"entry\"\(extraAttrs)>\(body)</d:entry>".utf8)
    }

    /// 0x40 zero bytes, LIMIT, the (0,-1) marker, padding up to 0x20, then the payload.
    public static func window(_ payload: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0, count: 0x40) + i32(0x20 + payload.count) + i32(0) + i32(-1)
            + [UInt8](repeating: 0, count: 0x20 - 12) + payload
    }

    /// One `Body.data` section holding every entry (several with `sections`, each entry list in its own section).
    public static func body(_ entries: [[UInt8]], sizeDelta: Int = 0, jumpDelta: Int = 0, compress: Bool = true) throws -> [UInt8] {
        try window(section(entries, sizeDelta: sizeDelta, jumpDelta: jumpDelta, compress: compress))
    }

    public static func body(sections: [[[UInt8]]]) throws -> [UInt8] {
        try window(sections.flatMap { try section($0, sizeDelta: 0, jumpDelta: 0, compress: true) })
    }

    static func section(_ entries: [[UInt8]], sizeDelta: Int, jumpDelta: Int, compress: Bool) throws -> [UInt8] {
        let buf = entries.flatMap { i32($0.count) + $0 }
        if compress {
            let z = try zlib(buf)
            let jump = 8 + z.count
            return i32(jump + jumpDelta) + i32(jump - 4 + sizeDelta) + i32(buf.count) + z
        }
        let jump = 4 + buf.count
        return i32(jump + jumpDelta) + i32(jump - 4 + sizeDelta) + buf
    }

    public static func lexeme(_ chunk: Int, _ keyword: String, first: Bool, flag: Int = 0, section: Int = 0x20) -> [UInt8] {
        var units: [UInt8] = []
        for u in keyword.utf16 { units += [UInt8(u & 0xff), UInt8(u >> 8)] }
        let inner = i32(chunk) + i32(section) + u16(flag) + u16(units.count) + units
        return (first ? u16(0) : []) + u16(inner.count) + inner
    }

    public static func record(_ lexemes: [[UInt8]]) -> [UInt8] {
        let body = u16(lexemes.count) + lexemes.flatMap { $0 }
        return i32(body.count) + body
    }

    public static func keytext(_ records: [[UInt8]]) throws -> [UInt8] {
        let buf = records.flatMap { $0 }
        let z = try zlib(buf)
        return window(i32(0) + i32(z.count + 4) + i32(buf.count) + z)
    }

    /// `version`: `IDXDictionaryVersion`, left out when nil. `keyTextIndex: false` leaves out the `KeyText.index`
    /// entry, as the system "Apple Dictionary" does.
    public static func plist(css: String? = "DefaultStyle.css", variable: [String] = ["DCSKeyword", "DCSHeadword"],
                             version: Int? = 3, keyTextIndex: Bool = true, bundleVersion: String? = nil,
                             displayName: String = "Test Dict", identifier: String? = nil,
                             languages: (index: String, description: String)? = nil) throws -> Data {
        var indexes: [[String: Any]] = [["IDXIndexPath": "EntryID.index"]]
        if keyTextIndex {
            indexes.append([
                "IDXIndexPath": "KeyText.index",
                "IDXIndexDataFields": [
                    "IDXFixedDataFields": [["IDXDataFieldName": "DCSPrivateFlag"]],
                    "IDXVariableDataFields": variable.map { ["IDXDataFieldName": $0] },
                    "IDXExternalDataFields": [["IDXDataSize": 8]],
                ],
                "TrieAuxiliaryDataOptions": ["HeapDataCompressionType": 3],
            ] as [String: Any])
        }
        indexes.append(["IDXIndexPath": "Body.data", "HeapDataCompressionType": 2] as [String: Any])
        var info: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "DCSDictionaryCopyright": "Test copyright",
            "IDXDictionaryIndexes": indexes,
        ]
        if let version { info["IDXDictionaryVersion"] = version }
        if let css { info["DCSDictionaryCSS"] = css }
        if let bundleVersion { info["CFBundleVersion"] = bundleVersion }
        if let identifier { info["CFBundleIdentifier"] = identifier }
        if let languages {
            info["DCSDictionaryLanguages"] = [["DCSDictionaryIndexLanguage": languages.index,
                                               "DCSDictionaryDescriptionLanguage": languages.description]]
        }
        return try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    }

    public struct Overrides {
        public var body: [UInt8]?
        public var keytext: [UInt8]?
        public var plist: Data?
        public var css = "body { color: black }"
        public var resources: [String: Data] = [:]
        public init() {}
    }

    /// One entry: its id, title, body HTML, and the extra search keys that redirect to it.
    public typealias Entry = (id: String, title: String, body: String, keys: [String])

    public static let defaultEntries: [Entry] = [
        ("e1", "alpha", "<p>first <a href=\"x-dictionary:r:e2\">beta</a></p>", ["alphas"]),
        ("e2", "beta", "<p>second</p>", []),
    ]

    /// Writes a bundle named `<name>.dictionary` under `root` and returns it.
    @discardableResult
    public static func make(in root: URL, name: String = "Test", entries: [Entry] = defaultEntries,
                            _ o: Overrides = Overrides()) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).dictionary")
        let res = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        let xmls = entries.map { entry($0.id, $0.title, $0.body) }
        var pos = 0
        var records: [[UInt8]] = []
        for (e, xml) in zip(entries, xmls) {
            records.append(record(([e.title] + e.keys).enumerated().map { lexeme(pos, $0.element, first: $0.offset == 0) }))
            pos += 4 + xml.count
        }
        try Data(o.body ?? body(xmls)).write(to: res.appendingPathComponent("Body.data"))
        try Data(o.keytext ?? keytext(records)).write(to: res.appendingPathComponent("KeyText.data"))
        try (o.plist ?? plist()).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data(o.css.utf8).write(to: res.appendingPathComponent("DefaultStyle.css"))
        for (rel, data) in o.resources {
            let url = res.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return bundle
    }

    /// A bundle whose `Body.data` holds one zlib section per list in `sections`, its keys addressing each entry by its
    /// section, so a test can stop a conversion between sections.
    @discardableResult
    public static func make(in root: URL, sections: [[Entry]], _ o: Overrides = Overrides()) throws -> URL {
        var payload: [UInt8] = []
        var records: [[UInt8]] = []
        var offset = 0x20
        for entries in sections {
            let xmls = entries.map { entry($0.id, $0.title, $0.body) }
            var pos = 0
            for (e, xml) in zip(entries, xmls) {
                records.append(record(([e.title] + e.keys).enumerated().map {
                    lexeme(pos, $0.element, first: $0.offset == 0, section: offset)
                }))
                pos += 4 + xml.count
            }
            let bytes = try section(xmls, sizeDelta: 0, jumpDelta: 0, compress: true)
            payload += bytes
            offset += bytes.count
        }
        var o = o
        o.body = window(payload)
        o.keytext = try keytext(records)
        return try make(in: root, entries: sections.flatMap { $0 }, o)
    }

    public static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xdict-apple-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
