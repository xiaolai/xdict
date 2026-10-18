/// **Why a snapshot was not converted, as a kind carrying data, never a sentence** (ADR-0011 decision 11). The shell
/// turns a kind into words (ADR-0007); nothing parses a diagnostic. The human detail of a fault, where there is any,
/// goes to the conversion's `Report`, apart from this.
public enum AppleImportError: Error, Equatable, Sendable {
    /// `IDXDictionaryVersion` is not 3: the only format these bundles are known in (ADR-0011 decision 11). `nil` when
    /// the key is absent or not an integer.
    case notVersion3(found: Int?)
    /// No `KeyText.index` among the bundle's indexes: the system "Apple Dictionary" is one, and has no search keys.
    case noKeyTextIndex
    case malformedInfoPlist(InfoPlistFault)
    /// A format 3 bundle using something no installed bundle was seen to use.
    case unsupported(Unsupported)
    case boundExceeded(Bound)
    case corrupt(Corruption)
    /// A name the bundle supplies for one of its files leaves `Contents/Resources`, or is not a plain path.
    case unsafeResourceName(String)
    /// A file in the snapshot is a symbolic link, which is refused, never followed (path relative to Resources).
    case symbolicLink(String)
    /// The output name is not a plain file name.
    case unsafeOutputName(String)
    /// A file of that name is already in the output folder: converted files are never overwritten (ADR-0011 decision 9).
    case outputExists(file: String)
    /// A file could not be read or written; `code` is the POSIX error number when there is one.
    case unreadable(file: String, code: Int)
    case unwritable(file: String, code: Int)
    /// The bundle has no entries.
    case noEntries
    /// The checkpoint answered `false` (ADR-0011 decision 5): the conversion stopped there and left nothing.
    case cancelled
}

public enum InfoPlistFault: Equatable, Sendable {
    case missing
    case unparsable
    case notADictionary
    /// `IDXDictionaryIndexes` is absent, short, or holds something that is not a dictionary.
    case indexes
    /// The named key has the wrong type or shape.
    case field(String)
}

public enum Unsupported: Equatable, Sendable {
    case bodyCompression(Int)
    case keyTextCompression(Int)
    case fixedFields([String])
    case noKeywordField
}

/// Which bound was exceeded (`Bounds`, and the per-block bound in `Zlib.swift`).
public enum Bound: Equatable, Sendable {
    /// A file the converter reads whole was larger than `Bounds.sourceFileBytes`.
    case sourceFile(name: String, limit: Int)
    /// One zlib block claims more than `maxInflatedBlock`, or more than deflate can expand its input to.
    case inflatedBlock(claimed: Int)
    /// All blocks together inflate to more than `Bounds.decompressedBytes`.
    case decompression(limit: Int)
    /// The MDX and MDD together would pass `Bounds.outputBytes`.
    case output(limit: Int)
    /// A key longer than the format's 16-bit lengths can describe.
    case keyLength(units: Int)
}

/// Where a bundle's bytes stopped making sense. Offsets are byte offsets into the named file.
public enum Corruption: Equatable, Sendable {
    case body(offset: Int)
    case keyText(offset: Int)
    /// An entry's XML: its address in `Body.data` (section, offset in the section).
    case entry(section: Int, chunk: Int)
    /// An entry's links could not be resolved into place.
    case links(entryID: String)
    case duplicateEntryID(String)
    /// `KeyText.data` names addresses no entry has.
    case strayKeys(count: Int)
    /// Redirects that would lead to no key.
    case danglingRedirects(count: Int)
    /// A stylesheet is not text, or keeps Apple's namespace selectors.
    case stylesheet(String)
    /// Two resources map to one MDD key, or a key is unusable (empty, a NUL).
    case resourceKey(String)
    case recordKey(String)
    /// An entry turned out empty.
    case emptyEntry(String)
    /// A resource is empty: the core's reader could not tell it from the next one (`xdict-mdx/src/index.rs`).
    case emptyRecord(String)
}

/// **The converter's bounds** (hardening of ADR-0011 decisions 4 and 5): what one conversion may read, inflate and
/// write. Injectable so the tests can show each refusal without gigabytes; the service uses `production`.
public struct Bounds: Sendable, Equatable {
    /// The largest file read whole (`Body.data`, `KeyText.data`, a stylesheet, a resource). 512 MiB: the snapshot's own
    /// bound (ADR-0011 decision 4), so no single file can pass what the copy admitted; Hungarian, the largest installed
    /// bundle, is 123 MB in all.
    public var sourceFileBytes: Int
    /// `Info.plist`, parsed by Foundation in one piece. 4 MiB: the installed ones are a few KiB.
    public var infoPlistBytes: Int
    /// Every zlib block of `Body.data` and `KeyText.data` together, inflated. 2 GiB: about sixteen times Hungarian's
    /// whole snapshot, and what is inflated is held while the records are built, so this is also a memory bound:
    /// 256 MiB inflated peaked at about 1 GiB through the service's path (`Tools/measure-apple-import-memory.sh`, which
    /// holds that to a budget). Hungarian in the signed service is the owner's measurement (ADR-0011 decision 5).
    public var decompressedBytes: Int
    /// The MDX and the MDD together. 2 GiB: an MDX is smaller than what it was inflated from, and the MDD is the
    /// snapshot's resources, already within 512 MiB.
    public var outputBytes: Int

    public init(sourceFileBytes: Int, infoPlistBytes: Int, decompressedBytes: Int, outputBytes: Int) {
        self.sourceFileBytes = sourceFileBytes
        self.infoPlistBytes = infoPlistBytes
        self.decompressedBytes = decompressedBytes
        self.outputBytes = outputBytes
    }

    public static let production = Bounds(sourceFileBytes: 512 << 20, infoPlistBytes: 4 << 20,
                                          decompressedBytes: 2 << 30, outputBytes: 2 << 30)
}

/// What is left of `Bounds.decompressedBytes`, charged by every block before it is inflated.
final class DecompressionBudget {
    let limit: Int
    private(set) var used = 0

    init(limit: Int) { self.limit = limit }

    func charge(_ bytes: Int) throws {
        let (sum, overflow) = used.addingReportingOverflow(bytes)
        guard !overflow, sum <= limit else { throw AppleImportError.boundExceeded(.decompression(limit: limit)) }
        used = sum
    }
}

/// What is left of `Bounds.outputBytes`, charged by every write.
final class OutputMeter {
    let limit: Int
    private(set) var written = 0

    init(limit: Int) { self.limit = limit }

    func charge(_ bytes: Int) throws {
        let (sum, overflow) = written.addingReportingOverflow(bytes)
        guard !overflow, sum <= limit else { throw AppleImportError.boundExceeded(.output(limit: limit)) }
        written = sum
    }
}
