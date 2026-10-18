import Foundation
import Testing
import XDictContract

/// **The app and its service share one app-group container** (ADR-0011 decision 4, amended 2026-10-18): its identifier
/// is the team's prefix and the app's bundle identifier, the team read at run time from the process's own signature,
/// never written in a tracked file.
struct AppGroupTests {
    @Test func theGroupIsTheTeamsPrefixAndTheAppsIdentifier() throws {
        #expect(AppGroup.identifier(team: "ABCDE12345") == "ABCDE12345.ai.xdict.app")
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] as? String == AppGroup.app, "the group's suffix is the app's identifier")
    }

    /// Only what Apple issues — ten upper-case letters and digits — becomes part of an identifier.
    @Test func aTeamApplePublishesNoSuchIdentifierForIsRefused() {
        for team in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE.1234", "ABCDE 1234", "ÄBCDE12345"] {
            #expect(AppGroup.identifier(team: team) == nil, "\(team.debugDescription)")
        }
    }

    @Test func theContainerIsWhatTheSystemAnswersForThatGroup() {
        let asked = AskedGroups()
        let found = AppGroup.container(team: "ABCDE12345") { group in
            asked.names.append(group)
            return URL(fileURLWithPath: "/tmp/group-\(group)")
        }
        #expect(asked.names == ["ABCDE12345.ai.xdict.app"])
        #expect(found?.path == "/tmp/group-ABCDE12345.ai.xdict.app")
        #expect(AppGroup.appleImports(in: URL(fileURLWithPath: "/g")).path == "/g/AppleImports")
    }

    /// No container (no entitlement, unsigned) or no valid team is no container: never a fallback folder.
    @Test func noContainerIsNil() {
        #expect(AppGroup.container(team: "ABCDE12345") { _ in nil } == nil)
        let asked = AskedGroups()
        #expect(AppGroup.container(team: "bad") { asked.names.append($0); return URL(fileURLWithPath: "/x") } == nil)
        #expect(asked.names.isEmpty, "an invalid team is never asked about")
    }
}

private final class AskedGroups {
    var names: [String] = []
}
