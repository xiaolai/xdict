/// **The order records are written in: what XDict's own core reader folds keys to** (ADR-0011 decision 12). Derived
/// from the reader, not from any other tool:
///
/// - `core/xdict-mdx/src/text.rs`, `fold` and `cased_chars`: a case-insensitive key is case-folded character by
///   character (lower, then upper, then lower again, which is full Unicode case folding: ß becomes "ss", Σ σ ς all σ;
///   dotless ı is kept as it is); when the file strips keys, only Unicode letters and digits (Rust's
///   `char::is_alphanumeric`: Alphabetic, or a number of category Nd, Nl or No) are kept, unless that leaves nothing,
///   in which case the case-folded key is.
/// - `core/xdict-mdx/src/lib.rs`, the rules per file kind: an MDX by its header (this writer declares
///   `KeyCaseSensitive="No"` and `StripKey="Yes"`), an MDD case-insensitive and never stripped.
/// - `core/xdict-mdx/src/index.rs`: folded keys compare as strings, that is by UTF-8 bytes, which is scalar order, and
///   ties keep file order.
///
/// **The core does not need it**: it sorts its own index at import (`core/xdict-mdx/src/lib.rs`, "XDict sorts its own
/// index"), so any order reads. Writing in its order makes the file sorted under the reader's own folding, which a
/// reader that binary-searches the file's key blocks expects, and makes the order a fact the tests can state.
/// The test writer (`core/xdict-mdx-writer`) sorts by plain key bytes, as a fixture need not be sorted either.
enum KeyOrder {
    /// The key as the core folds it, as scalar values.
    static func folded(_ key: String, strip: Bool) -> [UInt32] {
        var cased: [Unicode.Scalar] = []
        for c in key.unicodeScalars {
            if c == "\u{131}" {  // ı: kept apart from i, as the core keeps it (no Turkish tailoring)
                cased.append(c)
                continue
            }
            for lower in c.properties.lowercaseMapping.unicodeScalars {
                for upper in lower.properties.uppercaseMapping.unicodeScalars {
                    cased.append(contentsOf: upper.properties.lowercaseMapping.unicodeScalars)
                }
            }
        }
        guard strip else { return cased.map(\.value) }
        let kept = cased.filter(isAlphanumeric)
        return (kept.isEmpty ? cased : kept).map(\.value)
    }

    /// Rust's `char::is_alphanumeric`: the Alphabetic property, or a numeric general category.
    static func isAlphanumeric(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        switch p.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return p.isAlphabetic
        }
    }

    /// Indices of `keys` in the order they are written: by folded key, ties in input order.
    static func order(_ keys: [String], isMDD: Bool) -> [Int] {
        keys.enumerated().map { ($0.offset, folded($0.element, strip: !isMDD)) }
            .sorted { a, b in a.1 != b.1 ? a.1.lexicographicallyPrecedes(b.1) : a.0 < b.0 }
            .map(\.0)
    }
}
