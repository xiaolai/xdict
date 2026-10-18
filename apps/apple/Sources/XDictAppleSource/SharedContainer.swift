import Foundation
import Security
import XDictContract

/// **This process's own signing team**, read from its signature at run time, never written in the source (ADR-0011
/// decision 4). The app and the service both need it, to name the app-group container they share; the service also
/// builds its client requirement from it (`ClientCheck`).
public enum SigningTeam {
    public struct Unavailable: Error, CustomStringConvertible, Sendable {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// The `TeamIdentifier` of this process's own signature.
    public static func own() -> Result<String, Unavailable> {
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

/// **`<app-group container>/AppleImports/`, for this process** (ADR-0011 decisions 4 and 9), or nil: no team in the
/// signature, or no container for a process without the entitlement. Never a fallback folder.
public enum SharedContainer {
    public static func appleImports(team: Result<String, SigningTeam.Unavailable> = SigningTeam.own(),
                                    lookup: (String) -> URL? = {
                                        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
                                    }) -> URL? {
        guard case .success(let team) = team, let container = AppGroup.container(team: team, lookup: lookup) else {
            return nil
        }
        return AppGroup.appleImports(in: container)
    }

    /// `AppleImports/staging/`: the app's copies, each in a folder named by its UUID.
    public static func staging(in root: URL) -> URL {
        root.appending(path: "staging", directoryHint: .isDirectory)
    }
}
