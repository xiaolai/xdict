import Foundation
import Testing
import XDictClient
import XDictContract
import XDictLibrary

/// **A file XDict cannot read is refused with a reason, never skipped** (AGENTS.md; GoldenDict-ng #2890). Every typed
/// failure the client can deliver maps to one kind the view layer words; permanent ones (the file itself) are told
/// apart from passing ones (the service), which offer a retry.
struct ImportRefusalTests {
    let file = UUID()
    func name(_ id: UUID) -> String? { id == file ? "a.mdx" : nil }

    func refusal(_ failure: CoreFailure) -> ImportRefusal {
        ImportRefusal(.wire(.core(failure)), fileName: name)
    }

    @Test func theFilesOwnRefusalsAreNamedAndPermanent() {
        let cases: [(CoreFailure, ImportRefusal)] = [
            (.unsupported(feature: .resourceLibraryV3, detail: ""), .resourceLibraryV3),
            (.unsupported(feature: .registrationCode, detail: ""), .registrationCode),
            (.unsupported(feature: .formatVersion(version: "4.0"), detail: ""), .formatVersion("4.0")),
            (.unsupported(feature: .encryptionFlags(flags: 3), detail: ""), .encrypted),
            (.unsupported(feature: .blockEncryption(code: 2), detail: ""), .encrypted),
            (.unsupported(feature: .lzoInV3, detail: ""), .compression),
            (.unsupported(feature: .compressionType(code: 7), detail: ""), .compression),
            (.unsupported(feature: .encoding(name: "KOI8-R"), detail: ""), .encoding("KOI8-R")),
            (.malformed(detail: "header checksum"), .damaged),
            (.tooLarge(limit: .file, detail: ""), .tooLarge),
        ]
        for (failure, expected) in cases {
            #expect(refusal(failure) == expected)
            #expect(expected.isPermanent, "\(expected)")
        }
    }

    @Test func passingFailuresOfferARetry() {
        let passing: [ClientFailure] = [
            .wire(.interrupted), .wire(.invalidated), .wire(.timedOut(deadline: .seconds(1))),
            .wire(.undecodable(detail: "")), .wire(.contractMismatch(service: 3, client: 2)),
            .wire(.refused(.tooManyInFlight)), .wire(.core(.internalFault(detail: ""))),
            .wire(.core(.io(kind: .other, detail: ""))), .wire(.core(.staleHandle(detail: ""))),
        ]
        for failure in passing {
            #expect(ImportRefusal(failure, fileName: name) == .serviceFailed, "\(failure)")
        }
        #expect(!ImportRefusal.serviceFailed.isPermanent)
        #expect(refusal(.sourceChanged(detail: "")) == .changedDuringImport)
        #expect(refusal(.cancelled(detail: "")) == .cancelled)
        #expect(!ImportRefusal.cancelled.isPermanent && !ImportRefusal.changedDuringImport.isPermanent)
    }

    @Test func aFileThatCannotBeOpenedIsNamed() {
        #expect(ImportRefusal(.fileUnavailable(file: file, errno: ENOENT), fileName: name) == .missingFile("a.mdx"))
        #expect(ImportRefusal(.fileUnavailable(file: file, errno: EACCES), fileName: name) == .unreadable("a.mdx"))
        #expect(ImportRefusal(.fileUnavailable(file: UUID(), errno: ENOENT), fileName: name) == .missingFile(""))
        #expect(!ImportRefusal.missingFile("a.mdx").isPermanent)
    }

    /// What the client refuses to open (the security review of 2026-10-15) is said as what it is, not as a file the
    /// reader may not read: a link in the file's place or above it (`ELOOP`), a folder or a pipe there (`EFTYPE`).
    @Test func somethingElseInAFilesPlaceIsNamedAsThat() {
        #expect(ImportRefusal(.fileUnavailable(file: file, errno: ELOOP), fileName: name) == .notAFile("a.mdx"))
        #expect(ImportRefusal(.fileUnavailable(file: file, errno: EFTYPE), fileName: name) == .notAFile("a.mdx"))
        #expect(!ImportRefusal.notAFile("a.mdx").isPermanent, "the reader can put the file back")
    }
}
