import Foundation
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **Who may talk to the service**: a code-signing requirement built from the service's own signature and set on every
/// connection, and no connection at all when none can be built (ADR-0009, refutation 6 as the owner amended it).
struct ClientCheckTests {
    @Test func theRequirementNamesTheAppAndTheTeam() {
        #expect(ClientCheck.requirement(team: "ABCDE12345", app: "ai.xdict.app") == .requirement(
            #"anchor apple generic and identifier "ai.xdict.app" and certificate leaf[subject.OU] = "ABCDE12345""#))
    }

    /// A team that is not ten upper-case letters and digits is never spliced into the requirement language.
    @Test func aTeamThatIsNotApplesShapeRefusesEveryone() {
        for team in ["", "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCDE"1234"#, "ABCDE 1234"] {
            guard case .refuseAll = ClientCheck.requirement(team: team, app: "ai.xdict.app") else {
                Issue.record("\(team.debugDescription) made a requirement")
                continue
            }
        }
    }

    /// **Failing closed**: a service whose signature names no team (unsigned, ad hoc) builds no requirement and refuses
    /// every client, rather than accepting any.
    @Test func noTeamRefusesEveryone() {
        guard case .refuseAll = ClientCheck.ownTeamApp(team: .failure(.init(description: "no team"))) else {
            Issue.record("a service without a team accepted clients")
            return
        }
        #expect(ClientCheck.ownTeamApp(team: .success("ABCDE12345")) == ClientCheck.requirement(team: "ABCDE12345",
                                                                                                 app: "ai.xdict.app"))
    }

    /// A refused client gets no reply, only the connection's end: `interrupted` here, as the spike saw for a refused
    /// message (`NSCocoaErrorDomain 4097`), or `invalidated` (refused by name, as the E2E `service` stage's outside
    /// program is).
    static func refused(_ answer: Result<Versions, ClientFailure>) -> Bool {
        answer == .failure(.wire(.interrupted)) || answer == .failure(.wire(.invalidated))
    }

    /// **The requirement is set on the connection**: one this test's own process cannot satisfy refuses its first message
    /// before the service reads it. Red with `setCodeSigningRequirement` removed.
    @Test func aClientOutsideTheRequirementIsRefused() async throws {
        let harness = try ServiceHarness(check: .requirement(#"identifier "ai.xdict.app" and anchor apple generic"#))
        let answer = await harness.client().versions()
        #expect(Self.refused(answer), "\(answer)")
        // The control: the same service without a requirement answers this process.
        #expect(await (try ServiceHarness()).client().versions().map { _ in true } == .success(true))
    }

    @Test func aServiceThatRefusesEveryoneAnswersNoOne() async throws {
        let harness = try ServiceHarness(check: .refuseAll(why: "test"))
        let answer = await harness.client().versions()
        #expect(Self.refused(answer), "\(answer)")
    }

    /// The service starts only in its own sandbox container: outside it, it would write into the user's Library.
    @Test func storageIsTheSandboxContainersOnly() {
        #expect(ServiceContext.containerStorage(environment: [:]) == nil)
        #expect(ServiceContext.containerStorage(environment: ["APP_SANDBOX_CONTAINER_ID": "ai.xdict.spike.DictionaryService"]) == nil)
        let storage = ServiceContext.containerStorage(environment: ["APP_SANDBOX_CONTAINER_ID": "ai.xdict.app.DictionaryService"])
        #expect(storage?.indexes.lastPathComponent == "indexes")
        #expect(storage?.registry.lastPathComponent == "registry")
    }
}
