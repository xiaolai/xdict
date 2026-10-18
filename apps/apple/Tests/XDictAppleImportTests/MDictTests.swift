import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport

@Suite struct MDictTests {
    func roundTrip(_ items: [MDictItem], isMDD: Bool) throws -> [(String, [UInt8])] {
        let dir = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(isMDD ? "t.mdd" : "t.mdx")
        let order = try writeMDict(items: items, isMDD: isMDD, title: "T", description: "D", to: url)
        var got: [(String, [UInt8])] = []
        try readMDict(at: url, isMDD: isMDD) { i, key, value in
            let text = isMDD
                ? String(decoding: stride(from: 0, to: key.count, by: 2).map { UInt16(key[$0]) | UInt16(key[$0 + 1]) << 8 }, as: UTF16.self)
                : String(decoding: key, as: UTF8.self)
            #expect(text == items[order[i]].key)
            got.append((text, value))
        }
        return got
    }

    @Test func mdxRoundTripAndOrder() throws {
        let items = ["b", "A", "a-c", "ac", "Ä", "B"].map { MDictItem(key: $0, data: Array("v-\($0)".utf8)) }
        let got = try roundTrip(items, isMDD: false)
        #expect(got.count == 6)
        for (k, v) in got { #expect(v == Array("v-\(k)".utf8)) }
        // lower-cased, punctuation ignored: "a-c" and "ac" tie and keep input order
        #expect(got.map(\.0) == ["A", "a-c", "ac", "b", "B", "Ä"])
    }

    /// **The order is the core reader's tier-1 folding** (`xdict-mdx/src/text.rs`, `fold`; ADR-0011 decision 12): full
    /// case folding, then only letters and digits (Unicode's, not ASCII's), ties in input order. Each pair below is
    /// ordered differently by the rule this replaced (lower-casing less ASCII punctuation): a backslash and an en dash
    /// are not letters, and ß folds to "ss".
    @Test func mdxOrderIsTheCoreReadersFolding() throws {
        let items = ["a\\c", "ab", "ßa", "st", "a\u{2013}b", "aa"].map { MDictItem(key: $0, data: Array($0.utf8)) }
        let got = try roundTrip(items, isMDD: false)
        #expect(got.map(\.0) == ["aa", "ab", "a\u{2013}b", "a\\c", "ßa", "st"])
    }

    /// Full case folding has no final-sigma rule: Σ, σ and ς fold alike, so these tie and keep their input order.
    @Test func sigmasFoldAlike() throws {
        let items = ["σοσ", "σος", "ΣΟΣ", "ΑΣ b", "Σ"].map { MDictItem(key: $0, data: Array($0.utf8)) }
        let got = try roundTrip(items, isMDD: false)
        #expect(got.map(\.0) == ["ΑΣ b", "Σ", "σοσ", "σος", "ΣΟΣ"])
    }

    /// An MDD's paths are folded but never stripped (`xdict-mdx/src/lib.rs`, `Kind::Mdd`): punctuation counts.
    @Test func mddOrderKeepsPunctuation() throws {
        let items = ["\\b.png", "\\A-c.png", "\\ac.png"].map { MDictItem(key: $0, data: [1]) }
        let got = try roundTrip(items, isMDD: true)
        #expect(got.map(\.0) == ["\\A-c.png", "\\ac.png", "\\b.png"])
    }

    /// Corrupt 64-bit counts must end in a clean error, never in an arithmetic trap.
    @Test func hugeCountsInTheKeySectionAreRejected() throws {
        let dir = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.mdx")
        _ = try writeMDict(items: [MDictItem(key: "a", data: [1])], isMDD: false, title: "T", description: "D", to: url)
        let good = [UInt8](try Data(contentsOf: url))
        let headerLen = Int(good[0]) << 24 | Int(good[1]) << 16 | Int(good[2]) << 8 | Int(good[3])
        let head = 4 + headerLen + 4  // start of the 40-byte key section header
        for (field, value) in [(24, UInt8(0x7f)), (24, 0xff), (0, 0xff), (8, 0xff), (32, 0x7f)] {
            var bad = good
            bad[head + field] = value
            for k in 1..<8 { bad[head + field + k] = 0xff }
            let sum = adler32(Array(bad[head..<(head + 40)]))
            for k in 0..<4 { bad[head + 40 + k] = UInt8((sum >> UInt32(24 - 8 * k)) & 0xff) }
            let badURL = dir.appendingPathComponent("bad.mdx")
            try Data(bad).write(to: badURL)
            #expect(throws: (any Error).self) { try readMDict(at: badURL, isMDD: false) { _, _, _ in } }
        }
    }

    @Test func mddRoundTripWithLargeAndEmptyRecords() throws {
        let big = [UInt8](repeating: 9, count: 300_000)
        let got = try roundTrip([
            MDictItem(key: "\\img\\a.png", data: big), MDictItem(key: "\\b.css", data: [0]), MDictItem(key: "\\中文.txt", data: [1, 2, 3]),
        ], isMDD: true)
        #expect(got.count == 3)
        #expect(got.first { $0.0 == "\\img\\a.png" }?.1 == big)
    }

    @Test func manyRecordsSpanBlocks() throws {
        let items = (0..<20_000).map { MDictItem(key: "key\($0)", data: Array(String(repeating: "x", count: $0 % 50).utf8)) }
        #expect(try roundTrip(items, isMDD: false).count == 20_000)
    }

    @Test func unrepresentableInputIsAnErrorNotACrash() throws {
        let dir = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.mdx")
        func write(_ items: [MDictItem], mdd: Bool = false) throws { try writeMDict(items: items, isMDD: mdd, title: "", description: "", to: url) }
        #expect(throws: AppleImportError.self) { try write([]) }
        #expect(throws: AppleImportError.self) { try write([MDictItem(key: "a\0b", data: [1])]) }
        #expect(throws: AppleImportError.self) { try write([MDictItem(key: String(repeating: "k", count: 70_000), data: [1])]) }
        #expect(throws: AppleImportError.self) { try write([MDictItem(key: "", data: [1])]) }
        #expect(throws: AppleImportError.self) { try write([MDictItem(key: "\\a\0", data: [1])], mdd: true) }
        // The core's reader ends a record at the next larger start (`xdict-mdx/src/index.rs`, `record_ends`), so an
        // empty one would read as its neighbour's bytes.
        #expect(throws: AppleImportError.self) { try write([MDictItem(key: "\\a", data: []), MDictItem(key: "\\b", data: [1])], mdd: true) }
    }

    @Test func readerRejectsCorruptFiles() throws {
        let dir = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.mdx")
        try writeMDict(items: [MDictItem(key: "a", data: [1, 2, 3])], isMDD: false, title: "", description: "", to: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[bytes.count - 1] ^= 0xff  // damages the record block's Adler-32/stream
        try Data(bytes).write(to: url)
        #expect(throws: (any Error).self) { try readMDict(at: url, isMDD: false) { _, _, _ in } }
        try Data(bytes.dropLast(5)).write(to: url)
        #expect(throws: (any Error).self) { try readMDict(at: url, isMDD: false) { _, _, _ in } }
    }
}
