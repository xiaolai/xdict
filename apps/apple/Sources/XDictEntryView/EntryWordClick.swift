import Foundation

/// **A word the reader ⌘-clicked in an entry, to open in a new tab** (parity P47; owner, 2026-10-18: only ⌘-click, as
/// a plain click is too easily a misclick). It comes from the shell's own script (`word-clicks.js`), but through a page
/// the dictionary wrote, so it is taken only as one bounded word: `{kind: "word", word}` and nothing else, at most
/// `maximumLength` Unicode scalars, with no whitespace and no control or separator character.
public struct EntryWordClick: Equatable, Sendable {
    /// The script's bound (`XDictWordCore.MAX`), held again here.
    public static let maximumLength = 64

    public let word: String

    public init?(message body: Any) {
        guard let body = body as? [String: Any], body.count == 2, body["kind"] as? String == "word",
              let word = body["word"] as? String, !word.isEmpty, word.unicodeScalars.count <= Self.maximumLength,
              word.unicodeScalars.allSatisfy(Self.allowed) else { return nil }
        self.word = word
    }

    private static func allowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return false }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .unassigned: return false
        default: return true
        }
    }
}
