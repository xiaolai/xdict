import Foundation

/// The term a selection stands for: whitespace and the punctuation that only wraps or ends a word
/// come off — “ephemeral,” is ephemeral — while punctuation that belongs to the term stays: C#,
/// .NET, U.S., don't, word(s), -ish. Moved down from `XDictAnywhere` with the selection reader (plan-capture WI-2):
/// which characters a selection's term is made of is capture's; how long a term lookup admits is not (`TermAdmission`).
public struct SelectedTerm: Equatable, Sendable {
    public let text: String
    /// Where `text` sits in the selection it came from, UTF-16.
    public let range: NSRange

    /// Nil when nothing is left: the selection was only whitespace and punctuation.
    public init?(from selection: String) {
        var lower = selection.startIndex
        var upper = selection.endIndex
        while lower < upper {
            let first = selection[lower]
            let last = selection[selection.index(before: upper)]
            let inner = selection[lower..<upper]
            if first.isWhitespace || (Self.isOpening(first) && !Self.closes(first, in: inner)) {
                lower = selection.index(after: lower)
            } else if last.isWhitespace || Self.isTrailing(last, in: inner) {
                upper = selection.index(before: upper)
            } else if inner.count > 1, Self.pairs(first, last, around: inner.dropFirst().dropLast()) {
                lower = selection.index(after: lower)
                upper = selection.index(before: upper)
            } else {
                break
            }
        }
        guard lower < upper else { return nil }
        text = String(selection[lower..<upper])
        range = NSRange(lower..<upper, in: selection)
    }

    private static let brackets: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "（": "）", "「": "」", "『": "』", "【": "】", "《": "》", "〈": "〉",
    ]
    /// Ends a sentence or clause, in Latin and CJK scripts.
    private static let sentencePunctuation: Set<Character> = [",", ";", ":", "!", "?", "…", "。", "，", "、", "；", "：", "！", "？"]
    private static let dashes: Set<Character> = ["—", "–"]

    /// Opening quotes and ¿ ¡ always come off the front; an opening bracket only when its closer is
    /// not in the term — "(word)" loses both, "(s)he" keeps its own.
    private static func isOpening(_ character: Character) -> Bool {
        guard let category = character.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .openPunctuation || category == .initialPunctuation
            || ["\"", "¿", "¡"].contains(character) || dashes.contains(character)
    }

    private static func closes(_ opener: Character, in term: Substring) -> Bool {
        guard let closer = brackets[opener] else { return false }
        return term.dropFirst().contains(closer)
    }

    /// Closing quotes, sentence punctuation and dashes come off the end; a closing bracket only when
    /// its opener is not in the term (word(s) keeps it); a final full stop unless the term is an
    /// abbreviation spelled with stops — "U.S.", "e.g.", "Ph.D." keep theirs; "etc.", ".NET." and
    /// "example.com." lose it, and "word..." loses all three.
    private static func isTrailing(_ character: Character, in term: Substring) -> Bool {
        if let opener = brackets.first(where: { $0.value == character })?.key { return !term.dropLast().contains(opener) }
        if character == "." { return !isDottedAbbreviation(term) }
        guard let category = character.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .closePunctuation || category == .finalPunctuation
            || character == "\"" || sentencePunctuation.contains(character) || dashes.contains(character)
    }

    /// Two or more short letter groups, each followed by a stop: U.S., e.g., a.m., Ph.D.
    private static func isDottedAbbreviation(_ term: Substring) -> Bool {
        let groups = term.split(separator: ".", omittingEmptySubsequences: false)
        guard term.hasSuffix("."), groups.count >= 3, groups.last?.isEmpty == true else { return false }
        return groups.dropLast().allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }

    /// Marks that come off only as a pair around the whole term. Straight quotes are both opening
    /// and closing — 'quoted' loses both, 'tis and dogs' keep theirs — and a bracket wrapping the
    /// term, "(word)", goes with its closer; "(a) or (b)" keeps both, being two groups, not one.
    private static func pairs(_ first: Character, _ last: Character, around inner: Substring) -> Bool {
        if first == "'" && last == "'" { return true }
        guard brackets[first] == last else { return false }
        return !inner.contains(first) && !inner.contains(last)
    }
}

/// **How long a term the consumer admits, in characters (graphemes)** — handed to capture, never capture's own (XDict
/// ADR-0014 decision 3: lookup admission limits belong to the consumer). A term over it is refused whole, with its
/// length, and never cut: a cut key is a key nobody selected.
public struct TermAdmission: Sendable, Equatable {
    /// Graphemes, as `String.count` counts them. Zero admits nothing.
    public let maximumCharacters: Int

    public init(maximumCharacters: Int) {
        self.maximumCharacters = maximumCharacters
    }

    public func admits(_ term: String) -> Bool { term.count <= maximumCharacters }
}
