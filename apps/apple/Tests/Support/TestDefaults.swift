import Foundation
import Testing

/// **A preferences suite of one test's own, removed when the fixture goes** (audit findings, 2026-10-25): a generated
/// name keeps one test out of another's values, the removal keeps the test process from filling with domains, and a name
/// the system refuses stops the test instead of silently writing the reader's own defaults — the `?? .standard` fallback
/// this replaces did exactly that, and five suites still carried it when the Settings audit's own were fixed.
public final class TestDefaults {
    public let suite: String
    public let database: UserDefaults

    public init(prefix: String = "ai.xdict.tests") throws {
        suite = prefix + "." + UUID().uuidString
        database = try #require(UserDefaults(suiteName: suite), "a generated suite name was refused: \(suite)")
        database.removePersistentDomain(forName: suite)
    }

    deinit { database.removePersistentDomain(forName: suite) }
}

/// **A test's own defaults suite, held where a helper can keep it**: a struct's test methods cannot assign their own
/// properties, and the fixture must outlive the helper that made it.
public final class HeldDefaults {
    public var fixture: TestDefaults?

    public init() {}
}
