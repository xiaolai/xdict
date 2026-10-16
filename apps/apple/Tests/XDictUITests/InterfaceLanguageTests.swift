import Foundation
import Testing
import XDictUI

/// **The UI follows the system's language unless the reader picks one** (plan-macos-v1 WI-9): the choice is the app's
/// own `AppleLanguages`, read by the system at the next launch; "the system's" removes it rather than writing one.
struct InterfaceLanguageTests {
    @Test func aChoiceIsWrittenAndReadBack() throws {
        let domain = "xdict.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(InterfaceLanguage.current(in: defaults, domain: domain) == .system)
        InterfaceLanguage.simplifiedChinese.apply(to: defaults)
        #expect(defaults.array(forKey: InterfaceLanguage.key) as? [String] == ["zh-Hans"])
        #expect(InterfaceLanguage.current(in: defaults, domain: domain) == .simplifiedChinese)
        InterfaceLanguage.english.apply(to: defaults)
        #expect(InterfaceLanguage.current(in: defaults, domain: domain) == .english)
        InterfaceLanguage.system.apply(to: defaults)
        #expect(defaults.persistentDomain(forName: domain)?[InterfaceLanguage.key] == nil)
        #expect(InterfaceLanguage.current(in: defaults, domain: domain) == .system)
    }

    /// A language XDict does not ship, set some other way, reads as the system's.
    @Test func anUnknownLanguageReadsAsTheSystems() throws {
        let domain = "xdict.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["fr"], forKey: InterfaceLanguage.key)
        #expect(InterfaceLanguage.current(in: defaults, domain: domain) == .system)
    }

    /// Each choice names itself in its own language, so a reader who cannot read the other one can still find theirs.
    @Test func eachChoiceHasAName() {
        let names = Set(InterfaceLanguage.allCases.map { String(localized: $0.name) })
        #expect(names.count == InterfaceLanguage.allCases.count)
    }
}
