import Foundation
import Observation

/// **The words looked up last** (Codex's UX decision §5): up to 8, newest first, none twice, kept across launches; what
/// an empty sidebar offers. Choosing one looks it up again in the current scope.
@MainActor
@Observable
public final class RecentLookups {
    public static let limit = 8
    static let key = "recentLookups"
    public private(set) var words: [String]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = defaults.stringArray(forKey: Self.key) ?? []
    }

    public func add(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        words = Array(([word] + words.filter { $0 != word }).prefix(Self.limit))
        defaults.set(words, forKey: Self.key)
    }

    public func clear() {
        words = []
        defaults.removeObject(forKey: Self.key)
    }
}
