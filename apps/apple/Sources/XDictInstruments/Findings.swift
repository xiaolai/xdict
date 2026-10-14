import Foundation

/// One named check of an instrument's run, and what it saw.
public struct Check: Codable, Hashable, Sendable {
    public let name: String
    public let pass: Bool
    public let detail: String
}

/// **What a scenario found**: its checks, each passed or not, and the facts it measured. Printed as JSON by the app's
/// instruments and read by the E2E `service` stage, which requires every check it knows by name: a scenario that
/// stopped early leaves a name missing, never a run that reads as clean.
public struct Findings: Codable, Sendable {
    public private(set) var checks: [Check] = []
    public private(set) var facts: [String: String] = [:]

    public init() {}

    public mutating func check(_ name: String, _ pass: Bool, _ detail: String) {
        checks.append(Check(name: name, pass: pass, detail: detail))
    }

    public mutating func fact(_ name: String, _ value: String) {
        facts[name] = value
    }

    public mutating func merge(_ other: Findings) {
        checks += other.checks
        facts.merge(other.facts) { $1 }
    }

    /// Every check passed, and there was at least one.
    public var passed: Bool {
        !checks.isEmpty && checks.allSatisfy(\.pass)
    }

    public var failed: [Check] {
        checks.filter { !$0.pass }
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Milliseconds of a duration, for facts.
func milliseconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.1f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
}
