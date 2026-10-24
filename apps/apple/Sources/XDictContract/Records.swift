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
    /// What a link named: tier 1, else tier 2, internal keys included.
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

// MARK: - Words (plan-setup-v2 WI-6, ADR-0028)

/// **A page of one dictionary's words**, for Core Spotlight: the core's `Words`, with the edition it belongs to so a
/// page from another edition is not continued. No body travels beside it.
public struct Words: Codable, Hashable, Sendable {
    public let edition: Edition
    public let words: [String]
    /// Key entries in the dictionary, repeats and internal keys included: page from 0 until `from` reaches it.
    public let total: UInt64
    /// The next page's `from`, as the core counted it: not `from + words.count`.
    public let next: UInt64

    public init(edition: Edition, words: [String], total: UInt64, next: UInt64) {
        self.edition = edition
        self.words = words
        self.total = total
        self.next = next
    }
}

// MARK: - Reverse examples (ADR-0031; contract 14)

/// **The reverse-example query's answer**: the pairs whose Chinese carries the query, deduplicated across
/// dictionaries, ranked by the reader's dictionary order and then by shorter Chinese.
public struct Examples: Codable, Hashable, Sendable {
    /// At most the call's `limit`, in rank order.
    public let hits: [ExampleHit]
    /// Every distinct pair found before the limit.
    public let total: UInt64
    /// Dictionaries asked that have no store yet: still building, or never built. Never an error.
    public let notReady: [DictId]
    /// The scan reached its own bound before it ran out of pairs; `total` is then a floor.
    public let capped: Bool

    public init(hits: [ExampleHit], total: UInt64, notReady: [DictId], capped: Bool) {
        self.hits = hits
        self.total = total
        self.notReady = notReady
        self.capped = capped
    }
}

/// One example pair: the English as printed and the Chinese with the match's UTF-8 byte offsets in that printed
/// Chinese, so the pane underlines exactly what the reader typed.
public struct ExampleHit: Codable, Hashable, Sendable {
    public let english: String
    public let chinese: String
    /// The match's start, in UTF-8 bytes of `chinese` as printed.
    public let start: UInt64
    /// The match's length, in UTF-8 bytes of `chinese` as printed.
    public let len: UInt64
    /// A full sentence rather than a phrase: sentences rank first.
    public let sentence: Bool
    /// Every place the pair is printed, the first in the reader's dictionary order.
    public let sources: [ExampleSource]

    public init(english: String, chinese: String, start: UInt64, len: UInt64, sentence: Bool,
                sources: [ExampleSource]) {
        self.english = english
        self.chinese = chinese
        self.start = start
        self.len = len
        self.sentence = sentence
        self.sources = sources
    }
}

/// Where one pair is printed: a dictionary, its entry, and the headword the dictionary gives it.
public struct ExampleSource: Codable, Hashable, Sendable {
    public let dict: DictId
    public let entry: EntryRef
    public let headword: String

    public init(dict: DictId, entry: EntryRef, headword: String) {
        self.dict = dict
        self.entry = entry
        self.headword = headword
    }
}

/// **What building one dictionary's example store did** (contract 14): what the pass found, or that the store was
/// already current.
public struct ExamplesBuilt: Codable, Hashable, Sendable {
    public let edition: Edition
    public let pairs: UInt64
    /// Pairs each tier found (ADR-0031 d.2).
    public let roles: UInt64
    public let fallback: UInt64
    /// Entries read; none when the sample found no Chinese.
    public let entries: UInt64
    /// Entries passed over: a render over its ceiling, or a text the projection cut.
    public let failed: UInt64
    /// The edition has no Chinese in an evenly spaced sample: its empty store is kept and the pass skipped.
    public let noChinese: Bool
    /// The store was already there and current; nothing was read.
    public let cached: Bool

    public init(edition: Edition, pairs: UInt64, roles: UInt64, fallback: UInt64, entries: UInt64, failed: UInt64,
                noChinese: Bool, cached: Bool) {
        self.edition = edition
        self.pairs = pairs
        self.roles = roles
        self.fallback = fallback
        self.entries = entries
        self.failed = failed
        self.noChinese = noChinese
        self.cached = cached
    }
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
    /// The reader's "Original style" for the dictionary (ADR-0010 Q3): its own styles kept. The rewrite, the strip
    /// list and the policy are the same either way.
    public let originalStyle: Bool

    public init(maxBodyBytes: UInt64, originalStyle: Bool = false) {
        self.maxBodyBytes = maxBodyBytes
        self.originalStyle = originalStyle
    }
}

/// The text context of `entryText` (contract 8): the render context it shares with `entry`, plus the budget on the
/// plain text it returns, between 1 byte and `Limits.maxTextBytes`.
public struct TextRenderContext: Codable, Hashable, Sendable {
    public static let baseURL = RenderContext.baseURL

    /// See `RenderContext.maxBodyBytes`: the entry is rendered under this ceiling before it is projected.
    public let maxBodyBytes: UInt64
    /// The most UTF-8 bytes of plain text to return.
    public let maxTextBytes: UInt64
    /// See `RenderContext.originalStyle`.
    public let originalStyle: Bool

