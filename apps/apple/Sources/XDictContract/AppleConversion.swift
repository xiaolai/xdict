import Foundation

// **Converting an Apple dictionary** (ADR-0011; contract 6). The app copies a bundle's files, byte for byte, into
// `<app-group container>/AppleImports/staging/<uuid>/` and sends `convertApple(staging: uuid)`: a name, never a path
// (ADR-0009 decision 1). The service resolves it in the same container, converts it, and publishes the MDX and MDD into
// `AppleImports/<conversion uuid>/`, which the app then imports as any other dictionary (ADR-0011 decisions 2 and 9).

/// What a conversion published (ADR-0011 decisions 7 and 9). The app records the revisions and the conversion beside
/// the library entry (decision 10); the service remembers nothing.
public struct Converted: Codable, Hashable, Sendable {
    /// The folder the files were published into, `AppleImports/<conversion>/`: never reused, never overwritten.
    public let conversion: UUID
    /// The snapshot's manifest hash, versioned (`m1:` and 64 hex digits): for each file the converter reads, in
    /// canonical name order, its name, name length, size and SHA-256; `*.lproj` and the code signature left out.
    public let sourceRevision: String
    /// The converter's revision, bumped with any change to the bytes it writes.
    public let converterRevision: UInt32
    /// The published files' names, the MDX first.
    public let files: [String]
    /// Articles, redirects (search keys leading to an article) and MDD resources written.
    public let entries: UInt64
    public let redirects: UInt64
    public let resources: UInt64

    public init(conversion: UUID, sourceRevision: String, converterRevision: UInt32, files: [String], entries: UInt64,
                redirects: UInt64, resources: UInt64) {
        self.conversion = conversion
        self.sourceRevision = sourceRevision
        self.converterRevision = converterRevision
        self.files = files
        self.entries = entries
        self.redirects = redirects
        self.resources = resources
    }
}

/// **Why a snapshot was not converted**: a kind with its data, which the shell words (ADR-0011 decision 11, ADR-0007
/// decision 10). A `detail` is for logs only, never parsed, never shown. A cancelled conversion is
/// `CoreFailure.cancelled`, as an import's is.
public enum AppleImportRefusal: Error, Codable, Hashable, Sendable {
    /// The service has no app-group container: unsigned, or signed without the entitlement.
    case noContainer
    /// No staging folder of that UUID.
    case stagingNotFound
    /// The staging name is a link or a file, not a folder.
    case stagingNotAFolder
    /// A file in the snapshot is a symbolic link, which is refused, never followed (path inside the snapshot).
    case symbolicLink(path: String)
    /// Something in the snapshot is neither a folder nor a regular file: a pipe, a socket, a device.
    case notARegularFile(path: String)
    /// `IDXDictionaryVersion` is not 3; nil when absent or not an integer.
    case notVersion3(found: Int?)
    /// No `KeyText.index`: the system "Apple Dictionary" is one, with no search keys.
    case noKeyTextIndex
    case malformedInfoPlist(detail: String)
    /// A format 3 bundle using something no installed bundle was seen to use.
    case unsupported(detail: String)
    case boundExceeded(AppleImportBound)
    /// The bundle's bytes stopped making sense.
    case corrupt(detail: String)
    /// A name the bundle supplies is not a plain path inside it.
    case unsafeName(name: String)
    /// A file could not be read or written; `code` is the POSIX error number, 0 when there is none.
    case unreadable(file: String, code: Int)
    case unwritable(file: String, code: Int)
    /// The bundle has no entries.
    case noEntries
}

/// Which bound a conversion met (ADR-0011 decisions 4 and 11).
public enum AppleImportBound: Codable, Hashable, Sendable {
    /// More files in the snapshot than the service converts (512).
    case fileCount(limit: UInt64)
    /// The snapshot's files together larger than the service converts (512 MiB).
    case snapshotBytes(limit: UInt64)
    /// One file the converter reads whole is larger than it reads.
    case sourceFile(name: String, limit: UInt64)
    /// One compressed block claims more than it may inflate to.
    case inflatedBlock(claimed: UInt64)
    /// Every block together inflates past the budget.
    case decompression(limit: UInt64)
    /// The MDX and MDD together would pass the output cap.
    case output(limit: UInt64)
    /// A search key longer than the MDict format can hold.
    case keyLength(units: UInt64)
}
