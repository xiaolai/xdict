import Foundation

// Files cross as handles with metadata, never as paths (AGENTS.md: every `.mdx` and `.mdd` is parsed in the service; the
// service is sandboxed and cannot open what the reader chose). Spike 1 (`measurements/2026-10-14-macos-xpc`) measured
// the design: handles in, `pread` on them, change detected by fstat plus the app's path token.

// MARK: - Identity

/// A file's identity as the core compares it (ADR-0007 decision 13; the core's `FileIdentity`): device, inode, size,
/// and the modification and status-change times in nanoseconds.
public struct FileIdentity: Codable, Hashable, Sendable {
    /// `st_dev` widened as Rust's `MetadataExt::dev()` widens it: sign-extended, `i32 as u64`.
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let mtimeNs: Int64
    public let ctimeNs: Int64

    public init(device: UInt64, inode: UInt64, size: UInt64, mtimeNs: Int64, ctimeNs: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
    }

    /// From `stat(2)` or `fstat(2)`, exactly as the core's `identity_of` makes one from the same numbers (`source.rs`):
    /// the app's path token and the service's reading of its descriptor must agree to the bit.
    public init(stat info: stat) {
        self.init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                  size: UInt64(bitPattern: Int64(info.st_size)),
                  mtimeNs: Self.nanoseconds(info.st_mtimespec), ctimeNs: Self.nanoseconds(info.st_ctimespec))
    }

    /// `seconds × 10⁹ + nanoseconds`, saturating as Rust's `saturating_mul` and `saturating_add` do.
    static func nanoseconds(_ time: timespec) -> Int64 {
        let seconds = Int64(time.tv_sec), fraction = Int64(time.tv_nsec)
        let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let whole = overflowed ? (seconds < 0 ? Int64.min : Int64.max) : scaled
        let (sum, overflowedAgain) = whole.addingReportingOverflow(fraction)
        return overflowedAgain ? (fraction < 0 ? Int64.min : Int64.max) : sum
    }
}

/// What the app last found at the path it resolved for one file: `stat()` of that path, re-resolving the file's
/// bookmark first if the path is gone (`ENOENT`), or `missing` if nothing is there even then. Sent with every request
/// that may read the file (`Request.refusal` requires it), so the service can see what its descriptor cannot: the path
/// naming another file.
public struct FileToken: Codable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case present(FileIdentity)
        case missing
    }

    /// The file's id, as in its `FileSpec`.
    public let file: UUID
    /// **When the app observed it**, in an order the service can trust (`TokenLedger`): strictly greater for every
    /// later observation of the same file. The app takes a file's observations one at a time (a lock or a serial queue
    /// per file) and numbers each, inside that turn, from the system's monotonic clock in nanoseconds
    /// (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`), so a relaunched app never numbers below a service still holding the
    /// last one's tokens; a reboot ends that service too.
    public let observed: UInt64
    public let state: State

    public init(file: UUID, observed: UInt64, state: State) {
        self.file = file
        self.observed = observed
        self.state = state
    }
}

/// **The service's tokens, kept in the order the app observed them** (Codex objection 3). Requests run concurrently, so
/// one carrying an old observation can arrive after one carrying a newer: merged naively, the old would replace the new,
/// and a check reading the merged tokens would miss a swap the newer one saw. Each file keeps the token with the
/// highest `observed`; an equal one (the same observation, retried) changes nothing.
public enum TokenLedger {
    public static func merging(_ incoming: [FileToken], into held: [UUID: FileToken]) -> [UUID: FileToken] {
        var merged = held
        for token in incoming {
            if let current = merged[token.file], current.observed >= token.observed { continue }
            merged[token.file] = token
        }
        return merged
    }
}

/// What the service learned of one received descriptor before admission (its `HandleInspection`): its identity by
/// `fstat`, nil if that failed, and whether it is a regular file opened read-only — the only kind of descriptor a
/// dictionary file arrives as (Codex objection 7).
public struct HandleFacts: Hashable, Sendable {
    public let identity: FileIdentity?
    public let isRegularReadOnly: Bool

    public init(identity: FileIdentity?, isRegularReadOnly: Bool) {
        self.identity = identity
        self.isRegularReadOnly = isRegularReadOnly
    }
}

/// **The identity the service's byte source reports to the core** (`ByteSource.identity()`), which compares it with
/// the one it recorded at open and answers `sourceChanged` on any difference, none included (ADR-0007 decision 13).
///
/// - the held descriptor's `fstat`, if it moved since open: the file itself changed (rewritten in place; or replaced by a
///   rename, whose old inode loses its last link and so its ctime moves);
/// - else the app's token, if it differs from the identity at open: the path names another file now (a swapped folder,
///   which leaves the held inode untouched and which fstat alone misses), or nothing (`missing`, reported as none);
/// - else the `fstat`, equal to the identity at open.
///
/// A file the app moved is not a change only if the app re-resolved its bookmark before sending the token. With no
/// token known for the file, the `fstat` stands; admission requires a token for every file a request reads, so that is
/// never an admitted read's case. `token` is the newest the service holds (`TokenLedger`), not necessarily the
/// request's own. Spike 1 measured all four cases on both Macs.
public enum IdentityRule {
    public static func reported(atOpen: FileIdentity?, held: FileIdentity?, token: FileToken.State?) -> FileIdentity? {
        if held != atOpen { return held }
        switch token {
        case .none: return held
        case .missing: return nil
        case .present(let atPath): return atPath != atOpen ? atPath : held
        }
    }
}