    public init(maxBodyBytes: UInt64, maxTextBytes: UInt64, originalStyle: Bool = false) {
        self.maxBodyBytes = maxBodyBytes
        self.maxTextBytes = maxTextBytes
        self.originalStyle = originalStyle
    }
}

/// One run of an entry's text: its offsets in UTF-8 bytes of `EntryText.text`, and the roles written around it
/// (ADR-0021 d.5). Unclassified text is kept, with none.
public struct TextSpan: Codable, Hashable, Sendable {
    public let start: UInt64
    public let len: UInt64
    public let role: String?
    public let label: String?
    public let section: String?
    /// The innermost sense containing this run (ADR-0029 d.2).
    public let sense: UInt32?

    public init(start: UInt64, len: UInt64, role: String?, label: String?, section: String?, sense: UInt32? = nil) {
        self.start = start
        self.len = len
        self.role = role
        self.label = label
        self.section = section
        self.sense = sense
    }
}

/// **One sense the entry's markup names** (ADR-0029 d.2): its ordinal, its canonical range in the entry's text, the
/// label as printed, its section, its parent and whether the sent text carries it whole. An ordinal is valid for one
/// `EntryRef` and one rendering revision (`EntryText.style`); it is never a durable identity.
public struct Sense: Codable, Hashable, Sendable {
    public let id: UInt32
    public let start: UInt64
    public let len: UInt64
    public let label: String?
    public let section: String?
    public let parent: UInt32?
    public let whole: Bool

    public init(id: UInt32, start: UInt64, len: UInt64, label: String?, section: String?, parent: UInt32?,
                whole: Bool) {
        self.id = id
        self.start = start
        self.len = len
        self.label = label
        self.section = section
        self.parent = parent
        self.whole = whole
    }
}

/// An entry as whole plain text, for a consumer that reads it: the text, its spans, and what the budget left out.
/// A cut is data — `complete: false` — never an error (contract 8).
public struct EntryText: Codable, Hashable, Sendable {
    public let entry: EntryRef
    public let text: String
    public let spans: [TextSpan]
    /// The senses the markup names, in document order (ADR-0029 d.2). Empty when it names none.
    public let senses: [Sense]
    /// The rendering revision the ordinals belong to (ADR-0029 d.3).
    public let style: UInt32
    public let complete: Bool
    /// UTF-8 bytes the budget left out.
    public let omittedBytes: UInt64
    /// Where the cut fell, as a byte offset in the whole entry's text (the length of `text`).
    public let cutAt: UInt64
    /// Runs (and so their roles) the budget left out.
    public let spansDropped: UInt64

