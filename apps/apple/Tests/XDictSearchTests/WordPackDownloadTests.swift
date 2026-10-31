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

/// **A network inside the test process** (no socket, no name lookup): the pinned URLs answered from memory, so the real
/// transport runs whole. `canInit` narrows it to the pack's own host.
private final class StubNetwork: URLProtocol {
    private struct Reply {
        let status: Int
        let body: Data
    }

    private static let replies: [String: Reply] = [
        "/one.txt": Reply(status: 200, body: oneBytes),
        "/two.txt": Reply(status: 200, body: twoBytes),
        "/missing.txt": Reply(status: 404, body: Data("gone".utf8)),
    ]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wordpack.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.replies[url.path] ?? Reply(status: 404, body: Data())
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "\(reply.body.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    /// A `URLSession` whose whole network is `StubNetwork`: no socket is opened, so these tests run anywhere.
    static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubNetwork.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
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

    /// **The production transport with no network at all** (2026-10-31): this is the test the fake never was. A
    /// task-specific delegate receives no download callbacks on macOS 27, so a transport that waits for
    /// `didFinishDownloadingTo` to write the file "succeeds" with nothing at the destination — exactly the failure the
    /// owner saw. The temporary file the async call returns is the download; this fails unless it is moved into place,
    /// in a folder that does not exist yet and that the transport therefore has to make.
    @Test func theProductionTransportMovesTheDownloadIntoPlace() async throws {
        let url = try #require(URL(string: "https://wordpack.invalid/one.txt"))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Self.stubSession()
        defer { session.invalidateAndCancel() }
        let destination = folder.appending(path: "sources/one.txt")
        try await URLSessionTransfer(session: session).fetch(url, to: destination) { _ in }
        #expect(try Data(contentsOf: destination) == oneBytes)
    }

    /// **A response that is not a success is a failure, never a file**: the body a 404 wrote to the temporary file is
    /// not moved to the destination, and the download names the status.
    @Test func theProductionTransportRefusesAnErrorStatus() async throws {
        let url = try #require(URL(string: "https://wordpack.invalid/missing.txt"))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Self.stubSession()
        defer { session.invalidateAndCancel() }
        let destination = folder.appending(path: "missing.txt")
        do {
            try await URLSessionTransfer(session: session).fetch(url, to: destination) { _ in }
            Issue.record("an HTTP 404 was accepted as a file")
        } catch let failure as WordPackDownload.Failure {
            #expect(failure == .transport(file: "missing.txt", detail: "HTTP 404"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "an error response writes no file")
    }

    /// **The whole download through the real transport**: the manifest's size and SHA-256 are proved against the file
    /// the transport moved into the folder.
    @Test func theWholeDownloadRunsThroughTheRealTransport() async throws {
        let oneURL = try #require(URL(string: "https://wordpack.invalid/one.txt"))
        let twoURL = try #require(URL(string: "https://wordpack.invalid/two.txt"))
        let sources = WordPackSources(items: [
            WordPackSources.Item(file: "one.txt", url: oneURL, sha256: oneSha, bytes: UInt64(oneBytes.count)),
            WordPackSources.Item(file: "two.txt", url: twoURL, sha256: twoSha, bytes: UInt64(twoBytes.count)),
        ])
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Self.stubSession()
        defer { session.invalidateAndCancel() }
        try await WordPackDownload(sources: sources, transfer: URLSessionTransfer(session: session))
            .fetch(into: folder) { _, _, _ in }
        #expect(try Data(contentsOf: folder.appending(path: "one.txt")) == oneBytes)
        #expect(try Data(contentsOf: folder.appending(path: "two.txt")) == twoBytes)
    }

    /// **Verification reads the moved file**: a same-sized substituted body is caught after the move, by hash, and
    /// nothing is left for a build to read.
    @Test func theWholeDownloadIsVerifiedAfterTheMove() async throws {
        // `two` is the same length as `one`, so only the hash can catch it.
        let url = try #require(URL(string: "https://wordpack.invalid/two.txt"))
        let item = WordPackSources.Item(file: "one.txt", url: url, sha256: oneSha, bytes: UInt64(oneBytes.count))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Self.stubSession()
        defer { session.invalidateAndCancel() }
        do {
            try await WordPackDownload(sources: WordPackSources(items: [item]),
                                       transfer: URLSessionTransfer(session: session))
                .fetch(into: folder) { _, _, _ in }
            Issue.record("a same-sized substituted file was accepted through the real transport")
        } catch let failure as WordPackDownload.Failure {
            #expect(failure == .hashMismatch(file: "one.txt", expected: oneSha,
                                             found: WordPackDownload.measure(of: twoBytes)))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "one.txt").path),
                "the moved file is removed when its hash is wrong")
    }

    /// **The production transport, against the real endpoint** (opt-in): `XDICT_WORD_PACK_NETWORK=1` fetches the 1,740
    /// byte WNDB notice from upstream and checks the hash the manifest pins. Everything else here is local (the stub
    /// network above or a fake transfer), so this is the one test that also proves the endpoint and its TLS path.
    /// Off by default: a suite that reaches the network is not a suite anyone can run on a train.
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
