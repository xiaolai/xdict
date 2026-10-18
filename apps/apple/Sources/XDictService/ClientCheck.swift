import Foundation
import XDictAppleSource
import XDictBase
import XDictContract

/// **Who may talk to this service** (ADR-0009, refutation objection 6, as the owner amended it on 2026-10-14: the
/// boundary is input and output). An embedded XPC service is reachable by name only from its own app; on top of that,
/// every connection carries a code-signing requirement — the app's identifier, signed by this service's own team — that
/// NSXPC enforces before a message is delivered.
///
/// **The team is read from the service's own signature at run time**, never written in the source: the same tree signed
/// by another team requires that team. A service that cannot read a team (unsigned, ad hoc) **accepts no one**: failing
/// closed, since a requirement it could not build is not a requirement relaxed.
enum ClientCheck: Sendable, Equatable {
    /// NSXPC holds every connection to this requirement.
    case requirement(String)
    /// No requirement could be built; every connection is refused, and why is logged.
    case refuseAll(why: String)
    #if DEBUG
    /// The in-process tests' anonymous listeners, whose client is the unsigned test runner. Not in a release build, so
    /// the shipped service cannot be built to accept anyone.
    case anyoneForTests
    #endif

    /// The requirement for the app signed by the team that signed this process (`team`: this process's own, read from
    /// its signature).
    static func ownTeamApp(team: Result<String, Unavailable> = ownTeam()) -> ClientCheck {
        switch team {
        case .success(let team): requirement(team: team, app: XDictIdentity.app)
        case .failure(let why): .refuseAll(why: why.description)
        }
    }

    /// The requirement text, for a team identifier that is exactly what Apple issues (ten upper-case letters and
    /// digits) — anything else is refused rather than spliced into the requirement language.
    static func requirement(team: String, app: String) -> ClientCheck {
        guard AppGroup.isTeamIdentifier(team) else {
            return .refuseAll(why: "the signature's team identifier is not one Apple issues: \(team.debugDescription)")
        }
        return .requirement("anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\"")
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// The `TeamIdentifier` of this process's own signature (`SigningTeam`, shared with the app, which names the same
    /// app-group container by it).
    static func ownTeam() -> Result<String, Unavailable> {
        SigningTeam.own().mapError { Unavailable(description: $0.description) }
    }
}
