import Foundation
import Testing
@testable import XDictAppleImport
import XDictTestSupport

@Suite struct TransformTests {
    static let ns = "xmlns:d=\"\(SyntheticAppleBundle.dNS)\""

    func parse(_ xml: String, css: Set<String>? = nil, stats: Stats = Stats()) throws -> ParsedArticle {
        try EntryTransformer(cssAttrs: css).transform(Array(xml.utf8)[...], address: Address(section: 0, chunk: 0), stats: stats)
    }

    func entry(_ body: String, attrs: String = "id=\"e\" d:title=\"t\"") -> String {
        "<d:entry \(Self.ns) \(attrs)>\(body)</d:entry>"
    }

    func html(_ body: String, css: Set<String>? = nil) throws -> String {
        let a = try parse(entry(body), css: css)
        let patched = try patchLinks(a, keyByID: [:], keys: [], stats: Stats())
        return String(decoding: patched, as: UTF8.self)
    }

    @Test func rootIdentityComesFromTheOriginalAttributes() throws {
        let a = try parse("<d:entry \(Self.ns) xmlns:xml2=\"urn:x\" id=\"e\" xml:id=\"other\" data-d-title=\"x\" d:title=\"T\"></d:entry>")
        #expect(a.id == "e")
        #expect(a.key == "T")
        let b = try parse("<d:entry \(Self.ns) id=\"e2\" data-d-title=\"plain\"></d:entry>")
        #expect(b.key == "e2", "a plain data-d-title attribute is not d:title")
    }

    @Test func placeholderLookalikesInTextAreHarmless() throws {
        let a = try parse(entry("apple2mdx-link:99999999999999999999 <a href=\"x-dictionary:r:e\">x</a> apple2mdx-link:0"))
        let out = String(decoding: try patchLinks(a, keyByID: [Array("e".utf8): "K"], keys: [], stats: Stats()), as: UTF8.self)
        #expect(out.contains("<a href=\"entry://K\">x</a>"))
        #expect(out.contains("apple2mdx-link:99999999999999999999"))
        #expect(a.placeholder != linkPlaceholder, "a different prefix must have been chosen")
    }

    @Test func activeContentNeverSurvives() throws {
        let out = try html("<script>x()</script><p onclick=\"y\" class=\"k\">t<a href=\" JaVa\tScript:1\">l</a></p><iframe>q</iframe>", css: ["onclick"])
        #expect(!out.contains("script") && !out.contains("onclick") && !out.contains("iframe") && !out.contains("JaVa"))
        #expect(out.contains("class=\"k\""))
    }

    @Test func voidElementsDropTheirContent() throws {
        let out = try html("<p>a<br>x<b>y</b></br>t</p>")
        #expect(out.contains("<p>a<br>t</p>"))
    }

    @Test func booleanAttributesAreBare() throws {
        let out = try html("<td nowrap=\"nowrap\" colspan=\"2\">c</td>", css: ["nowrap"])
        #expect(out.contains("<td nowrap colspan=\"2\">"))
    }

    @Test func styleTextIsNotEscaped() throws {
        let out = try html("<style>a&gt;b</style><p>a&gt;b</p>")
        #expect(out.contains("<style>a>b</style><p>a&gt;b</p>"))
    }

    @Test func uriAttributesAreEscapedTheWayLibxml2Does() throws {
        let out = try html("<a href=\"  a b&lt;[é\">t</a>")
        #expect(out.contains("<a href=\"a%20b&lt;[%C3%A9\">"))
    }

    @Test func deadLinkWithoutOtherAttributesBecomesASpan() throws {
        let out = try html("<a href=\"x-dictionary:d:nope\">n</a>")
        #expect(out.contains("<span>n</span>"))
    }

    @Test func pdfImageKeepsItsAltText() throws {
        let out = try html("<img src=\"x-dictionary:d:g.pdf\" alt=\"Guide\"/>")
        #expect(out.contains(">Guide</span>") || out.contains(">Guide</a>"))
    }

    @Test func malformedXMLIsAnError() {
        let bad = [
            "<1x/>", "<p a=\"1\" a=\"2\"/>", "<p xmlns:a=\"u\" xmlns:b=\"u\" a:x=\"1\" b:x=\"2\"/>", "<p>&#0;</p>",
            "<p>\u{FFFE}</p>", "<p>a]]>b</p>", "<p a=\"1\"b=\"2\">x</p>", "<p>&#X41;</p>", "<p>&#+65;</p>",
            String(repeating: "<b>", count: 300) + String(repeating: "</b>", count: 300),
        ]
        for b in bad {
            #expect(throws: EntryFault.self, "\(b.prefix(40))") { try parse(entry(b)) }
        }
    }

    @Test func canonicallyEquivalentPrefixesStayDistinct() throws {
        // U+00E9 versus e + U+0301: different XML names, so the second prefix is undeclared
        let xml = "<d:entry \(Self.ns) id=\"e\" xmlns:\u{E9}=\"\(xhtmlNS)\"><e\u{301}:b/></d:entry>"
        #expect(throws: EntryFault.self) { try parse(xml) }
    }

    @Test func deepNestingWithinTheLimitIsAccepted() throws {
        _ = try parse(entry(String(repeating: "<b>", count: 200) + "x" + String(repeating: "</b>", count: 200)))
    }
}
