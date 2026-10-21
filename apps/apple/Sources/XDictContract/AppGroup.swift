import Foundation

/// **The app-group container the app and its dictionary service share** (ADR-0011 decision 4, amended 2026-10-18): the
/// app copies an Apple dictionary bundle into it, byte for byte, and the service converts it there. Both binaries carry
/// `com.apple.security.application-groups` with the group `<team>.ai.xdict.app`, which macOS grants an app and its
/// helpers with no prompt. **The team is read at run time** from the process's own signature (`ClientCheck` in the
/// service), never written in the source: the entitlements say `$(TeamIdentifierPrefix)`, expanded at signing from the
/// signing identity (`Tools/expand-entitlements.sh`). In the contract because it is what both processes agree on, as
/// the JSON is; the contract stands alone, so the app's identifier is written here, and `AppGroupTests` holds it to the
/// bundle's (`XDictIdentity.app`, ADR-0001).
public enum AppGroup {
    /// The app's bundle identifier, the group's suffix.
    public static let app = "ai.xdict.app"

    /// The group for `team`, or nil unless `team` is exactly what Apple issues: ten upper-case ASCII letters and digits.
    public static func identifier(team: String) -> String? {
        guard isTeamIdentifier(team) else { return nil }
        return "\(team).\(app)"
    }

    /// Ten upper-case ASCII letters and digits: what Apple issues as a team identifier, and nothing else is spliced into
    /// an identifier or a code requirement.
    public static func isTeamIdentifier(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    /// The group's container, as the system answers for it (`lookup`, a seam for tests), or nil: no valid team, or no
    /// container for a process without the entitlement. Never a fallback folder.
    public static func container(team: String, lookup: (String) -> URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }) -> URL? {
        guard let group = identifier(team: team) else { return nil }
        return lookup(group)
    }

    /// Where Apple dictionary conversions live in the container: `staging/<uuid>/` for snapshots the app copied,
    /// `<conversion uuid>/` for what the service published (ADR-0011 decision 9).
    public static func appleImports(in container: URL) -> URL {
        container.appending(path: "AppleImports", directoryHint: .isDirectory)
    }

    /// **Where one sync pass's files meet** (plan §2.6): the app copies the reader's folder's logs into `Sync/in` — the
    /// service's sandbox cannot read that folder — the service merges them and writes this device's log to `Sync/out`,
    /// and the app copies it back. Both processes hold the group.
    public static func sync(in container: URL) -> URL {
        container.appending(path: "Sync", directoryHint: .isDirectory)
    }
}
