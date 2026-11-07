import Foundation
import Testing
import XDictAI
@testable import XDictUI

/// **The two command-line sources say the same thing for the same facts** (audit 2026-11-05 L15): each check proves the
/// program, its version and XDict's own folders, and neither proves that the account behind it will answer — only an
/// ask does. Codex was labelled Ready and Claude Code Configured for that same proof.
struct MeaningSourceStatusTests {
    /// One mapping, which no longer knows which program it was: the same facts cannot say two things.
    @Test func aPassedCheckIsConfiguredForEitherCLI() {
        #expect(MeaningProviders.cliStatus(.success("1.2.3")) == .configured("1.2.3"))
    }

    @Test func aFailedCheckIsTheSameFailureForEitherCLI() {
        #expect(MeaningProviders.cliStatus(.failure(.notInstalled)) == .failed(.notInstalled))
    }
}
