import Foundation
import Security
import XDictBase

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
        guard team.count == 10, team.allSatisfy({ ($0.isASCII && $0.isUppercase) || ($0.isASCII && $0.isNumber) }) else {
            return .refuseAll(why: "the signature's team identifier is not one Apple issues: \(team.debugDescription)")
        }
        return .requirement("anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\"")
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// The `TeamIdentifier` of this process's own signature.
    static func ownTeam() -> Result<String, Unavailable> {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return .failure(Unavailable(description: "SecCodeCopySelf failed"))
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return .failure(Unavailable(description: "SecCodeCopyStaticCode failed"))
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let signing = information as? [String: Any] else {
            return .failure(Unavailable(description: "SecCodeCopySigningInformation failed: \(status)"))
        }
        guard let team = signing[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return .failure(Unavailable(description: "this process's signature names no team"))
        }
        return .success(team)
    }
}
