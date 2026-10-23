import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport
import XDictAppleSource

/// **Every record, in file order, exactly** (plan WI-3 acceptance), read back by the test-only reader: the order the
/// core's folding gives, each key's bytes, each record's bytes (MDX terminator removed), each resource's bytes. The
/// service's tests read the same conversion back through the core's binding (`AppleImportAcceptanceTests`).
struct AcceptanceTests {
    func converted(_ variant: AppleImportAcceptance.Variant, in root: URL) throws -> (mdx: [(key: String, value: String)],
                                                                                      mdd: [(key: String, value: [UInt8])]) {
        let dir = root.appendingPathComponent("\(variant)")
        let bundle = try AppleImportAcceptance.bundle(in: dir, variant)
        let out = dir.appendingPathComponent("out")
        try convert(snapshot: bundle, into: out, name: "T")
        let mdx = try readRecords(out.appendingPathComponent("T.mdx"), isMDD: false)
            .map { (key: String(decoding: $0.0, as: UTF8.self), value: String(decoding: $0.1, as: UTF8.self)) }
        let mdd = try readRecords(out.appendingPathComponent("T.mdd"), isMDD: true).map { (key: utf16Key($0.0), value: $0.1) }
        return (mdx, mdd)
    }

    var expectedResources: [(key: String, value: [UInt8])] {
        AppleImportAcceptance.resources(stylesheet: Array((AppleImportAcceptance.stylesheet + "\n" + fallbackCSS).utf8))
    }

    @Test func theFaithfulConversionMatchesRecordForRecord() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = try converted(.faithful, in: root)
        #expect(AppleImportAcceptance.mismatches(got.mdx, AppleImportAcceptance.records) == [])
        #expect(AppleImportAcceptance.mismatches(got.mdd, expectedResources) == [])
    }

    /// **The positive controls**: one definition, one redirect target, one resource byte, one trailing newline, each
    /// changed with every count kept, and each must fail the comparison above.
    @Test(arguments: [AppleImportAcceptance.Variant.definition, .redirectTarget, .resourceByte, .trailingNewline])
    func eachControlFailsTheComparison(_ variant: AppleImportAcceptance.Variant) throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = try converted(variant, in: root)
        #expect(got.mdx.count == AppleImportAcceptance.records.count && got.mdd.count == expectedResources.count,
                "a control must keep every count, or it does not test the comparison")
        let found = AppleImportAcceptance.mismatches(got.mdx, AppleImportAcceptance.records)
            + AppleImportAcceptance.mismatches(got.mdd, expectedResources)
        #expect(!found.isEmpty, "\(variant) passed the record comparison")
    }
}
