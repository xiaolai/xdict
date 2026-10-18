import Foundation
import Testing
@testable import XDictAppleImport
import XDictCore
import XDictTestSupport

/// **The converter's output, read back by the core** (ADR-0011 decisions 2 and 3; plan WI-3 acceptance): the spike's
/// reader does not ship, so a conversion is accepted as the core's binding reads it. Every record the converter meant to
/// write is asked of the core, in the expectation's order, and compared exactly: an article as `entry()` serves it under
/// the original style (the record whole, its terminator kept, only its two URLs rewritten to XDict's scheme), a
/// redirect by the target the core follows it to, a resource by its bytes.
///
/// What the binding cannot show: the order of records in the file (the core sorts its own index, `xdict-mdx/src/lib.rs`),
/// which the converter's own tests hold with the test-only reader (`AcceptanceTests`).
struct AppleImportAcceptanceTests {
    static let base = "xdict://d/"

    /// The core's answer for every expected key and resource, as (key, what it serves), for comparison.
    func answers(_ variant: AppleImportAcceptance.Variant, in root: URL)
        throws -> (mdx: [(key: String, value: String)], mdd: [(key: String, value: [UInt8])]) {
        let dir = root.appending(path: "\(variant)")
        let bundle = try AppleImportAcceptance.bundle(in: dir, variant)
        let out = dir.appending(path: "out")
        try convert(snapshot: bundle, into: out, name: "T")
        let cache = dir.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try Core(config: Config(dataDir: cache.path, cacheDir: cache.path, clientProtocol: versions().protocol,
                                           entropy: Data(), stripOffForTests: false))
        let package = Package(mdx: .path(path: out.appending(path: "T.mdx").path),
                              mdd: [.path(path: out.appending(path: "T.mdd").path)], sidecars: [])
        _ = try core.import(package: package, progress: nil)
        guard case .ready(let dict, _, _) = try core.open(package: package) else {
            throw Refused(description: "\(variant): the converted pair did not open")
        }
        let view = View(baseUrl: Self.base, maxBodyBytes: 1 << 24, originalStyle: true)
        var mdx: [(key: String, value: String)] = []
        for (key, _) in AppleImportAcceptance.records {
            let hits = try core.lookup(query: key, dicts: [dict], options: LookupOptions(limit: 10, offset: 0, mode: .link,
                                                                                          generation: nil)).hits
            guard hits.count == 1, let hit = hits.first else {
                mdx.append((key, "\(hits.count) hits"))
                continue
            }
            switch hit.how {
            case .redirect(let chain) where chain.first == key:
                mdx.append((key, "@@@LINK=" + hit.entry.key))
            case .exact where hit.entry.key == key:
                mdx.append((key, try core.entry(dict: dict, entry: hit.entry, view: view).html))
            default:
                mdx.append((key, "reached \(hit.entry.key) by \(hit.how)"))
            }
        }
        var mdd: [(key: String, value: [UInt8])] = []
        for (key, _) in AppleImportAcceptance.resources(stylesheet: []) {
            let path = key.dropFirst().replacingOccurrences(of: "\\", with: "/")
            switch try core.resource(dict: dict, path: path, view: view) {
            case .found(_, _, let bytes): mdd.append((key, [UInt8](bytes)))
            case .missing: mdd.append((key, []))
            }
        }
        return (mdx, mdd)
    }

    /// An article as `entry()` serves it under the original style: the doctype, the record with its stylesheet link and
    /// its `entry://` links in XDict's scheme, and the record's own CR LF (the core keeps it; its NUL it drops).
    static func served(_ record: String) -> String {
        guard !record.hasPrefix("@@@LINK=") else { return record }
        let rewritten = record.replacingOccurrences(of: "href=\"apple.css\"", with: "href=\"\(base)r/apple.css\"")
            .replacingOccurrences(of: "href=\"entry://", with: "href=\"\(base)entry/")
        return "<!DOCTYPE html>" + rewritten + "\r\n"
    }

    var expected: (mdx: [(key: String, value: String)], mdd: [(key: String, value: [UInt8])]) {
        (AppleImportAcceptance.records.map { ($0.key, Self.served($0.value)) },
         AppleImportAcceptance.resources(stylesheet: Array((AppleImportAcceptance.stylesheet + "\n" + fallbackCSS).utf8)))
    }

    @Test func theCoreReadsTheFaithfulConversionRecordForRecord() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = try answers(.faithful, in: root)
        #expect(AppleImportAcceptance.mismatches(got.mdx, expected.mdx) == [])
        #expect(AppleImportAcceptance.mismatches(got.mdd, expected.mdd) == [])
    }

    /// **The positive controls, through the core**: each one-thing change, counts kept, must fail the comparison.
    @Test(arguments: [AppleImportAcceptance.Variant.definition, .redirectTarget, .resourceByte, .trailingNewline])
    func eachControlFailsTheComparisonThroughTheCore(_ variant: AppleImportAcceptance.Variant) throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = try answers(variant, in: root)
        let found = AppleImportAcceptance.mismatches(got.mdx, expected.mdx) + AppleImportAcceptance.mismatches(got.mdd, expected.mdd)
        #expect(!found.isEmpty, "\(variant) passed the comparison through the core")
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }
}
