import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport

/// **Refusals are kinds carrying data, never sentences** (ADR-0011 decision 11): the shell words them (ADR-0007), and
/// no one parses a diagnostic. The human detail goes to the `Report`, apart from the error.
struct FailureTests {
    func refusal(_ o: SyntheticAppleBundle.Overrides = .init(), entries: [SyntheticAppleBundle.Entry] = SyntheticAppleBundle.defaultEntries,
                 bounds: Bounds = .production, report: Report = Report()) throws -> AppleImportError? {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root, entries: entries, o)
        let out = root.appendingPathComponent("out")
        do {
            try convert(snapshot: bundle, into: out, name: "T", bounds: bounds, report: report)
        } catch {
            // A refused conversion leaves nothing behind (ADR-0011 decision 5).
            #expect((try? FileManager.default.contentsOfDirectory(atPath: out.path))?.isEmpty ?? true, "output left after \(error)")
            return error
        }
        return nil
    }

    // MARK: - ADR-0011 decision 4 and 11: what is refused, by kind

    @Test func version4IsRefusedByKind() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: 4)
        #expect(try refusal(o) == .notVersion3(found: 4))
    }

    @Test func aMissingVersionIsRefusedByKind() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(version: nil)
        #expect(try refusal(o) == .notVersion3(found: nil))
    }

    /// The system "Apple Dictionary" has no `KeyText.index`.
    @Test func noKeyTextIndexIsRefusedByKind() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(keyTextIndex: false)
        #expect(try refusal(o) == .noKeyTextIndex)
    }

    @Test func aMalformedInfoPlistIsRefusedByKind() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = Data("not a plist".utf8)
        #expect(try refusal(o) == .malformedInfoPlist(.unparsable))
        o.plist = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0)
        #expect(try refusal(o) == .malformedInfoPlist(.notADictionary))
        o.plist = try SyntheticAppleBundle.plist(variable: ["DCSKeyword", "DCSKeyword"])
        #expect(try refusal(o) == .malformedInfoPlist(.field("IDXVariableDataFields")))
    }

    @Test func aDamagedBodyIsCorruptAtItsOffset() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.body = try SyntheticAppleBundle.body([SyntheticAppleBundle.entry("e1", "a")], sizeDelta: 1)
        guard case .corrupt(.body(let offset)) = try refusal(o) else {
            Issue.record("not a corrupt body")
            return
        }
        #expect(offset == 0x60, "the first section, after the 0x40 header and the 0x20 window start")
    }

    /// The human detail of a bad entry is in the report, and the error names only where.
    @Test func aBadEntryIsCorruptWhereItIsWithItsDetailInTheReport() throws {
        let report = Report()
        let error = try refusal(entries: [("e1", "a\u{1}b", "<p>x</p>", [])], report: report)
        #expect(error == .corrupt(.entry(section: 0x20, chunk: 0)))
        #expect(report.lines.contains { $0.contains("Invalid character") }, "\(report.lines)")
    }

    @Test func anExistingOutputIsNeverReplaced() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: out.appendingPathComponent("T.mdd"))
        #expect(throws: AppleImportError.outputExists(file: "T.mdd")) { try convert(snapshot: bundle, into: out, name: "T") }
        #expect(try Data(contentsOf: out.appendingPathComponent("T.mdd")) == Data("precious".utf8))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("T.mdx").path))
    }

    @Test func anUnsafeOutputNameIsRefusedByKind() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        for name in ["../escape", "/abs", "a/b", "", "..", "a\\b"] {
            #expect(throws: AppleImportError.unsafeOutputName(name)) {
                try convert(snapshot: bundle, into: root.appendingPathComponent("o"), name: name)
            }
        }
    }

    // MARK: - Hardening item 1: bounded reads, a decompression budget, an output cap

    /// A file over the cap is refused before it is read whole.
    @Test func aSourceFileOverItsCapIsRefused() throws {
        var bounds = Bounds.production
        bounds.sourceFileBytes = 100
        guard case .boundExceeded(.sourceFile(let name, let limit)) = try refusal(bounds: bounds) else {
            Issue.record("not a source-file bound")
            return
        }
        #expect(name == "Body.data" && limit == 100)
    }

    /// Every section within the per-block bound, all of them together over the budget.
    @Test func theDecompressionBudgetIsCumulative() throws {
        let filler = String(repeating: "x", count: 4000)
        let sections = (0..<4).map { i in [SyntheticAppleBundle.entry("e\(i)", "k\(i)", "<p>\(filler)</p>")] }
        var o = SyntheticAppleBundle.Overrides()
        o.body = try SyntheticAppleBundle.body(sections: sections)
        var bounds = Bounds.production
        bounds.decompressedBytes = 10_000  // one section inflates to ~4 KiB; four do not fit
        #expect(try refusal(o, bounds: bounds) == .boundExceeded(.decompression(limit: 10_000)))
    }

    @Test func theOutputCapIsHeld() throws {
        var bounds = Bounds.production
        bounds.outputBytes = 64
        #expect(try refusal(bounds: bounds) == .boundExceeded(.output(limit: 64)))
    }

    /// The control: the same bundle within every production bound converts.
    @Test func theProductionBoundsAdmitTheSyntheticBundle() throws {
        #expect(try refusal() == nil)
    }

    /// The bounds are what ADR-0011 decision 4 names, or reasoned from it, and the per-block one is deflate's own limit.
    @Test func theProductionBoundsAreTheNamedOnes() {
        #expect(Bounds.production.sourceFileBytes == 512 << 20)
        #expect(maxInflatedBlock == 256 << 20)
        #expect(Bounds.production.decompressedBytes >= Bounds.production.sourceFileBytes)
        #expect(Bounds.production.outputBytes >= Bounds.production.sourceFileBytes)
    }
}