    public init(entry: EntryRef, text: String, spans: [TextSpan], senses: [Sense] = [], style: UInt32 = 0,
                complete: Bool, omittedBytes: UInt64, cutAt: UInt64, spansDropped: UInt64) {
        self.entry = entry
        self.text = text
        self.spans = spans
        self.senses = senses
        self.style = style
        self.complete = complete
        self.omittedBytes = omittedBytes
        self.cutAt = cutAt
        self.spansDropped = spansDropped
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

// MARK: - Health (plan-macos-v1 WI-12; contract 3)

/// What the core's health check found in an edition: what the reader is told, and every class it counts.
public struct Health: Codable, Hashable, Sendable {
    /// The checker's version.
    public let version: UInt32
    /// Entries checked: every record of the edition.
    public let entries: UInt64
    /// Most actionable first; empty when there is nothing to say.
    public let findings: [HealthFinding]
    /// Every class counted, by its census name: kept for the record, never shown.
    public let classes: [HealthClass]

    public init(version: UInt32, entries: UInt64, findings: [HealthFinding], classes: [HealthClass]) {
        self.version = version
        self.entries = entries
        self.findings = findings
        self.classes = classes
    }
}

/// One thing the reader is told about an edition.
public struct HealthFinding: Codable, Hashable, Sendable {
    public let kind: FindingKind
    /// References, entries or characters, as the kind says.
    public let count: UInt64
    /// The file a `missingFile` names.
    public let name: String?
    /// Up to three places, as the dictionary has them.
    public let examples: [HealthExample]

    public init(kind: FindingKind, count: UInt64, name: String?, examples: [HealthExample]) {
        self.kind = kind
        self.count = count
        self.name = name
        self.examples = examples
    }
}

/// One place a finding was met: its entry's key and up to 120 characters around it.
public struct HealthExample: Codable, Hashable, Sendable {
    public let key: String
    public let text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

/// One class the check counts, by its census name.
public struct HealthClass: Codable, Hashable, Sendable {
    public let name: String
    public let count: UInt64

    public init(name: String, count: UInt64) {
        self.name = name
        self.count = count
    }
}

/// What a finding is about (`xdict-core`'s `FindingKind`).
public enum FindingKind: String, Codable, Hashable, Sendable, CaseIterable {
    case missingFile, missingSounds, missingImages, missingWords, codeAsText, commentMarks, styleAsText, brokenRedirects
    case doubleEncoded, undecodable, emptyEntries, hugeEntries, repeatedEntries, oddHeadwords, repaired
}

// MARK: - Reading style (ADR-0010, owner's decision of 2026-10-17; contract 4)

/// What the reading style does to an open dictionary: the core's report, computed in the service. Selectors, families
/// and paths are the dictionary's own text, shown as written.
public struct ReadingStyle: Codable, Hashable, Sendable {
    /// The rules' version (`xdict_core::STYLE`).
    public let version: UInt32
    /// The base size in CSS pixels, and where it was read.
    public let basePx: Double
    public let baseFrom: BaseSource
    /// The dictionary's own fonts kept, each with why.
    public let fonts: [KeptFont]
    /// The sheets read, by path; those not read, each with why.
    public let sheets: [String]
    public let skipped: [SkippedSheet]
    /// What normalizing the dictionary's sheets changed.
    public let changes: StyleChanges

    public init(version: UInt32, basePx: Double, baseFrom: BaseSource, fonts: [KeptFont], sheets: [String],
                skipped: [SkippedSheet], changes: StyleChanges) {
        self.version = version
        self.basePx = basePx
        self.baseFrom = baseFrom
        self.fonts = fonts
        self.sheets = sheets
        self.skipped = skipped
        self.changes = changes
    }
}

/// Where a dictionary's base size was read (`xdict-core`'s `BaseSource`).
public enum BaseSource: Codable, Hashable, Sendable {
    /// The page's own size (`body`, `html` or `:root`).
    case page(selector: String)
    /// The size most prose rules set, each selector one vote.
    case prose(weight: UInt64)
    /// The size most of a sample of entries' text is set in: `chars` characters, `share` of all.
    case text(chars: UInt64, share: Double)
    /// No absolute size at all: a browser's default.
    case browserDefault
}

/// A sheet the reading style did not read (`xdict-core`'s `SkippedSheet`): its path as the dictionary names it, and why.
public struct SkippedSheet: Codable, Hashable, Sendable {
    public let path: String
    public let reason: SkipReason

    public init(path: String, reason: SkipReason) {
        self.path = path
        self.reason = reason
    }
}

/// Why a sheet was not read (`xdict-core`'s `SkipReason`): a kind the view layer words. A `detail` is the core's own
/// diagnostic, in English, shown only behind a disclosure, never as the reader's sentence.
public enum SkipReason: Codable, Hashable, Sendable {
    /// Past the first `limit` sheets.
    case tooMany(limit: UInt64)
    /// Past the `limit` bytes read in all.
    case tooLarge(limit: UInt64, detail: String)
    /// Named by the dictionary, but not among its files.
    case notFound
    /// There, but could not be read.
    case unreadable(detail: String)
}

/// A font the dictionary keeps, why, and the rule that showed it.
public struct KeptFont: Codable, Hashable, Sendable {
    public let family: String
    public let reason: FontReason
    public let selector: String

    public init(family: String, reason: FontReason, selector: String) {
        self.family = family
        self.reason = reason
        self.selector = selector
    }
}

/// Why a dictionary's font is kept (`xdict-core`'s `FontReason`).
public enum FontReason: String, Codable, Hashable, Sendable, CaseIterable {
    case privateUse, pseudoContent, phonetic
}

/// What normalizing a dictionary's sheets changed, by kind.
public struct StyleChanges: Codable, Hashable, Sendable {
    public let important, page, family, size, lineHeight, colour, weight, space, dropped: UInt64

    public init(important: UInt64, page: UInt64, family: UInt64, size: UInt64, lineHeight: UInt64, colour: UInt64,
                weight: UInt64, space: UInt64, dropped: UInt64) {
        self.important = important
        self.page = page
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
        self.colour = colour
        self.weight = weight
        self.space = space
        self.dropped = dropped
    }
}

// MARK: - Display options (ADR-0013; contract 7)

/// The display options an open dictionary's edition declares, as the core's catalogue writes them: each applies where
/// the edition's markup carries its contract. `css` keys every rule on one root attribute per option; an absent
/// attribute, or a value outside the option's, means its default. No options and no CSS when none applies.
public struct DisplayOptions: Codable, Hashable, Sendable {
    /// The catalogue's version (`xdict_entry::DISPLAY_OPTIONS`).
    public let version: UInt32
    public let options: [DisplayOption]
    public let css: String

    public init(version: UInt32, options: [DisplayOption], css: String) {
        self.version = version
        self.options = options
        self.css = css
    }
}

/// One option: its id, the root attribute a shell sets to the reader's choice, its values in order, and its default for
/// the edition.
public struct DisplayOption: Codable, Hashable, Sendable {
    public let id: String
    public let attribute: String
    public let values: [String]
    public let defaultValue: String

    public init(id: String, attribute: String, values: [String], defaultValue: String) {
        self.id = id
        self.attribute = attribute
        self.values = values
        self.defaultValue = defaultValue
    }
}
