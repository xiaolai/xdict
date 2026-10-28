import Foundation
import Testing
@testable import XDictSearch

/// The fixture bytes, and the hashes the manifest pins them to.
private let oneBytes = Data("one".utf8)
private let twoBytes = Data("two".utf8)
private let tamperedBytes = Data("tampered".utf8)
private let oneSha = "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed"
private let twoSha = "3fc4ccfe745870e2c0d99f71f30ff0656c8dedd41cc1d7d3d376b0dbe685e2f3"

/// A manifest as the app ships one: two pinned files, each with its URL, size and hash.
private func manifest(one: String = oneSha, two: String = twoSha, twoSize: Int = twoBytes.count) -> Data {
    let json = """
    {"format":"xdict-word-lexicon-sources","version":2,"sources":[
     {"id":"a","provider":"cmudict","name":"A","url":"https://example.invalid/one.txt","version":"v1",\
    "sha256":"\(one)","file":"one.txt","bytes":\(oneBytes.count),"licence":"CC0-1.0",\
    "attribution":"The xdict tests","notice":"None"},
     {"id":"b","provider":"cmudict","name":"B","url":"https://example.invalid/two.txt","version":"v1",\
    "sha256":"\(two)","file":"two.txt","bytes":\(twoSize),"licence":"CC0-1.0",\
    "attribution":"The xdict tests","notice":"None"}]}
    """
    return Data(json.utf8)
}

/// A network that answers with whatever it is given, by the file's name.
private struct FakeTransfer: WordPackTransfer {
    let bodies: [String: Data]
    func fetch(_ url: URL, to destination: URL, written: @escaping @Sendable (Int64) -> Void) async throws {
        guard let body = bodies[url.lastPathComponent] else { throw URLError(.badURL) }
        try body.write(to: destination)
        written(Int64(body.count))
    }
}

/// A network that stops after `limit` files, as a cancel does.
private final class StoppingTransfer: WordPackTransfer, @unchecked Sendable {
    init(bodies: [String: Data], limit: Int) {
        self.bodies = bodies
        self.limit = limit
    }

    private let bodies: [String: Data]
    private let limit: Int
    private var seen = 0

    func fetch(_ url: URL, to destination: URL, written: @escaping @Sendable (Int64) -> Void) async throws {
        seen += 1
        if seen > limit { throw CancellationError() }
        guard let body = bodies[url.lastPathComponent] else { throw URLError(.badURL) }
        try body.write(to: destination)
        written(Int64(body.count))
    }
}

/// What the progress reports said, collected off the download's own thread.
private final class Reports: @unchecked Sendable {
    var items: [(file: Int, done: UInt64, total: UInt64)] = []
}

