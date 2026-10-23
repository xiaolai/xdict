import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport
import XDictAppleSource

/// The MDD key of a UTF-16LE key as the reader returns it.
func utf16Key(_ k: [UInt8]) -> String {
    String(decoding: stride(from: 0, to: k.count - 1, by: 2).map { UInt16(k[$0]) | UInt16(k[$0 + 1]) << 8 }, as: UTF16.self)
}

func readRecords(_ url: URL, isMDD: Bool) throws -> [([UInt8], [UInt8])] {
    var out: [([UInt8], [UInt8])] = []
    try readMDict(at: url, isMDD: isMDD) { _, k, v in out.append((k, v)) }
    return out
}

@Suite struct ConvertTests {
    func quiet() -> Report { Report(echo: false) }

    @Test func endToEnd() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.resources = ["img/a.png": Data([0x89, 0x50])]
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        let out = root.appendingPathComponent("out")
        try convert(snapshot: bundle, into: out, name: "T", report: quiet())
        let mdx = try readRecords(out.appendingPathComponent("T.mdx"), isMDD: false)
        #expect(Set(mdx.map { String(decoding: $0.0, as: UTF8.self) }) == ["alpha", "beta", "alphas"])
        let alpha = try #require(mdx.first { String(decoding: $0.0, as: UTF8.self) == "alpha" })
        #expect(String(decoding: alpha.1, as: UTF8.self).contains("href=\"entry://beta\""))
        #expect(try readRecords(out.appendingPathComponent("T.mdd"), isMDD: true).count == 2)
        // ADR-0011 decision 2: the output is an `.mdx` + `.mdd` pair, and nothing else is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["T.mdd", "T.mdx"])
    }

    /// Keeping Apple's pronunciation markers changes the bytes written (ADR-0013 decision 1), so it is revision 2.
    @Test func keepingPronunciationMarkersIsRevisionTwo() {
        #expect(AppleImport.converterRevision == 2)
    }

    @Test func resourcePathsSurviveASymlinkedTempDirectory() throws {
        // /var -> /private/var made relative-path arithmetic wrong once: keys came out as "\sources\..."
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.resources = ["x/y.bin": Data([1])]
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        let out = root.appendingPathComponent("o")
        try convert(snapshot: bundle, into: out, name: "T", report: quiet())
        let keys = try readRecords(out.appendingPathComponent("T.mdd"), isMDD: true).map { utf16Key($0.0) }
        #expect(Set(keys) == ["\\x\\y.bin", "\\apple.css"])
    }

    @Test func unsafeNamesAreRefused() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        for name in ["../escape", "/abs", "a/b", "", ".."] {
            #expect(throws: (any Error).self, "\(name)") {
                try convert(snapshot: bundle, into: root.appendingPathComponent("o"), name: name, report: quiet())
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.mdx").path))
    }

    @Test func symlinkedResourceIsRefused() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let secret = root.appendingPathComponent("secret.txt")
        try Data("s".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/Resources/leak.txt"), withDestinationURL: secret)
        #expect(throws: (any Error).self) { try convert(snapshot: bundle, into: root.appendingPathComponent("o"), name: "T", report: quiet()) }
    }

    @Test func extraStylesheetsAreKeptAndFbmIsFolded() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.resources = ["extra.css": Data("b{}".utf8), "fbm.css": Data("i{}".utf8)]
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        let out = root.appendingPathComponent("o")
        try convert(snapshot: bundle, into: out, name: "T", report: quiet())
        let records = try readRecords(out.appendingPathComponent("T.mdd"), isMDD: true)
        let keys = records.map { utf16Key($0.0) }
        #expect(keys.contains("\\extra.css"))
        #expect(!keys.contains("\\fbm.css"))
        let css = try #require(records.first { utf16Key($0.0) == "\\apple.css" })
        #expect(String(decoding: css.1, as: UTF8.self).contains("i{}"))
    }

    // MARK: - ADR-0011 decision 4: Apple's format 3 only

    @Test func aVersion4BundleIsRefused() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: 4)
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        #expect(throws: (any Error).self) { try convert(snapshot: bundle, into: root.appendingPathComponent("o"), name: "T", report: quiet()) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("o/T.mdx").path))
    }

    @Test func aBundleWithoutAVersionIsRefused() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: nil)
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        #expect(throws: (any Error).self) { try convert(snapshot: bundle, into: root.appendingPathComponent("o"), name: "T", report: quiet()) }
    }

    // MARK: - ADR-0011 decision 6: deterministic output

    func convertBytes(_ bundle: URL, root: URL, name: String) throws -> (mdx: Data, mdd: Data) {
        let out = root.appendingPathComponent("out-\(name)")
        try convert(snapshot: bundle, into: out, name: name, report: quiet())
        return (try Data(contentsOf: out.appendingPathComponent("\(name).mdx")),
                try Data(contentsOf: out.appendingPathComponent("\(name).mdd")))
    }

    @Test func theOutputNameChangesNoByte() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.resources = ["img/a.png": Data([0x89, 0x50, 0x4e, 0x47])]
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        let first = try convertBytes(bundle, root: root, name: "First")
        let second = try convertBytes(bundle, root: root, name: "Another name")
        #expect(first.mdx == second.mdx)
        #expect(first.mdd == second.mdd)
    }

    /// The header says nothing a clock wrote: no `CreationDate` (ADR-0011 decision 6).
    @Test func noHeaderNamesACreationDate() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let bytes = try convertBytes(bundle, root: root, name: "T")
        for file in [bytes.mdx, bytes.mdd] {
            let header = try headerText(of: [UInt8](file))
            #expect(!header.contains("CreationDate"), "\(header)")
            #expect(header.hasPrefix("<Dictionary ") || header.hasPrefix("<Library_Data "), "\(header)")
        }
    }

    /// Another time zone, and another default calendar's day, change no byte.
    @Test func anotherTimeZoneChangesNoByte() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let east = try convertBytes(bundle, root: root, name: "East")
        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Pago_Pago"))
        let west = try convertBytes(bundle, root: root, name: "West")
        #expect(east.mdx == west.mdx)
        #expect(east.mdd == west.mdd)
    }

    /// **No clock is read**: the converter's sources name no date, calendar, time zone or process clock, so no
    /// injected one could change a byte.
    @Test func theConverterReadsNoClock() throws {
        let sources = try SourceScan.files(under: Manifest.package.appending(path: "Sources/XDictAppleImport"))
        #expect(!sources.isEmpty)
        let clocks = ["Date(", "Date.now", "Calendar", "TimeZone", "ProcessInfo", "clock_gettime", "time(nil)", "mach_absolute_time"]
        let found = sources.flatMap { file, text in
            clocks.filter { SourceScan.codeOnly(text).contains($0) }.map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(found == [])
    }

    // MARK: - No trap anywhere (hardening item 2)

    @Test func theConverterHasNoTrap() throws {
        let sources = try SourceScan.files(under: Manifest.package.appending(path: "Sources/XDictAppleImport"))
        #expect(!sources.isEmpty)
        #expect(Self.traps(sources.map { ($0.file.lastPathComponent, $0.text) }) == [])
    }

    /// The control: each spelling of a trap is named; `!=`, a prefix `!`, and one in a comment or string are not.
    @Test func aTrapIsNamed() {
        let planted = "let a = b!\nlet c = try! d()\nfatalError(\"x\")\nlet e = f as! G\nprecondition(h)\n"
        let innocent = "let a = b != c\nlet d = !e\n// x!\nlet s = \"y! try! fatalError\"\n"
        #expect(Self.traps([("Planted.swift", planted), ("Innocent.swift", innocent)]) == [
            "Planted.swift: as!", "Planted.swift: fatalError", "Planted.swift: force unwrap",
            "Planted.swift: precondition", "Planted.swift: try!",
        ])
    }

    static func traps(_ files: [(String, String)]) -> [String] {
        files.flatMap { name, text -> [String] in
            let code = SourceScan.codeOnly(text)
            var found: [String] = []
            if code.contains("try!") { found.append("try!") }
            if code.contains("as!") { found.append("as!") }
            if code.contains("fatalError(") { found.append("fatalError") }
            if code.contains("precondition(") || code.contains("preconditionFailure(") { found.append("precondition") }
            let unwrap = /[\w\)\]]!(?![=])/
            if code.replacingOccurrences(of: "try!", with: "").replacingOccurrences(of: "as!", with: "")
                .contains(unwrap) { found.append("force unwrap") }
            return found.sorted().map { "\(name): \($0)" }
        }
    }

    // MARK: - What the core's reader cannot tell apart

    /// **An empty resource is not packed**: the core's reader ends a record at the next larger start
    /// (`xdict-mdx/src/index.rs`, `record_ends`), so a zero-length record shares its start with the next one and would
    /// read as that one's bytes.
    @Test func anEmptyResourceIsLeftOut() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = SyntheticAppleBundle.Overrides()
        o.resources = ["a/empty.bin": Data(), "b/full.bin": Data([1, 2, 3])]
        let bundle = try SyntheticAppleBundle.make(in: root, o)
        let out = root.appendingPathComponent("o")
        try convert(snapshot: bundle, into: out, name: "T", report: quiet())
        let records = try readRecords(out.appendingPathComponent("T.mdd"), isMDD: true)
        #expect(!records.map { utf16Key($0.0) }.contains("\\a\\empty.bin"))
        #expect(records.allSatisfy { !$0.1.isEmpty })
    }
}

/// The header text of an MDict file: a big-endian length, then UTF-16LE.
func headerText(of bytes: [UInt8]) throws -> String {
    try #require(bytes.count >= 4)
    let n = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    try #require(bytes.count >= 4 + n)
    return utf16Key(Array(bytes[4..<(4 + n)]))
}
