import Foundation
import Synchronization
import Testing
import XDictContract
@testable import XDictClient

/// **What the client sends is the file at the path, never what a link there names** (the security review of
/// 2026-10-15). The library checks each path once, when it resolves a package; the client opens it later, and opens it
/// again by itself after the service restarts. A link put in a file's place, or in a folder above it, in between would be
/// followed to a file the reader never chose, and a pipe there would hold the client forever. So the client opens without
/// following any link and without waiting, refuses anything but a regular file before anything is sent, and observes the
/// path for its tokens by the same rule; packages made of fixed paths are made canonical when they are built.
struct ServiceClientFileTests {
    static func canonical(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func ready(_ dict: String = "d") -> Answer {
        .opened(.ready(dict: DictId(rawValue: dict), edition: Fixture.edition, info: Fixture.info))
    }

    /// Replaces the file at `url` with a link to `target`.
    static func link(_ url: URL, to target: URL) throws {
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    @Test func aPackageOfFixedPathsIsMadeOfCanonicalOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xdict-canonical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("mdx".utf8).write(to: directory.appending(path: "a.mdx"))
        let canonical = try #require(Self.canonical(directory))
        try #require(canonical != directory.path, "the scratch folder is reached through a link here (/var), or this proves nothing")
        let package = DictionaryPackage.of(mdx: directory.appending(path: "a.mdx"),
                                           volumes: [directory.appending(path: "not-yet.mdd")])
        #expect(package.files.map { $0.locate().path } == [canonical + "/a.mdx", canonical + "/not-yet.mdd"])
    }

    @Test func aLinkInAFilesPlaceOrInAFolderAboveItIsNeverSent() async throws {
        let service = FakeTransport { request, _ in .reply(Self.ready(), to: request) }
        let client = ServiceClient(connect: service.connect)
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appending(path: "secret")
        try Data("not the dictionary's".utf8).write(to: secret)
        try Self.link(package.files[1].locate(), to: secret)
        #expect(await client.open(package) == .failure(.fileUnavailable(file: package.files[1].spec.id, errno: ELOOP)))

        let sub = directory.appending(path: "sub"), other = directory.appending(path: "other")
        for folder in [sub, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("mdx".utf8).write(to: folder.appending(path: "b.mdx"))
        }
        let inSub = DictionaryPackage.of(mdx: sub.appending(path: "b.mdx"))
        try Self.link(sub, to: other)
        #expect(await client.open(inSub) == .failure(.fileUnavailable(file: inSub.files[0].spec.id, errno: ELOOP)))
        #expect(service.sent.isEmpty)
    }

    /// A pipe in a file's place: refused as no regular file (`EFTYPE`) at once. Before, `open(2)` waited for a writer that
    /// never comes; the test gives it three seconds, then opens the pipe's other end itself so the run can end.
    @Test func aPipeInAFilesPlaceIsRefusedWithoutWaitingOnIt() async throws {
        let service = FakeTransport { request, _ in .reply(Self.ready(), to: request) }
        let client = ServiceClient(connect: service.connect)
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = package.files[1].locate()
        try FileManager.default.removeItem(at: volume)
        try #require(mkfifo(volume.path, 0o600) == 0)
        let outcome = Slot<Result<Opened, ClientFailure>>()
        let opening = Task { outcome.set(await client.open(package)) }
        for _ in 0..<300 where outcome.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        if outcome.current == nil {
            Issue.record("the client waited on a pipe put in a file's place")
            let writer = open(volume.path, O_WRONLY | O_NONBLOCK)
            _ = await opening.value
            if writer >= 0 { close(writer) }
        }
        #expect(outcome.current == .failure(.fileUnavailable(file: package.files[1].spec.id, errno: EFTYPE)))
        #expect(service.sent.isEmpty)
    }

    /// The tokens say what the client would open: a link in a file's place or above it, or a pipe, is `missing`.
    @Test func tokensAreTakenWithoutFollowingALink() throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let observer = FileObserver()
        var info = stat()
        try #require(stat(package.files[0].locate().path, &info) == 0)
        #expect(observer.token(package.files[0]).state == .present(FileIdentity(stat: info)))

        let secret = directory.appending(path: "secret")
        try Data("not the dictionary's".utf8).write(to: secret)
        let volume = package.files[1].locate()
        try Self.link(volume, to: secret)
        #expect(observer.token(package.files[1]).state == .missing, "a link in the file's place")
        try FileManager.default.removeItem(at: volume)
        try #require(mkfifo(volume.path, 0o600) == 0)
        #expect(observer.token(package.files[1]).state == .missing, "a pipe in the file's place")

        let sub = directory.appending(path: "sub"), other = directory.appending(path: "other")
        for folder in [sub, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("mdx".utf8).write(to: folder.appending(path: "b.mdx"))
        }
        let inSub = DictionaryPackage.of(mdx: sub.appending(path: "b.mdx"))
        try Self.link(sub, to: other)
        #expect(observer.token(inSub.files[0]).state == .missing, "a link in a folder above the file")
    }

    /// **The path that needs no race**: a dictionary is open, one of its files becomes a link to a file elsewhere, and the
    /// service restarts (`staleHandle`): the client opens the package again by itself, by its paths. That open fails
    /// `ELOOP`, the call waiting on it fails with it, and no handle the service ever received is the linked file.
    @Test func anOpenAfterARestartNeverFollowsALinkPutInAFilesPlace() async throws {
        let (package, directory) = try Fixture.package()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appending(path: "secret")
        try Data("not the dictionary's".utf8).write(to: secret)
        var info = stat()
        try #require(stat(secret.path, &info) == 0)
        let secretInode = UInt64(info.st_ino)
        let received = Mutex<[UInt64]>([])
        let first = DictId(rawValue: "first"), opens = Slot<Int>()
        let service = FakeTransport { request, files in
            for handle in files ?? [] {
                var facts = stat()
                if fstat(handle.fileDescriptor, &facts) == 0 { received.withLock { $0.append(UInt64(facts.st_ino)) } }
            }
            switch request.operation {
            case .openPackage:
                let count = (opens.current ?? 0) + 1
                opens.set(count)
                return .reply(Self.ready(count == 1 ? "first" : "second"), to: request)
            case .lookup(_, let dicts, _) where dicts == [first]:
                return .failure(.core(.staleHandle(detail: "restarted")), to: request)
            case .lookup(_, let dicts, _):
                return .reply(Fixture.page(dicts.map(Fixture.hit(in:))), to: request)
            default:
                return .silent
            }
        }
        let client = ServiceClient(connect: service.connect)
        guard case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the package did not open")
            return
        }
        try Self.link(package.files[1].locate(), to: secret)
        #expect(await client.call(Fixture.lookup("k", in: [dict]))
            == .failure(.fileUnavailable(file: package.files[1].spec.id, errno: ELOOP)))
        #expect(!received.withLock { $0 }.contains(secretInode), "the file the link names was sent to the service")
        #expect(opens.current == 1, "the package was opened again through the link")
    }
}
