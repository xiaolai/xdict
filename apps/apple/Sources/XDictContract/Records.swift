import Foundation

// The core's records and enums (ADR-0007; `xdict-core` `types.rs`), as the contract carries them: plain Codable Swift,
// so the app never needs the UniFFI binding, which the service alone links and converts from (`CoreMapping.swift`
// there). Fields and cases are the core's, under its names, with two exceptions said where they occur: an entry's HTML
// and a resource's bytes are the reply's payload, not fields; and the render base is the contract's, not the caller's.

// MARK: - Identity and handles (ADR-0007 decision 2: different types)

/// A **session handle** for one opened package (`Opened.ready`): valid in the service process that issued it, until
/// `close`. A restarted service refuses it with `staleHandle`; the client opens the package again. Carried as the core
/// carries it, a string (16 hex digits), and never stored.
public struct DictId: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A dictionary edition: `mdx-sha256-v1:<hex>` (ADR-0002). Stored by the app.
public struct Edition: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A lineage: a UUID the core mints, joined only by the reader (ADR-0002). Stored by the app.
public struct LineageId: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Versions, import, open

/// The core's versions, each compared on its own (ADR-0007 decision 11). The JSON names are those of XDictBase's
/// `CoreVersions` and `Generated/core-versions.json`, so the E2E `launch` stage compares like with like once WI-3 answers
/// the handshake from here.
public struct Versions: Codable, Hashable, Sendable {
    public let protocolVersion: UInt32
    public let core: String
    public let indexFormat: UInt32
    public let normalization: UInt32

    public init(protocolVersion: UInt32, core: String, indexFormat: UInt32, normalization: UInt32) {
        self.protocolVersion = protocolVersion
        self.core = core
        self.indexFormat = indexFormat
        self.normalization = normalization
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case core, indexFormat, normalization
    }
}

/// What a dictionary's header says.
public struct DictInfo: Codable, Hashable, Sendable {
    /// Empty where the file declares none.
    public let title: String
    public let description: String
    /// `1.2`, `2.0` or `3.0`.
    public let formatVersion: String
    public let keys: UInt64

    public init(title: String, description: String, formatVersion: String, keys: UInt64) {
        self.title = title
        self.description = description
        self.formatVersion = formatVersion
        self.keys = keys
    }
}

public struct Imported: Codable, Hashable, Sendable {
    public let edition: Edition
    public let lineage: LineageId
    public let info: DictInfo
    public let problems: [Problem]

    public init(edition: Edition, lineage: LineageId, info: DictInfo, problems: [Problem]) {
        self.edition = edition
        self.lineage = lineage
        self.info = info
        self.problems = problems
    }
}

/// Something an import met that did not stop it.
public enum Problem: Codable, Hashable, Sendable {
    /// A volume could not be read; its resources will be reported missing. `name` is the volume's location name.
    case volumeUnreadable(name: String, error: CoreFailure)
}

public enum Opened: Codable, Hashable, Sendable {
    case ready(dict: DictId, edition: Edition, info: DictInfo)
    case needsImport(reason: ImportReason)
}

public enum ImportReason: String, Codable, Hashable, Sendable {
    case new, changed, indexMissing, indexOutdated, noIdentity
}

// MARK: - Lookup

/// Where an entry is, in the only form the app stores (ADR-0007 decision 2).
public struct EntryRef: Codable, Hashable, Sendable {
    public let edition: Edition
    /// The key exactly as the file spells it.
    public let key: String
    /// Among the records under exactly this key, 0-based, in file order.
    public let occurrence: UInt32

    public init(edition: Edition, key: String, occurrence: UInt32) {
        self.edition = edition
        self.key = key
        self.occurrence = occurrence
    }
}

public enum MatchMode: String, Codable, Hashable, Sendable {
    /// What a reader typed: both tiers, public keys.
    case reader
    /// What a link named: tier 1 only, internal keys included.
    case link
}

public struct LookupOptions: Codable, Hashable, Sendable {
    /// At most the core's page size, 1,000; more is the core's `tooLarge(.page)`.
    public let limit: UInt32
    public let offset: UInt32
    public let mode: MatchMode
    /// The core's page generation this page continues (ADR-0007 decision 9); nil for a first page. Not the client's
    /// request generations, which never cross.
    public let generation: UInt32?

