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

    nonisolated static func built(_ pack: WordPackInfo?) -> ClientOutcome {
        .success(Delivered(answer: .wordPackBuilt(WordPackState(pack: pack)), payload: nil))
    }

    /// A manifest of one pinned file, so a build can run without the network: the body's own size and SHA-256.
    nonisolated static func manifest(_ body: Data) -> Data {
        let json = """
        {"format":"xdict-word-lexicon-sources","version":2,"sources":[
         {"id":"a","provider":"cmudict","name":"A","url":"https://example.invalid/a.txt","version":"v1",\
        "sha256":"\(WordPackDownload.measure(of: body))","file":"a.txt","bytes":\(body.count),\
        "licence":"CC0-1.0","attribution":"The xdict tests","notice":"None"}]}
        """
        return Data(json.utf8)
    }

    /// A network inside the test: the one pinned file written straight to its place, reported as it lands.
    private struct LocalTransfer: WordPackTransfer {
        let body: Data

        func fetch(_ url: URL, to destination: URL, limit: UInt64,
                   written: @escaping @Sendable (Int64) -> Void) async throws {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: destination)
            written(Int64(body.count))
        }
    }

    /// Waits for the model's own state to reach what `condition` names, yielding to its main-actor updates; a state
    /// that never arrives fails the test rather than hanging it.
    @MainActor
    static func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("waiting for \(what) timed out")
    }

    /// The model on its way to a build: the container, the one-file manifest and a transfer, with no network.
    @MainActor
    static func buildingModel(
        _ folder: URL, backend: FakeSearchBackend, body: Data, manifest: Data
    ) -> WordDataModel {
        WordDataModel(backend: backend, container: { folder }, manifest: { manifest },
                      transfer: LocalTransfer(body: body))
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

    /// **The build's own progress becomes the row's state** (2026-10-31): a report of 42 of 100 bytes is a building
    /// phase with a determinate fraction — the thing the reader was missing while the pack built for minutes.
    @Test func theCoresBuildProgressIsADeterminateBarAndAPhase() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let body = Data("one".utf8)
        let manifest = Self.manifest(body)
        let backend = await Self.backend { _ in .failure(.wire(.interrupted)) }
        let gate = Slot()
        await backend.setProgressRequest { _, progress in
            progress(42, 100)
            return await gate.value()
        }
        let model = Self.buildingModel(folder, backend: backend, body: body, manifest: manifest)
        let build = Task { await model.buildFromSources() }
        await Self.waitUntil("the core's first report") { model.phase == .building }
        #expect(model.fraction.map { abs($0 - 0.42) < 0.000_001 } == true,
                "42 of 100 bytes is a determinate bar: \(String(describing: model.fraction))")
        #expect(model.phase == .building)
        let progressRequests = await backend.progressRequests
        #expect(progressRequests.count == 1, "the build was asked with a progress listener")
        gate.fulfil(Self.built(Self.pack))
        await build.value
        #expect(model.state == .installed(Self.pack))
        #expect(model.phase == nil, "nothing is under way once the pack is installed")
    }

    /// **A build that reports nothing yet still says what it is doing**: the core checks the downloaded sources before
    /// it parses one, and with no amount the row names the phase and draws a moving bar rather than a bar at zero.
    @Test func aBuildWithNoReportsStillNamesItsPhase() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let body = Data("one".utf8)
        let manifest = Self.manifest(body)
        let backend = await Self.backend { _ in .failure(.wire(.interrupted)) }
        let gate = Slot()
        await backend.setProgressRequest { _, _ in await gate.value() }
        let model = Self.buildingModel(folder, backend: backend, body: body, manifest: manifest)
        let build = Task { await model.buildFromSources() }
        await Self.waitUntil("the build to start") {
            if case .building = model.state { true } else { false }
        }
        #expect(model.phase == .preparing, "no bytes parsed yet: the sources are being checked or the first parsed")
        #expect(model.fraction == nil, "no amount is known, so no bar at zero")
        gate.fulfil(Self.built(Self.pack))
        await build.value
        #expect(model.state == .installed(Self.pack))
    }

    /// **Every source parsed is the writing phase, not a bar frozen full**: the core reports the last byte parsed
    /// before it writes the pack, and the row says what it is doing there instead of drawing a finished bar.
    @Test func aFinishedParseIsTheWritingPhase() {
        #expect(WordDataBuild(done: 100, total: 100).phase == .writing)
        #expect(WordDataBuild(done: 100, total: 100).fraction == nil)
        #expect(WordDataBuild().phase == .preparing)
        #expect(WordDataBuild().fraction == nil)
        #expect(WordDataProgress(file: 1, files: 2, done: 0, total: 10).fraction == nil)
    }

    /// **A source that fails mid-build is said where the progress was**, with the builder's own sentence naming the
    /// file and the line — never a silent return to the absent row.
    @Test func aRefusedBuildShowsTheSourcesSentence() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let body = Data("one".utf8)
        let manifest = Self.manifest(body)
        let backend = await Self.backend { _ in .failure(.wire(.interrupted)) }
        await backend.setProgressRequest { _, _ in
            .failure(.wire(.core(.malformed(detail: "oewn: line 12: an undeclared synset"))))
        }
        let model = Self.buildingModel(folder, backend: backend, body: body, manifest: manifest)
        await model.buildFromSources()
        #expect(model.state == .refused(.build(detail: "oewn: line 12: an undeclared synset")))
        #expect(model.phase == nil, "the failure's sentence takes the place of the progress")
    }

    /// A network that never delivers: the download waits until it is cancelled.
    private struct StalledTransfer: WordPackTransfer {
        func fetch(_ url: URL, to destination: URL, limit: UInt64,
                   written: @escaping @Sendable (Int64) -> Void) async throws {
            try await Task.sleep(for: .seconds(60))
        }
    }

    nonisolated static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// **A cancelled build asks what is installed** (M8): the service may hold a pack from before the build, and a
    /// row set to absent by assumption hid it and offered a build over it. The download cache goes with the cancel.
    @Test func aCancelledBuildRereadsWhatTheServiceHolds() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let body = Data("one".utf8)
        let backend = await Self.backend { _ in Self.packaged(Self.pack) }
        // The re-read must not be asked from inside the cancelled build: a backend may refuse a cancelled caller.
        await backend.refuseCancelledCallers()
        let model = WordDataModel(backend: backend, container: { folder }, manifest: { Self.manifest(body) },
                                  transfer: StalledTransfer())
        let build = Task { await model.buildFromSources() }
        await Self.waitUntil("the download to start") {
            if case .downloading = model.state { true } else { false }
        }
        model.cancelBuild()
        await build.value
        #expect(model.state == .installed(Self.pack), "the pack the service holds, not an assumed absence")
        #expect(await backend.requests == [.wordPack])
        #expect(!Self.exists(folder.appending(path: "sources")), "the download cache goes with the cancel")
    }

    /// **The download cache goes once the build has answered** (M8), installed or refused: it is about 185 MB that
    /// only that build reads, and the next build downloads every file again.
    @Test(arguments: [true, false])
    func theDownloadCacheGoesWhenTheBuildAnswers(accepted: Bool) async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let body = Data("one".utf8)
        let backend = await Self.backend { _ in Self.packaged(nil) }
        await backend.setProgressRequest { _, _ in
            accepted ? Self.built(Self.pack) : .failure(.wire(.core(.malformed(detail: "a: line 1: refused"))))
        }
        let model = Self.buildingModel(folder, backend: backend, body: body, manifest: Self.manifest(body))
        await model.buildFromSources()
        #expect(model.state == (accepted ? .installed(Self.pack) : .refused(.build(detail: "a: line 1: refused"))))
        #expect(!Self.exists(folder.appending(path: "sources")), "no source is left behind")
    }

    /// **A refused file leaves the installed pack named and removable** (M8): the core keeps the pack it held, so the
    /// model asks for it after the refusal and keeps it beside the refusal's sentence.
    @Test func aRefusedInstallStillKnowsThePackItKept() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp, file: Data("installed\n".utf8))
        let chosen = tmp.appending(path: "chosen.jsonl")
        try Data("{}\n".utf8).write(to: chosen)
        let backend = await Self.backend { operation in
            guard case .setWordPack = operation else { return Self.packaged(Self.pack) }
            return .failure(.wire(.core(.unsupported(feature: .formatVersion(version: "1"), detail: "old"))))
        }
        let model = WordDataModel(backend: backend, container: { folder })
        await model.restore()
        await model.install(chosen)
        #expect(model.state == .refused(.version(found: "1")), "the refusal is what the row says")
        #expect(model.held == Self.pack, "and the pack still attached is known beside it")
        let staged = folder.appending(path: AppGroup.wordPackFile + ".incoming").path(percentEncoded: false)
        #expect(await backend.requests == [.wordPack, .setWordPack(path: staged), .wordPack],
                "the service is asked again after the refusal")
    }

    /// **An install waits for the operation before it** (M8): an attach started while a build was running answered
    /// first and was then replaced by the build's pack, and a restore's question superseded an install's attach so
    /// an accepted install deleted its own file. One at a time, the install runs after the build has answered.
    @Test func anInstallWaitsForTheBuildBeforeIt() async throws {
        let tmp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = Self.container(tmp)
        let chosen = tmp.appending(path: "chosen.jsonl")
        try Data("{}\n".utf8).write(to: chosen)
        let body = Data("one".utf8)
        let other = WordPackInfo(version: 2, language: "en", sources: ["chosen"], records: 1)
        let backend = await Self.backend { _ in Self.packaged(other) }
        let gate = Slot()
        await backend.setProgressRequest { _, _ in await gate.value() }
        let model = Self.buildingModel(folder, backend: backend, body: body, manifest: Self.manifest(body))
        let build = Task { await model.buildFromSources() }
        await Self.waitUntil("the build to start") {
            if case .building = model.state { true } else { false }
        }
        let install = Task { await model.install(chosen) }
        // Long enough for an install that does not wait to copy a two-byte file and ask the service.
        for _ in 0..<50 {
            if await !backend.requests.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await backend.requests.isEmpty, "nothing is attached while the build is running")
        gate.fulfil(Self.built(Self.pack))
        await build.value
        await install.value
        let staged = folder.appending(path: AppGroup.wordPackFile + ".incoming").path(percentEncoded: false)
        #expect(await backend.requests == [.setWordPack(path: staged)])
        #expect(model.state == .installed(other), "the later operation's answer is the one shown")
        #expect(Self.exists(folder.appending(path: AppGroup.wordPackFile)), "the accepted file is installed")
    }
}
