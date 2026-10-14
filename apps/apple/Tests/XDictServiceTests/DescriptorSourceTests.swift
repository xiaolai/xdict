import Foundation
import Synchronization
import Testing
import XDictContract
import XDictCore
@testable import XDictService

/// **The service's byte source**: a descriptor the app opened, read by offset, its identity by `IdentityRule`, closed when
/// the core lets it go.
struct DescriptorSourceTests {
    final class Token: Sendable {
        let state = Mutex<FileToken.State?>(nil)
    }

    static func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "xdict-source-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    static func source(_ url: URL, token: Token = Token()) throws -> DescriptorSource {
        DescriptorSource(handle: try FileHandle(forReadingFrom: url), file: UUID(), token: { _ in token.state.withLock { $0 } })
    }

    @Test func readsExactlyTheBytesAskedForAndFewerAtTheEnd() throws {
        let bytes = (0..<256).map { UInt8($0) }
        let url = try Self.file(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try Self.source(url)
        #expect(source.size() == 256)
        #expect(try source.readAt(offset: 10, len: 20) == Data(bytes[10..<30]))
        #expect(try source.readAt(offset: 250, len: 20) == Data(bytes[250..<256]))
        #expect(try source.readAt(offset: 300, len: 4).isEmpty)
        #expect(try source.readAt(offset: 0, len: 0).isEmpty)
    }

    /// `pread` has no shared cursor: the core's threads read at once, each its own bytes.
    @Test func concurrentReadsDoNotShareACursor() async throws {
        let bytes = (0..<(1 << 16)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let url = try Self.file(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try Self.source(url)
        let wrong = await withTaskGroup(of: Bool.self) { group in
            for offset in stride(from: 0, to: 1 << 16, by: 1 << 10) {
                group.addTask { (try? source.readAt(offset: UInt64(offset), len: 1 << 10)) != Data(bytes[offset..<offset + (1 << 10)]) }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wrong == 0)
    }

    /// `IdentityRule` through the source: the held file's own identity with no newer token; the app's token when the
    /// path names another file now; none when the app found nothing there.
    @Test func identityFollowsTheNewestToken() throws {
        let url = try Self.file([1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        let token = Token()
        let source = try Self.source(url, token: token)
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        let held = XDictContract.FileIdentity(stat: info)
        #expect(source.identity() == XDictCore.FileIdentity(held))
        token.state.withLock { $0 = .present(held) }
        #expect(source.identity() == XDictCore.FileIdentity(held))
        let elsewhere = XDictContract.FileIdentity(device: held.device, inode: held.inode + 1, size: 3, mtimeNs: held.mtimeNs,
                                                   ctimeNs: held.ctimeNs)
        token.state.withLock { $0 = .present(elsewhere) }
        #expect(source.identity() == XDictCore.FileIdentity(elsewhere))
        token.state.withLock { $0 = .missing }
        #expect(source.identity() == nil)
    }

    /// The source owns its descriptor: released, the descriptor no longer names the file (closed, or reused for another).
    @Test func releasingTheSourceClosesItsDescriptor() throws {
        let url = try Self.file([1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        var source: DescriptorSource? = try Self.source(url)
        let handle = try FileHandle(forReadingFrom: url)
        let inode = try #require(DescriptorSource.held(handle.fileDescriptor)?.inode)
        let descriptor = try #require(source).descriptor
        #expect(DescriptorSource.held(descriptor)?.inode == inode)
        source = nil
        #expect(DescriptorSource.held(descriptor)?.inode != inode)
        try handle.close()
    }
}
