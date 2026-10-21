import Foundation
import Observation

/// **The reader's learning settings** (ADR-0023; plan-history-and-learning §2.7): the history's switch, the languages a
/// reading must be in to be **recorded**, and the languages the **drawer shows**. Recording and showing are independent
/// on purpose — a reader may keep everything and read one language, or keep one and read everything — and changing either
/// never rewrites or deletes what is stored.
@MainActor
@Observable
public final class LearningPreferences {
    public static let shared = LearningPreferences()

    private enum Key {
        static let history = "learning.history.enabled"
        static let targets = "learning.languages.targets"
        static let drawer = "learning.languages.drawer"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// **On for a new reader** (ADR-0023): a history that begins empty because the switch was never found is a failed
    /// feature; one click turns it off. Off means no reading is written at all — not the sentence, not the word.
    public var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.history) }
    }

    /// The languages a reading must be in to be written; **empty keeps every language** (D5). The core decides, so every
    /// shell filters alike; an unknown language is kept only while this is empty.
    public private(set) var targetLanguages: [String]

    /// The languages the drawer shows; **empty shows every stored reading**.
    public private(set) var drawerLanguages: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyEnabled = defaults.object(forKey: Key.history) as? Bool ?? true
        targetLanguages = defaults.stringArray(forKey: Key.targets) ?? []
        drawerLanguages = defaults.stringArray(forKey: Key.drawer) ?? []
    }

    public func setTargetLanguages(_ languages: [String]) {
        targetLanguages = Self.unique(languages)
        defaults.set(targetLanguages, forKey: Key.targets)
    }

    public func setDrawerLanguages(_ languages: [String]) {
        drawerLanguages = Self.unique(languages)
        defaults.set(drawerLanguages, forKey: Key.drawer)
    }

    /// Whether `language` is among the recording targets (always true while the set is empty).
    public func records(_ language: String) -> Bool {
        targetLanguages.isEmpty || targetLanguages.contains(language)
    }

    /// Whether the drawer shows `language` (always true while its set is empty).
    public func shows(_ language: String) -> Bool {
        drawerLanguages.isEmpty || drawerLanguages.contains(language)
    }

    static func unique(_ languages: [String]) -> [String] {
        languages.reduce(into: [String]()) { all, language in
            if !all.contains(language) { all.append(language) }
        }
    }
}