    public init(limit: UInt32, offset: UInt32, mode: MatchMode, generation: UInt32?) {
        self.limit = limit
        self.offset = offset
        self.mode = mode
        self.generation = generation
    }
}

/// A page of references, never bodies.
public struct Page: Codable, Hashable, Sendable {
    public let hits: [Hit]
    public let total: UInt64
    public let generation: UInt32
    /// Problems that left no hit to carry them.
    public let problems: [HitProblem]

    public init(hits: [Hit], total: UInt64, generation: UInt32, problems: [HitProblem]) {
        self.hits = hits
        self.total = total
        self.generation = generation
        self.problems = problems
    }
}

public struct Hit: Codable, Hashable, Sendable {
    public let dict: DictId
    public let entry: EntryRef
    public let headword: String
    public let how: How
    public let problems: [HitProblem]

    public init(dict: DictId, entry: EntryRef, headword: String, how: How, problems: [HitProblem]) {
        self.dict = dict
        self.entry = entry
        self.headword = headword
        self.how = how
        self.problems = problems
    }
}

/// Why a lookup matched: the reason the reader is shown (Q4).
public enum How: Codable, Hashable, Sendable {
    case exact
    case folded
    case unmarked
    /// Reached through `@@@LINK=`: the keys passed through, the query first.
    case redirect(chain: [String])
}

public enum HitProblem: Codable, Hashable, Sendable {
    case danglingRedirect(from: String, target: String)
    case redirectLoop(chain: [String])
    case redirectLimit(chain: [String])
}

// MARK: - Rendering

/// The render context of `entry`, `link` and `resource` (the core's `View`, ADR-0007 decision 6), **less its base**:
/// every entry is rewritten under `baseURL`, the one authority the entry view's scheme handler answers (plan WI-4), so
/// no request can have the core write an entry's URLs anywhere else. The service fills the base in.
public struct RenderContext: Codable, Hashable, Sendable {
    /// `xdict://d/`.
    public static let baseURL = "xdict://d/"
    /// The reader's views: the contract's whole ceiling.
    public static let reader = RenderContext(maxBodyBytes: Limits.maxBodyBytes)

    /// The ceiling on one rendered body (an entry, or a stylesheet, script or page it loads), between 1 byte and
    /// `Limits.maxBodyBytes`.
    public let maxBodyBytes: UInt64

    public init(maxBodyBytes: UInt64) {
        self.maxBodyBytes = maxBodyBytes
    }
}

/// An entry for the entry view, **less its HTML, which is the reply's payload** (UTF-8).
public struct Entry: Codable, Hashable, Sendable {
    public let entry: EntryRef
    /// The Content-Security-Policy the view must apply before the first byte of the HTML (ADR-0007 decision 14).
    public let csp: String
    /// Bytes the text decoder could not read and replaced.
    public let lossyBytes: UInt64

    public init(entry: EntryRef, csp: String, lossyBytes: UInt64) {
        self.entry = entry
        self.csp = csp
        self.lossyBytes = lossyBytes
    }
}

/// Where a link appeared, for resolving it (ADR-0007 decision 7).
public enum LinkOrigin: Codable, Hashable, Sendable {
    case entry(entry: EntryRef)
    /// A stylesheet or script, by its path in the package.
    case resource(path: String)
}

/// What a link means (ADR-0007 decision 7). Paths are inside the package, encoded once (decision 8).
public enum Link: Codable, Hashable, Sendable {
    /// Look this up, in link mode.
    case lookup(query: String, anchor: String?)
    case resource(path: String)
    case sound(path: String)
    case speak(text: String)
    case anchor(name: String)
    case blocked(why: BlockReason)
}

public enum BlockReason: Codable, Hashable, Sendable {
    case remote(url: String)
    case script
    case unknownScheme(scheme: String)
}

/// A resource, **less its bytes, which are the reply's payload** when it is found. A missing resource is a value, not
/// an error (ADR-0007 decision 8).
public enum Resource: Codable, Hashable, Sendable {
    case found(path: String, mime: String)
    case missing(path: String)
}
