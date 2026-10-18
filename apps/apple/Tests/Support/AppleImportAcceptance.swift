import Foundation

/// **The acceptance bundle and what converting it must write, record by record** (plan WI-3 acceptance), shared by the
/// converter's tests (read back by the test-only reader, in file order) and the service's (read back through the core's
/// binding). The expectation is written out by hand here, never derived from a conversion, so a converter that drifts
/// cannot carry its expectation with it.
///
/// Each `Variant` other than `.faithful` changes exactly one thing and keeps every count (records, keys, resources), so a
/// comparison that only counted would pass it: these are the positive controls the comparison must fail.
public enum AppleImportAcceptance {
    public enum Variant: CaseIterable, Sendable {
        case faithful
        /// One definition's text: "second" becomes "secone".
        case definition
        /// One redirect's target: "alphas" leads to gamma, not alpha.
        case redirectTarget
        /// One byte of one resource.
        case resourceByte
        /// One trailing newline after a definition.
        case trailingNewline
    }

    public static let stylesheet = "body { color: black }"
    /// Two variants of one pronunciation, each marked by Apple's `d:prn` (synthetic text). The stylesheet selects no
    /// attribute, so the markers survive only because the converter keeps them (ADR-0013 decision 1).
    static let pronunciations =
        "<span class=\"ph t_respell\" d:prn=\"US\">thurd</span><span class=\"ph t_IPA\" d:prn=\"US\">/thurd/</span>"
    public static let image: [UInt8] = [0x89, 0x50, 0x4e, 0x47]

    /// Writes the acceptance bundle under `root`, changed as `variant` says.
    public static func bundle(in root: URL, _ variant: Variant) throws -> URL {
        let second = variant == .definition ? "<p>secone</p>" : variant == .trailingNewline ? "<p>second</p>\n" : "<p>second</p>"
        let entries: [SyntheticAppleBundle.Entry] = [
            ("e1", "alpha", "<p>first <a href=\"x-dictionary:r:e2\">beta</a></p>", variant == .redirectTarget ? [] : ["alphas"]),
            ("e2", "beta", second, []),
            ("e3", "gamma", "<p>third " + pronunciations + "</p>", variant == .redirectTarget ? ["gammas", "alphas"] : ["gammas"]),
        ]
        var o = SyntheticAppleBundle.Overrides()
        o.css = stylesheet
        var png = image
        if variant == .resourceByte { png[3] ^= 1 }
        o.resources = ["img/a.png": Data(png)]
        return try SyntheticAppleBundle.make(in: root, entries: entries, o)
    }

    static let link = "<link rel=\"stylesheet\" type=\"text/css\" href=\"apple.css\">"

    /// The MDX records the faithful bundle converts to, in the order they are written: the core's tier-1 folding
    /// (`core/xdict-mdx/src/text.rs`), ties in input order. A record's text without its CR LF NUL terminator.
    public static let records: [(key: String, value: String)] = [
        ("alpha", link + "<div id=\"e1\" class=\"entry\"><p>first <a href=\"entry://beta\">beta</a></p></div>"),
        ("alphas", "@@@LINK=alpha"),
        ("beta", link + "<div id=\"e2\" class=\"entry\"><p>second</p></div>"),
        ("gamma", link + "<div id=\"e3\" class=\"entry\"><p>third <span class=\"ph t_respell\" data-d-prn=\"US\">thurd</span>"
            + "<span class=\"ph t_IPA\" data-d-prn=\"US\">/thurd/</span></p></div>"),
        ("gammas", "@@@LINK=gamma"),
    ]

    /// The MDD records, in order, but for the stylesheet's text, which the caller supplies (it ends with the converter's
    /// own fallback rules): `\apple.css` (ADR-0011 decision 6: a fixed name), then the bundle's one image.
    public static func resources(stylesheet css: [UInt8]) -> [(key: String, value: [UInt8])] {
        [("\\apple.css", css), ("\\img\\a.png", image)]
    }

    /// Every way `got` differs from `expected`, in order: a missing, extra or reordered record, or one whose value differs.
    public static func mismatches<V: Equatable>(_ got: [(key: String, value: V)], _ expected: [(key: String, value: V)]) -> [String] {
        var out: [String] = []
        if got.count != expected.count { out.append("\(got.count) records, expected \(expected.count)") }
        for (i, (g, e)) in zip(got, expected).enumerated() {
            if g.key != e.key { out.append("record \(i): key \(g.key.debugDescription), expected \(e.key.debugDescription)") }
            if g.value != e.value { out.append("record \(i) (\(e.key)): value differs") }
        }
        return out
    }
}