// MARK: - Packages

/// One file of a package. Its handle travels beside the request, at the same position in the list.
public struct FileSpec: Codable, Hashable, Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable {
        case mdx, mdd, sidecar
    }

    /// The app's id for the file, persisted with it.
    public let id: UUID
    /// **The core's location name** (`Location::Source { name }`). For an MDX or a volume, the id's `uuidString`: the
    /// core's registry keys a location by it (`core.rs` `location_key`), so it must not move when the file does. For a
    /// sidecar, **its path in the package**, `/`-separated (`styles/main.css`): the core finds a sidecar by comparing that
    /// name with the resource path asked for (`core.rs` `find_resource`), so an id would never be found.
    public let name: String
    public let role: Role
    /// The file's place within its role, from 0: a volume's search order (`.mdd`, `.1.mdd`, …), a sidecar's. The MDX's
    /// is 0.
    public let order: Int

    public init(id: UUID, name: String, role: Role, order: Int) {
        self.id = id
        self.name = name
        self.role = role
        self.order = order
    }

    public static func mdx(id: UUID) -> FileSpec {
        FileSpec(id: id, name: id.uuidString, role: .mdx, order: 0)
    }

    public static func volume(id: UUID, order: Int) -> FileSpec {
        FileSpec(id: id, name: id.uuidString, role: .mdd, order: order)
    }

    public static func sidecar(id: UUID, pathInPackage: String, order: Int) -> FileSpec {
        FileSpec(id: id, name: pathInPackage, role: .sidecar, order: order)
    }

    var namingProblem: PackageProblem? {
        switch role {
        case .mdx, .mdd: name == id.uuidString ? nil : .notNamedByID(file: id)
        case .sidecar: Self.isPathInPackage(name) ? nil : .sidecarNotAPackagePath(file: id)
        }
    }

    /// A path as the core resolves one (`xdict-entry` `Path::resolve`): relative, `/`-separated, with no empty, `.` or
    /// `..` segment and no backslash — and not a UUID, which is how an MDX or a volume is named, never a sidecar.
    static func isPathInPackage(_ name: String) -> Bool {
        guard UUID(uuidString: name) == nil, !name.contains("\\") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

/// A dictionary as the core takes it (ADR-0007 decision 4): one MDX, its volumes in order, its sidecars. **It holds no
/// location**: the service builds each `Location::Source` from a received handle and the file's `name`, and nothing in
/// this contract can name a place on disk.
public struct PackageSpec: Codable, Hashable, Sendable {
    public let files: [FileSpec]

    public init(files: [FileSpec]) {
        self.files = files
    }

    /// The first thing wrong with this package, or nil: at most `Limits.maxPackageFiles` files, no file twice, each
    /// named as its role requires, exactly one MDX, and each role's orders `0, 1, …` without a gap or a repeat.
    public var problem: PackageProblem? {
        guard files.count <= Limits.maxPackageFiles else {
            return .tooManyFiles(found: files.count, limit: Limits.maxPackageFiles)
        }
        var seen = Set<UUID>()
        for file in files where !seen.insert(file.id).inserted { return .duplicateFile(file.id) }
        if let problem = files.lazy.compactMap(\.namingProblem).first { return problem }
        let mdx = files.count { $0.role == .mdx }
        guard mdx == 1 else { return .mdxCount(found: mdx) }
        for role in FileSpec.Role.allCases {
            let orders = files.filter { $0.role == role }.map(\.order).sorted()
            guard orders == Array(0..<orders.count) else { return .orderNotContiguous(role: role) }
        }
        return nil
    }
}

/// What makes a package one the service refuses.
public enum PackageProblem: Codable, Hashable, Sendable {
    /// A package has exactly one MDX.
    case mdxCount(found: Int)
    /// The same file id twice.
    case duplicateFile(UUID)
    /// An MDX or a volume named otherwise than by its id's `uuidString`: a path, most likely.
    case notNamedByID(file: UUID)
    /// A sidecar named by a UUID, or by anything that is not a path inside the package.
    case sidecarNotAPackagePath(file: UUID)
    /// A role's orders are not `0, 1, …`.
    case orderNotContiguous(role: FileSpec.Role)
    /// More files than `Limits.maxPackageFiles`.
    case tooManyFiles(found: Int, limit: Int)
}
