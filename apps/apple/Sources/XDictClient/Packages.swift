import Foundation
import Synchronization
import XDictContract

/// One file of a dictionary package as the app holds it: the contract's description, and where it is now.
public struct PackageFile: Sendable {
    public let spec: FileSpec
    /// Where the file is, asked before every observation and every open. WI-5 answers it from the file's bookmark,
    /// re-resolving when the path is gone (ADR-0009 decision 1: a moved folder is not a change); here, a fixed URL.
    public let locate: @Sendable () -> URL

    public init(spec: FileSpec, locate: @escaping @Sendable () -> URL) {
        self.spec = spec
        self.locate = locate
    }

    public init(spec: FileSpec, url: URL) {
        self.init(spec: spec, locate: { url })
    }
}

/// A dictionary package as the app sends it: the files, in the order their handles travel.
public struct DictionaryPackage: Sendable {
    public let files: [PackageFile]

    public init(files: [PackageFile]) {
        self.files = files
    }

    public var spec: PackageSpec {
        PackageSpec(files: files.map(\.spec))
    }

    /// An MDX with its volumes and sidecars at `urls`, each file given a new id: the usual shape, for the instruments
    /// and tests. A sidecar is named by its file name, its path in the package.
    public static func of(mdx: URL, volumes: [URL] = [], sidecars: [URL] = []) -> DictionaryPackage {
        var files = [PackageFile(spec: .mdx(id: UUID()), url: mdx)]
        files += volumes.enumerated().map { PackageFile(spec: .volume(id: UUID(), order: $0.offset), url: $0.element) }
        files += sidecars.enumerated().map {
            PackageFile(spec: .sidecar(id: UUID(), pathInPackage: $0.element.lastPathComponent, order: $0.offset), url: $0.element)
        }
        return DictionaryPackage(files: files)
    }
}

/// **The app's observations of its files** (`FileToken`): `stat` of the path each file is at now, numbered so the service
/// can order them (`TokenLedger`). Observations are taken one at a time, and each is numbered inside its turn from the
/// system's monotonic clock in nanoseconds (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`), raised past the last number if the
/// clock has not moved: strictly increasing for every file, and never below a number an earlier launch of the app gave
/// a service still running (a reboot ends both).
public final class FileObserver: Sendable {
    private let last = Mutex<UInt64>(0)
    private let clock: @Sendable () -> UInt64

    public init(clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.clock = clock
    }

    public func token(_ file: PackageFile) -> FileToken {
        token(file: file.spec.id, at: file.locate())
    }

    public func token(file: UUID, at url: URL) -> FileToken {
        last.withLock { last in
            var info = stat()
            let state: FileToken.State = stat(url.path, &info) == 0 ? .present(FileIdentity(stat: info)) : .missing
            last = max(clock(), last &+ 1)
            return FileToken(file: file, observed: last, state: state)
        }
    }
}
