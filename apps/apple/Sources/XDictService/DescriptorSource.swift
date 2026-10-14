import Foundation
import XDictContract
import XDictCore

/// **A file the app opened and sent, read by offset** (ADR-0009 decision 1; spike 1 measured the design). The source owns
/// the descriptor: it closes it when the core lets the source go (a closed dictionary, an import that has answered), so
/// an open dictionary holds exactly one descriptor per file and nothing else holds any.
///
/// `pread` has no shared cursor, so the core's threads may read at once (its `ByteSource` contract). `identity()` is
/// `IdentityRule`: the held descriptor's `fstat` if it moved since the source was made, else the app's newest token for
/// the file if that differs, else the `fstat` — and the core answers `sourceChanged` on any difference from what it saw at
/// open (ADR-0007 decision 13).
final class DescriptorSource: ByteSource, @unchecked Sendable {
    // `@unchecked`: every stored property is immutable after `init`; `FileHandle` is not declared `Sendable`, and the
    // only thing done with it from other threads is reading its descriptor number, which never changes.
    private let handle: FileHandle
    /// The descriptor this source owns (read by the tests, to see it closed).
    let descriptor: Int32
    private let file: UUID
    private let atOpen: XDictContract.FileIdentity?
    private let token: @Sendable (UUID) -> FileToken.State?

    /// `token` answers the newest token the service holds for a file (`TokenLedger`), read at every `identity()`.
    init(handle: FileHandle, file: UUID, token: @escaping @Sendable (UUID) -> FileToken.State?) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        self.file = file
        self.token = token
        atOpen = Self.held(handle.fileDescriptor)
    }

    deinit {
        try? handle.close()
    }

    func size() -> UInt64 {
        Self.held(descriptor)?.size ?? atOpen?.size ?? 0
    }

    /// Exactly `len` bytes from `offset`, or fewer at the end of the file, which the core reports as a short read.
    func readAt(offset: UInt64, len: UInt32) throws -> Data {
        var data = Data(count: Int(len))
        var got = 0
        let failure: Int32? = data.withUnsafeMutableBytes { buffer -> Int32? in
            guard let base = buffer.baseAddress else { return len == 0 ? nil : EINVAL }
            while got < Int(len) {
                let read = pread(descriptor, base + got, Int(len) - got, off_t(offset) + off_t(got))
                if read < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if read == 0 { break }
                got += read
            }
            return nil
        }
        if let failure {
            let kind: XDictCore.IoKind = switch failure {
            case EACCES, EPERM: .permissionDenied
            case ENOMEM: .outOfMemory
            case ENOENT: .notFound
            default: .other
            }
            throw CoreError.Io(kind: kind, detail: "pread at \(offset): \(String(cString: strerror(failure)))")
        }
        if got < Int(len) { data.count = got }
        return data
    }

    func identity() -> XDictCore.FileIdentity? {
        IdentityRule.reported(atOpen: atOpen, held: Self.held(descriptor), token: token(file)).map(XDictCore.FileIdentity.init)
    }

    static func held(_ descriptor: Int32) -> XDictContract.FileIdentity? {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? XDictContract.FileIdentity(stat: info) : nil
    }
}
