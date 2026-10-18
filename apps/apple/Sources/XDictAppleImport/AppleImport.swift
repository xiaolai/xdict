// XDictAppleImport — Apple's dictionaries, converted to MDX once (ADR-0011).
//
// **Provenance** (ADR-0011 decision 12; the file-by-file record is `dev-docs/apple-import-provenance.md`). Adopted from
// the dict2mdx spike's Swift port (`spike-swift/Sources/XDictCore`), whose Python reference stays outside this
// repository as an oracle, never as code to copy. What each part was written from:
//
// - `AppleDict.swift` (the bundle's `Info.plist`, `Body.data`, `KeyText.data`) and `Transform.swift`,
//   `HTMLEntities.swift` (entry XML to HTML): Apple's installed `*.dictionary` bundles as observed, byte by byte, and
//   the XML 1.0 and HTML specifications. No Apple code, and no other converter's.
// - `MDictWriter.swift` (MDX and MDD 2.0): the MIT-licensed writemdict format description, as `core/xdict-mdx` is.
// - `KeyOrder.swift` (the order records are written in): what XDict's own core reader folds keys to
//   (`core/xdict-mdx/src/text.rs`, `fold`; `core/xdict-mdx/src/lib.rs`, the rules per file kind). It replaces the
//   spike's rule, which mirrored a GPL tool's regex with no recorded origin.
// - `Zlib.swift`: the system's libz, called through its documented interface.
//
// No GPL or AGPL source was read for any of it (ADR-0001). The spike's own MDX reader is not here: the core's reader is
// the production check of every output (ADR-0011 decision 3), and a test-only reader lives with the tests.

/// What the converter is, apart from what it converts.
public enum AppleImport {
    /// **Bumped with any change to the bytes written** (ADR-0011 decision 7): an imported copy made by an older revision
    /// is offered a fresh conversion. 2: Apple's pronunciation markers are kept (ADR-0013 decision 1).
    public static let converterRevision = 2
}

/// **Where a conversion is, asked of its checkpoint** (ADR-0011 decision 5): before every section of `Body.data` is
/// inflated (`reading`: bytes of the body's data window passed, of all), every 1,024 entries transformed (`building`:
/// entries passed, of all), and before every output block is built or written (`writing`: records passed, of the
/// MDX's and the MDD's together). A checkpoint that answers `false` stops the
/// conversion there as `AppleImportError.cancelled`.
public struct ConversionStep: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case reading, building, writing
    }

    public let phase: Phase
    public let done: Int
    public let total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

/// Asked at every `ConversionStep`; `false` cancels.
public typealias Checkpoint = (ConversionStep) -> Bool

/// What a conversion wrote: articles, redirects (search keys leading to an article), MDD resources (the stylesheet
/// included), and the output files' names, MDX first.
public struct ConversionSummary: Equatable, Sendable {
    public let entries: Int
    public let redirects: Int
    public let resources: Int
    public let files: [String]

    public init(entries: Int, redirects: Int, resources: Int, files: [String]) {
        self.entries = entries
        self.redirects = redirects
        self.resources = resources
        self.files = files
    }
}

/// The checkpoint as the converter's parts call it: throws `cancelled` on a `false`. Counts the records written across
/// both output files, so `writing` steps rise from the MDX through the MDD.
final class Steps {
    private let checkpoint: Checkpoint?
    private(set) var written = 0
    var writingTotal = 0

    init(_ checkpoint: Checkpoint?) { self.checkpoint = checkpoint }

    func reading(done: Int, total: Int) throws {
        try ask(ConversionStep(phase: .reading, done: done, total: total))
    }

    func building(done: Int, total: Int) throws {
        try ask(ConversionStep(phase: .building, done: done, total: total))
    }

    /// Before an output block: `records` more will have been passed once it is built.
    func writing(adding records: Int = 0) throws {
        try ask(ConversionStep(phase: .writing, done: written, total: writingTotal))
        written += records
    }

    private func ask(_ step: ConversionStep) throws {
        guard let checkpoint else { return }
        guard checkpoint(step) else { throw AppleImportError.cancelled }
    }
}
