/// **The word a ⌘-click opens in a new tab** (parity P47), handed over just before that tab's window is made and taken
/// once by it. It is held for `bound` at most, and dropped when the tab is not made (`failed`) or when another window is
/// opened on purpose (`cancel`, File ▸ New Tab): a later, unrelated window never inherits it.
@MainActor
public final class NewTabLookups {
    public static let shared = NewTabLookups()
    /// As long as `NewTab.open` waits for the window it asked for.
    public static let bound: Duration = .seconds(2)

    private var pending: (word: String, until: ContinuousClock.Instant)?

    public init() {}

    public func hand(_ word: String, now: ContinuousClock.Instant = .now) {
        pending = (word, now + Self.bound)
    }

    /// The word, for the window being made now; nil past the bound, which drops it.
    public func take(now: ContinuousClock.Instant = .now) -> String? {
        defer { pending = nil }
        guard let pending, now <= pending.until else { return nil }
        return pending.word
    }

    /// Another window is opened on purpose: nothing pending is its.
    public func cancel() { pending = nil }

    /// The tab asked for `word` was not made: drop the word, unless a newer click has handed another since.
    public func failed(_ word: String) {
        if pending?.word == word { pending = nil }
    }
}
