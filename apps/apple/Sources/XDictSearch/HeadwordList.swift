import Foundation

/// **The sidebar's list, as Apple's Dictionary has it** (parity ledger P9, P13): every headword matching what the reader
/// typed, one row each across the dictionaries in scope — the typed word's own matches first, in the reader's order, then
/// the keys that begin with it — or, when there is none, the nearest spellings the dictionaries themselves hold
/// ("Did you mean?").
public struct Listing: Hashable, Sendable {
    /// What the reader typed.
    public let typed: String
    public var headwords: [String]
    /// The rows are spelling guesses, not matches.
    public var isGuess: Bool
    /// Every part of the list has answered; until then the rows are what is known so far.
    public var settled: Bool

    public init(typed: String, headwords: [String] = [], isGuess: Bool = false, settled: Bool = false) {
        self.typed = typed
        self.headwords = headwords
        self.isGuess = isGuess
        self.settled = settled
    }

    /// The words, each once, in the order first met.
    static func merged(_ lists: [String]...) -> [String] {
        var seen: Set<String> = []
        return lists.joined().filter { seen.insert($0).inserted }
    }
}

