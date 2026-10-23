import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport
import XDictAppleSource

@Suite struct AppleDictTests {
    func read(_ o: SyntheticAppleBundle.Overrides = .init(), entries: [SyntheticAppleBundle.Entry]? = nil) throws -> ([AppleArticle], [Address: [Lexeme]]) {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try entries.map { try SyntheticAppleBundle.make(in: root, entries: $0, o) } ?? SyntheticAppleBundle.make(in: root, o)
        let props = try loadProperties(bundle: bundle)
        return (try readBody(bundle: bundle, props: props), try readKeyText(bundle: bundle, props: props))
    }

    func rejected(_ o: SyntheticAppleBundle.Overrides, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: AppleImportError.self, comment, sourceLocation: sourceLocation) { try read(o) }
    }

    let entries = [SyntheticAppleBundle.entry("e1", "a"), SyntheticAppleBundle.entry("e2", "b")]

    @Test func readsAValidBundle() throws {
        let (arts, keys) = try read()
        #expect(arts.count == 2)
        #expect(keys[arts[0].address]?.map(\.keyword) == ["alpha", "alphas"])
    }

    @Test func bodySizeAndJumpAreChecked() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.body = try SyntheticAppleBundle.body(entries, sizeDelta: 1)
        rejected(o, "size must equal jump - 4")
        o.body = try SyntheticAppleBundle.body(entries, jumpDelta: 1000)
        rejected(o, "jump past the data window")
        o.body = try SyntheticAppleBundle.body(entries, jumpDelta: -4)
        rejected(o, "short jump")
        o.body = try SyntheticAppleBundle.body(entries, sizeDelta: -1000, compress: false)
        rejected(o, "negative uncompressed size must throw, not trap")
    }

    @Test func decompressionIsBounded() throws {
        let bomb = try SyntheticAppleBundle.zlib([UInt8](repeating: 0, count: 1 << 22))
        for claim in [1, 1 << 30] {
            var o = SyntheticAppleBundle.Overrides()
            o.body = SyntheticAppleBundle.window(SyntheticAppleBundle.i32(8 + bomb.count) + SyntheticAppleBundle.i32(4 + bomb.count) + SyntheticAppleBundle.i32(claim) + bomb)
            rejected(o, "claimed inflated size \(claim)")
        }
    }

    @Test func keyTextBoundariesAreChecked() throws {
        let good = SyntheticAppleBundle.lexeme(0, "a", first: true)
        var o = SyntheticAppleBundle.Overrides()
        for bad in [Array(good.dropLast(2)), good + [7], Array(good.prefix(2)) + SyntheticAppleBundle.u16(5000) + Array(good.dropFirst(4))] {
            o.keytext = try SyntheticAppleBundle.keytext([SyntheticAppleBundle.record([bad])])
            rejected(o, "malformed lexeme \(bad)")
        }
        var rec = SyntheticAppleBundle.record([good])
        rec.replaceSubrange(0..<4, with: SyntheticAppleBundle.i32(1_000_000))
        o.keytext = try SyntheticAppleBundle.keytext([rec])
        rejected(o, "record jump past the data")
    }

    @Test func invalidUTF16IsRejected() throws {
        for field in [SyntheticAppleBundle.u16(2) + [0x00, 0xd8], SyntheticAppleBundle.u16(3) + [0x61, 0x62, 0x63]] {
            let inner = SyntheticAppleBundle.i32(0) + SyntheticAppleBundle.i32(0x20) + SyntheticAppleBundle.u16(0) + field
            let lex = SyntheticAppleBundle.u16(0) + SyntheticAppleBundle.u16(inner.count) + inner
            var o = SyntheticAppleBundle.Overrides()
            o.keytext = try SyntheticAppleBundle.keytext([SyntheticAppleBundle.record([lex])])
            rejected(o)
        }
    }

    @Test func plistShapeIsChecked() throws {
        var o = SyntheticAppleBundle.Overrides()
        o.plist = try SyntheticAppleBundle.plist(variable: ["DCSKeyword", "DCSKeyword"])
        rejected(o, "duplicate field name")
        for css in ["/etc/hosts", "../../x.css", "a/../../x.css", "a\\b.css", ""] {
            o.plist = try SyntheticAppleBundle.plist(css: css)
            rejected(o, "css name \(css)")
        }
        o.plist = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0)
        rejected(o, "list-valued root")
        o.plist = Data("not a plist".utf8)
        rejected(o, "garbage")
    }

    @Test func resourceNamesCannotEscapeThroughSymlinks() throws {
        let root = try SyntheticAppleBundle.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SyntheticAppleBundle.make(in: root)
        let secret = root.appendingPathComponent("secret.css")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/Resources/Evil.css"), withDestinationURL: secret)
        #expect(throws: AppleImportError.self) { try resourceURL(bundle: bundle, name: "Evil.css") }
        #expect(throws: Never.self) { try resourceURL(bundle: bundle, name: "DefaultStyle.css") }
    }
}
