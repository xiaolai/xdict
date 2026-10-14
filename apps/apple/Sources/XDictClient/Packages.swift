import Foundation
import Synchronization
import XDictContract

/// One file of a dictionary package as the app holds it: the contract's description, and where it is now.
public struct PackageFile: Sendable {
    public let spec: FileSpec
    /// Where the file is, asked before every observation and every open: **a canonical path**, since the client follows
    /// no link in it (`FileAccess`). The library answers it from the file's bookmark, re-resolving when the path is gone
    /// (ADR-0009 decision 1: a moved folder is not a change); here, a fixed URL.
    public let locate: @Sendable () -> URL

    public init(spec: FileSpec, locate: @escaping @Sendable () -> URL) {
        self.spec = spec
        self.locate = locate
    }

    /// A file at a fixed path, for trusted callers (the instruments, the tests): made canonical here, when the package is
    /// built, not when it is opened. The library's files come canonical from their resolution, by `init(spec:locate:)`.
    public init(spec: FileSpec, url: URL) {
        let canonical = FileAccess.canonical(url)
        self.init(spec: spec, locate: { canonical })
    }
}

/// **How the app reaches a file it hands the service** (the security review of 2026-10-15). Every path it is given is
/// canonical — the library's are found so (`FileLocator`), and a package of fixed paths is made so when it is built — so
/// a link anywhere in one was put there after the path was checked, and is refused rather than followed
/// (`O_NOFOLLOW_ANY`, `AT_SYMLINK_NOFOLLOW_ANY`): followed, it would hand the service a file the reader never chose. Only
/// a regular file is reached, and the open never waits on a pipe put in a file's place (`O_NONBLOCK`, cleared once the
/// descriptor is known to be a regular file's). The observation behind a token and the open follow the same rule, so a
/// token says what the open would find.
public enum FileAccess {
    /// Why a file was not opened: the system's errno, `ELOOP` for a link in the file's place or in a folder above it, and
    /// `EFTYPE` for anything but a regular file (a folder, a pipe, a socket).
    public struct Refused: Error, Hashable, Sendable {
        public let errno: Int32
    }

    /// A read-only descriptor of the regular file at `url`, the caller's to close; or why not.
    public static func open(_ url: URL) -> Result<Int32, Refused> {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(Refused(errno: errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return refuse(descriptor, errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return refuse(descriptor, EFTYPE) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return refuse(descriptor, errno) }
        return .success(descriptor)
    }

    /// The identity of the regular file at `url`, reached without a link; nil when there is none: nothing there, a link in
    /// its place or in a folder above it, or something that is not a regular file.
    public static func identity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard fstatat(AT_FDCWD, url.path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return FileIdentity(stat: info)
    }

    /// `url` made canonical, every link in it resolved (`realpath(3)`): for a path a trusted caller names. A file not
    /// there yet keeps its name under its folder's canonical path; with no folder there either, `url` is left as it is.
    public static func canonical(_ url: URL) -> URL {
        if let path = realpath(url) { return URL(fileURLWithPath: path) }
        if let folder = realpath(url.deletingLastPathComponent()) {
            return URL(fileURLWithPath: folder).appending(path: url.lastPathComponent)
        }
        return url
    }

    private static func realpath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Closes `descriptor`, answering `code` (read before the close can change `errno`).
    private static func refuse(_ descriptor: Int32, _ code: Int32) -> Result<Int32, Refused> {
        close(descriptor)
        return .failure(Refused(errno: code))
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

/// **The app's observations of its files** (`FileToken`): `stat` of the path each file is at now, without following a link
/// (`FileAccess.identity`: a link, or anything but a regular file, is `missing`, since the client would not open it),
/// numbered so the service can order them (`TokenLedger`). Observations are taken one at a time, and each is numbered inside its turn from the
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
            let state: FileToken.State = FileAccess.identity(at: url).map { .present($0) } ?? .missing
            last = max(clock(), last &+ 1)
            return FileToken(file: file, observed: last, state: state)
        }
    }
}
