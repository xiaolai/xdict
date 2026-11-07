import Foundation
import Testing
@testable import XDictCapture

/// **The log a reader hands back** (owner, 2026-10-29): kinds and reasons by default, the words only when they say so, a
/// file bounded by rotation, and an export that carries the last of it whatever the files are called.
struct DiagnosticsTests {
    private func made(_ maxBytes: Int = Diagnostics.maxBytes) throws -> (Diagnostics, UserDefaults, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.diag.\(UUID().uuidString)"))
        return (Diagnostics(defaults: suite, directory: folder, maxBytes: maxBytes), suite, folder)
    }

    @Test func aLineCarriesKindsAndNotTheWord() throws {
        let (diagnostics, _, _) = try made()
        diagnostics.record("hover.delivered", ["word": diagnostics.word("inspection"), "request": "7"])
        let text = diagnostics.exportText()
        #expect(text.contains("hover.delivered"))
        #expect(text.contains("request=7"))
        #expect(text.contains("<withheld: 10 chars>"))
        #expect(!text.contains("inspection"), "the word a reader looked up was written without their leave")
    }

    @Test func theReadersSwitchPutsTheirWordsIn() throws {
        let (diagnostics, suite, _) = try made()
        suite.set(true, forKey: Diagnostics.includeTextKey)
        diagnostics.record("hover.delivered", ["word": diagnostics.word("inspection")])
        #expect(diagnostics.exportText().contains("word=inspection"))
    }

    @Test func aValueStaysOnItsLine() throws {
        let (diagnostics, _, _) = try made()
        diagnostics.record("event", ["why": "one\ntwo"])
        #expect(diagnostics.exportText().contains("why=one\\ntwo"))
    }

    /// **The bound is bytes, and a line is the unit** (audit 2026-10-29 finding 4): the old tail counted grapheme clusters,
    /// so Chinese lines — three bytes a character — could exceed the limit it claimed, and the tail could begin inside a
    /// line.
    @Test func theExportedTailIsBoundedInBytesAndWholeLines() throws {
        let (diagnostics, _, _) = try made()
        for index in 0..<400 {
            diagnostics.record("word", ["n": "\(index)", "text": String(repeating: "词", count: 10)])
        }
        let text = diagnostics.exportText(limit: 400)
        #expect(text.utf8.count <= 400, "the tail was \(text.utf8.count) bytes for a 400-byte bound")
        #expect(text.hasPrefix("… the log was longer; its last part follows\n"))
        #expect(text.contains("n=399"), "the newest line was not in the tail")
        // Every line but the marker is a whole record: nothing begins or ends mid-line.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() where !line.isEmpty {
            #expect(line.hasSuffix(String(repeating: "词", count: 10)), "a record was cut before its end: \(line)")
        }
        // **Even the marker obeys the bound** (verify 2026-10-29): a limit below its own bytes is not answered with more.
        for tiny in [0, 5, 20] {
            #expect(diagnostics.exportText(limit: tiny).utf8.count <= tiny, "limit \(tiny) was exceeded")
        }
    }

    /// The file is bounded: past its size it rotates, and three files are kept — the oldest dropped.
    @Test func theFileRotatesAndKeepsThree() throws {
        let (diagnostics, _, folder) = try made(240)
        for index in 0..<40 {
            diagnostics.record("line", ["n": "\(index)", "pad": String(repeating: "x", count: 40)])
        }
        // The appends are queued; the export waits for them, so the listing below sees what was written.
        _ = diagnostics.exportText()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(names.contains("diagnostics.log"))
        #expect(names.contains("diagnostics.1.log"))
        #expect(Set(names).count <= Diagnostics.keep)
        #expect(!names.contains("diagnostics.3.log"), "more files were kept than the bound")
        // The newest line is in the log, the oldest long gone.
        #expect(diagnostics.exportText().contains("n=39"))
    }
}

/// **A value is one field of one line, whatever it holds** (audit 2026-11-05 L15): a line is `key=value` fields
/// separated by spaces, so a value may hold no line break of any kind, no control character, and no bare space, quote or
/// `=` that would end the field or start another; and what was escaped reads back as what was written.
struct DiagnosticsEscapingTests {
    /// Every control character (C0, DEL, C1), the two Unicode line breaks, the quote, the backslash, the space and `=`.
    static let hostile: [Unicode.Scalar] = (0x00...0x1F).compactMap(Unicode.Scalar.init) + [Unicode.Scalar(0x7F)]
        + (0x80...0x9F).compactMap(Unicode.Scalar.init) + ["\u{2028}", "\u{2029}", "\"", "\\", " ", "="]

    @Test func everyHostileCharacterStaysInsideItsField() {
        for scalar in Self.hostile {
            let value = "a\(Character(scalar))b"
            let field = Diagnostics.escaped(value)
            let line = "key=\(field) next=1"
            #expect(!field.unicodeScalars.contains { $0.properties.generalCategory == .control
                        || $0 == "\u{2028}" || $0 == "\u{2029}" },
                    "U+\(String(scalar.value, radix: 16)) was written raw: \(field.debugDescription)")
            #expect(Self.fields(line)?.first == ["key", value],
                    "U+\(String(scalar.value, radix: 16)) did not read back: \(field.debugDescription)")
            #expect(Self.fields(line)?.last == ["next", "1"], "U+\(String(scalar.value, radix: 16)) ended its field early")
        }
    }

    @Test func anOrdinaryValueIsWrittenAsItIs() {
        #expect(Diagnostics.escaped("notTapped") == "notTapped")
        #expect(Diagnostics.escaped("词") == "词")
    }

    /// The reader of the format this test holds the writer to: fields split on spaces outside quotes, a quoted value
    /// read up to its closing quote, and `\\`, `\"`, `\n`, `\r`, `\t` and `\u{…}` undone. Nil for a malformed line.
    static func fields(_ line: String) -> [[String]]? {
        var fields: [[String]] = []
        var scalars = line.unicodeScalars.makeIterator()
        var key = "", value = "", inKey = true, quoted = false, started = false
        func flush() {
            fields.append([key, value])
            (key, value, inKey, quoted, started) = ("", "", true, false, false)
        }
        while let scalar = scalars.next() {
            if inKey {
                if scalar == "=" { inKey = false } else { key.unicodeScalars.append(scalar) }
                continue
            }
            if !started, scalar == "\"" { quoted = true; started = true; continue }
            started = true
            if quoted, scalar == "\"" {
                quoted = false
                continue
            }
            if !quoted, scalar == " " { flush(); continue }
            if !quoted, scalar == "\"" || scalar == "=" { return nil }
            guard scalar == "\\" else { value.unicodeScalars.append(scalar); continue }
            guard let escape = scalars.next() else { return nil }
            switch escape {
            case "\\": value += "\\"
            case "\"": value += "\""
            case "n": value += "\n"
            case "r": value += "\r"
            case "t": value += "\t"
            case "u":
                guard scalars.next() == "{" else { return nil }
                var hex = ""
                while let digit = scalars.next(), digit != "}" { hex.unicodeScalars.append(digit) }
                guard let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) else { return nil }
                value.unicodeScalars.append(decoded)
            default: return nil
            }
        }
        if !inKey { flush() }
        return fields
    }
}