/// **The download the app runs before a build** (plan-local-word-pack WI-6): every pinned file is fetched, checked
/// against the manifest's size and SHA-256, and — when anything is wrong — **nothing is left behind for a build to
/// read**. The network is faked, so what is proved here is the checking, not the transport.
struct WordPackDownloadTests {
    static func folder() -> URL {
        let root = URL.temporaryDirectory.appending(path: "xdict-pack-download-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func everyPinnedFileIsWrittenAndVerified() async throws {
        let sources = try #require(WordPackSources(manifest()))
        #expect(sources.items.count == 2, "the manifest's two downloads")
        #expect(sources.totalBytes == UInt64(oneBytes.count + twoBytes.count), "the total is every file's size")
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = Reports()
        try await WordPackDownload(sources: sources, transfer: FakeTransfer(bodies: ["one.txt": oneBytes,
                                                                                    "two.txt": twoBytes]))
            .fetch(into: folder) { file, done, total in reports.items.append((file, done, total)) }
        #expect(try Data(contentsOf: folder.appending(path: "one.txt")) == oneBytes)
        #expect(try Data(contentsOf: folder.appending(path: "two.txt")) == twoBytes)
        #expect(reports.items.last?.done == sources.totalBytes, "the last report is the whole download")
        #expect(reports.items.map(\.file).max() == 2, "both files are named")
    }

    @Test func aSubstitutedFileIsRefusedByNameAndNothingIsLeft() async throws {
        // The size the manifest pins is the substituted file's own, so only the hash can catch this one.
        let sources = try #require(WordPackSources(manifest(twoSize: tamperedBytes.count)))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transfer = FakeTransfer(bodies: ["one.txt": oneBytes, "two.txt": tamperedBytes])
        do {
            try await WordPackDownload(sources: sources, transfer: transfer).fetch(into: folder) { _, _, _ in }
            Issue.record("a substituted file was accepted")
        } catch let failure as WordPackDownload.Failure {
            #expect(failure == .hashMismatch(file: "two.txt", expected: twoSha,
                                             found: WordPackDownload.measure(of: tamperedBytes)))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "one.txt").path),
                "the good file goes too: nothing half a pack is left")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "two.txt").path))
    }

    @Test func aWrongSizeIsRefusedByNameAndNothingIsLeft() async throws {
        // The manifest pins the tampered bytes' own hash, so only the size can catch this one.
        let sources = try #require(WordPackSources(manifest(two: WordPackDownload.measure(of: tamperedBytes))))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transfer = FakeTransfer(bodies: ["one.txt": oneBytes, "two.txt": tamperedBytes])
        do {
            try await WordPackDownload(sources: sources, transfer: transfer).fetch(into: folder) { _, _, _ in }
            Issue.record("a wrong-sized file was accepted")
        } catch let failure as WordPackDownload.Failure {
            #expect(failure == .sizeMismatch(file: "two.txt", expected: UInt64(twoBytes.count),
                                             found: UInt64(tamperedBytes.count)))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "two.txt").path))
    }

    @Test func aCancelLeavesNothingBehind() async throws {
        let sources = try #require(WordPackSources(manifest()))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transfer = StoppingTransfer(bodies: ["one.txt": oneBytes, "two.txt": twoBytes], limit: 1)
        do {
            try await WordPackDownload(sources: sources, transfer: transfer).fetch(into: folder) { _, _, _ in }
            Issue.record("a cancelled download finished")
        } catch is CancellationError {
            // Expected: the second file never starts.
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "one.txt").path),
                "a cancelled download writes nothing")
    }

    /// **The production transport, against the real endpoint** (opt-in): `XDICT_WORD_PACK_NETWORK=1` fetches the 1,740
    /// byte WNDB notice from upstream and checks the hash the manifest pins. Everything else here fakes the network,
    /// so this is the one test that proves `URLSessionTransfer` itself. Off by default: a suite that reaches the
    /// network is not a suite anyone can run on a train.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XDICT_WORD_PACK_NETWORK"] == "1"))
    func theProductionTransportFetchesAPinnedFile() async throws {
        let url = try #require(URL(string:
            "https://raw.githubusercontent.com/globalwordnet/english-wordnet/2025-edition/WNDB_License.txt"))
        let item = WordPackSources.Item(file: "oewn-WNDB_License.txt", url: url,
                                        sha256: "df30ec18fbabcdaf031b79ea026d3e6b959010cffe6dd7be9ac137822175b904",
                                        bytes: 1740)
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await WordPackDownload(sources: WordPackSources(items: [item])).fetch(into: folder) { _, _, _ in }
        let written = try Data(contentsOf: folder.appending(path: item.file))
        #expect(written.count == 1740)
        #expect(WordPackDownload.measure(of: written) == item.sha256)
    }

    @Test func aManifestThatNamesAFileTwiceIsNotRead() {
        let doubled = """
        {"sources":[{"file":"a.txt","url":"https://example.invalid/a.txt","sha256":"\(oneSha)","bytes":3},
                    {"file":"a.txt","url":"https://example.invalid/a.txt","sha256":"\(oneSha)","bytes":3}]}
        """
        #expect(WordPackSources(Data(doubled.utf8)) == nil, "a manifest naming one file twice is refused")
        #expect(WordPackSources(Data("not a manifest".utf8)) == nil)
    }
}
