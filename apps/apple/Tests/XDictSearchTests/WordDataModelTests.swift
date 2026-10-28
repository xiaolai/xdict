import Foundation
import Testing
import XDictClient
import XDictContract
import XDictSearch

/// **The word data Settings installs** (plan-word-exploration WI-5): the file in the container is attached at launch,
/// a chosen file is copied in and attached, a refusal deletes the copy and keeps the service's kind, and a removal
/// takes both the pack and the file.
@MainActor
struct WordDataModelTests {
    nonisolated static let pack = WordPackInfo(version: 2, language: "en", sources: ["oewn"], records: 1_488_719)

    /// A container of one test's own, with `file` in it when given.
    nonisolated static func container(_ tmp: URL, file: Data? = nil) -> URL {
        let folder = tmp.appending(path: "WordPack", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try? file.write(to: folder.appending(path: AppGroup.wordPackFile)) }
        return folder
    }

    nonisolated static func backend(_ answer: @escaping @Sendable (ServiceOperation) -> ClientOutcome) async
        -> FakeSearchBackend {
        let backend = FakeSearchBackend { _, _, _ in .failure(.wire(.interrupted)) }
        await backend.setAnswer(answer)
        return backend
    }

    nonisolated static func packaged(_ pack: WordPackInfo?) -> ClientOutcome {
        .success(Delivered(answer: .wordPacked(WordPackState(pack: pack)), payload: nil))
    }

    /// At launch the container's file is attached, because the service starts holding nothing: the row says installed.
    @Test func launchAttachesTheFileTheContainerHolds() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp, file: Data("{}\n".utf8))
        let backend = await Self.backend { operation in
            guard case .setWordPack = operation else { return Self.packaged(nil) }
            return Self.packaged(Self.pack)
        }
        let model = WordDataModel(backend: backend, container: { folder })
        await model.restore()
        #expect(model.state == .installed(Self.pack))
        #expect(await backend.requests == [
            .wordPack,
            .setWordPack(path: folder.appending(path: AppGroup.wordPackFile).path(percentEncoded: false)),
        ], "the service is asked first, and the file attached only because it held none")
    }

    /// Nothing in the container: the app asks what the service holds, and says absent when it holds nothing.
    @Test func launchWithoutAFileAsksWhatIsInstalled() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let backend = await Self.backend { _ in Self.packaged(nil) }
        let model = WordDataModel(backend: backend, container: { folder })
        await model.restore()
        #expect(model.state == .absent)
        #expect(await backend.requests == [.wordPack])
    }

    /// **A refused replacement leaves the installed pack alone** (audit, 2026-10-28): the chosen file is copied to a
    /// staging name and attached from there; only an accepted pack replaces the installed one. Before the fix the
    /// destination was deleted first, so a refused file permanently lost the pack the reader had.
    @Test func aRefusedFileIsCopiedInAttachedAndThenDeleted() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp, file: Data("installed\n".utf8))
        let chosen = tmp.appending(path: "chosen.jsonl")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: chosen)
        let backend = await Self.backend { _ in
            .failure(.wire(.core(.unsupported(feature: .formatVersion(version: "1"), detail: "damaged for the test"))))
        }
        let model = WordDataModel(backend: backend, container: { folder })
        await model.install(chosen)
        #expect(model.state == .refused(.version(found: "1")))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: AppGroup.wordPackFile)
            .path(percentEncoded: false)), "the installed pack survives a refused replacement")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(left == [AppGroup.wordPackFile], "only the installed pack is left: \(left)")
        let kept = try Data(contentsOf: folder.appending(path: AppGroup.wordPackFile))
        #expect(String(decoding: kept, as: UTF8.self) == "installed\n", "and it is the reader's old file, untouched")
    }

    /// Removing detaches the pack and deletes the file; a file left behind would be attached again at the next launch.
    @Test func removingDetachesAndDeletesTheFile() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp, file: Data("{}\n".utf8))
        let backend = await Self.backend { operation in
            guard case .clearWordPack = operation else { return Self.packaged(Self.pack) }
            return Self.packaged(nil)
        }
        let model = WordDataModel(backend: backend, container: { folder })
        await model.restore()
        #expect(model.state == .installed(Self.pack))
        await model.remove()
        #expect(model.state == .absent)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: AppGroup.wordPackFile)
            .path(percentEncoded: false)))
    }

    /// No container in this process: the row says so rather than pretending a folder of the app's own would do.
    @Test func noContainerIsSaidNotGuessedAround() async {
        let backend = await Self.backend { _ in Self.packaged(nil) }
        let model = WordDataModel(backend: backend, container: { nil })
        await model.install(URL(filePath: "/tmp/nothing.jsonl"))
        #expect(model.state == .trouble(.noContainer))
    }
}
