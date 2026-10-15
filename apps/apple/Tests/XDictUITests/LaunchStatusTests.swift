import Foundation
import Testing
import XDictBase
import XDictUI

/// What the main window says about the handshake: one sentence per outcome, each its own. Read here in the source language; the catalog's completeness in both languages is
/// `StringCatalogTests`'.
struct LaunchStatusTests {
    @Test func askingSaysSo() {
        #expect(String(localized: LaunchStatus.asking.headline) == "Asking the dictionary service…")
    }

    @Test func anAnswerSaysSo() {
        let status = LaunchStatus.answered(CoreVersions(protocolVersion: 1, core: "0.0.1", indexFormat: 2, normalization: 1))
        #expect(String(localized: status.headline) == "The dictionary service answered.")
    }

    /// A reader told "it failed" cannot tell a service that is slow from one that is missing; each failure is its
    /// own sentence.
    @Test func eachFailureHasItsOwnSentence() {
        let failures: [HandshakeFailure] = [
            .timedOut(after: .seconds(10)), .unreachable("x"), .refused("x"), .unreadable("x"),
        ]
        let sentences = failures.map { String(localized: LaunchStatus.failed($0).headline) }
        #expect(Set(sentences).count == failures.count, "\(sentences)")
        #expect(!sentences.contains(String(localized: LaunchStatus.asking.headline)))
    }
}
