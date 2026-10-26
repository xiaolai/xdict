import Foundation
import Testing
import XDictContract
import XDictTestSupport
@testable import XDictService

/// **The token ledger stays a ledger, not a history** (audit rounds 1–4, 2026-10-26): every file the reader ever imported
/// left a token for the process's life. It is capped by recency now, the files of open dictionaries always kept, and an
/// evicted token fails a read closed — the core refuses a source the service cannot vouch for, never trusts it.
struct DictionariesLedgerTests {
    private func dictionaries(_ directory: TemporaryDirectory) -> Dictionaries {
        Dictionaries(storage: Dictionaries.Storage(indexes: directory.appending("indexes"),
                                                   registry: directory.appending("registry")))
    }

    @Test func theTokenLedgerKeepsItsCeilingAndTheNewest() throws {
        let directory = try TemporaryDirectory(named: "xdict-token-ledger")
        let dictionaries = dictionaries(directory)
        let files = (0..<(Dictionaries.tokenCeiling + 10)).map { _ in UUID() }
        for (index, file) in files.enumerated() {
            dictionaries.observe([FileToken(file: file, observed: UInt64(index), state: .missing)])
        }
        #expect(dictionaries.tokenCount == Dictionaries.tokenCeiling)
        #expect(dictionaries.token(of: files[files.count - 1]) == .missing, "the newest observation was evicted")
        #expect(dictionaries.token(of: files[0]) == nil, "the oldest observation was kept")
    }
}
