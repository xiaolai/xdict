import Foundation
import XDictClient
import XDictContract
import XDictLibrary

/// **One dictionary's part of a search, as the window shows it** (R11: every result identifies its source): its name
/// and edition, and what it has to show.
public struct ResultSection: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let edition: Edition?
    public let status: SectionStatus

    /// What the reader can do next, if anything (Q11: every state names its next action).
    public var next: NextAction? { status.next(for: id) }
}

/// What one dictionary shows for the query: its results, that it has none, or why it cannot say (Q11: no match,
/// indexing, a missing file, a damaged one and an unsupported one are told apart).
public enum SectionStatus: Hashable, Sendable {
    /// Asked; no answer yet. Nothing else waits for it (Q12).
    case searching
    case results(Results)
    /// It answered, with nothing for the query.
    case noMatch(query: String, mode: MatchMode)
    /// It cannot be asked now.
    case unavailable(Unavailable)
    /// It was asked and could not answer.
    case failed(LookupFailure)

    func next(for dictionary: UUID) -> NextAction? {
        switch self {
        case .searching, .results: nil
        // A link names a key of its own dictionary; the reader may still look the word up everywhere.
        case .noMatch(let query, .link): .searchEverywhere(query)
        case .noMatch: .checkSpelling
        case .unavailable(let why): why.next(for: dictionary)
        case .failed(let why): why.next(for: dictionary)
        }
    }
}

/// A dictionary's hits so far: every record under each key (Q10), in the core's order (the reader's dictionaries, then
/// tier, then file order: exact before folded before unmarked, ADR-0007 decision 9), with the total and the page
/// generation they continue.
public struct Results: Hashable, Sendable {
    public var hits: [Hit]
    public var total: UInt64
    public var generation: UInt32
    /// A further page is being asked for.
    public var loadingMore = false
    /// Why the last further page did not come.
    public var moreFailed: LookupFailure?

    public init(hits: [Hit], total: UInt64, generation: UInt32) {
        self.hits = hits
        self.total = total
        self.generation = generation
    }

    public var hasMore: Bool { UInt64(hits.count) < total }

    /// The keys with more than one record among these hits, whose rows say which record each is.
    public var repeatedKeys: Set<String> {
        var seen: Set<String> = [], repeated: Set<String> = []
        for hit in hits where !seen.insert(hit.entry.key).inserted { repeated.insert(hit.entry.key) }
        return repeated
    }
}

/// Why a dictionary cannot be asked now (Q11).
public enum Unavailable: Hashable, Sendable {
    /// Being imported or opened; it is asked as soon as it can answer.
    case indexing(fraction: Double?)
    /// A file of it is not where it was.
    case missingFile(String)
    /// A file of it has become a link or left its folder.
    case outsideItsFolder(String)
    /// The file is damaged (a checksum or its structure).
    case malformed
    /// The file uses something XDict does not read, named (a format, a lock, an encryption, a compression, an
    /// encoding, a size).
    case unsupported(ImportRefusal)
    /// The last import was cancelled or failed for a reason that may pass.
    case notImported(ImportRefusal)

    init(_ state: SourceState) {
        switch state {
        case .ready: self = .indexing(fraction: nil)
        case .indexing(let fraction): self = .indexing(fraction: fraction)
        case .missing(let name): self = .missingFile(name)
        case .outsideItsFolder(let name): self = .outsideItsFolder(name)
        case .refused(.damaged): self = .malformed
        case .refused(let why): self = .unsupported(why)
        case .notImported(.missingFile(let name)): self = .missingFile(name)
        case .notImported(let why): self = .notImported(why)
        }
    }

    func next(for dictionary: UUID) -> NextAction {
        switch self {
        case .indexing: .wait
        case .missingFile, .outsideItsFolder, .malformed, .unsupported: .openLibrary(dictionary)
        case .notImported: .retryImport(dictionary)
        }
    }
}

/// Why an asked dictionary did not answer.
public enum LookupFailure: Hashable, Sendable {
    /// The data read was damaged.
    case malformed
    /// The file changed under the service; the dictionary must be opened again.
    case changed
    /// More than XDict reads at once for one lookup.
    case tooLarge
    /// The dictionary service stopped, did not answer in time, or answered what XDict cannot read.
    case serviceFailed

    init?(_ failure: ClientFailure) {
        switch failure {
        case .superseded: return nil
        case .wire(.core(.malformed)): self = .malformed
        case .wire(.core(.sourceChanged)), .reopenNeedsImport, .fileUnavailable: self = .changed
        case .wire(.core(.tooLarge)): self = .tooLarge
        case .wire, .needsFiles: self = .serviceFailed
        }
    }

    func next(for dictionary: UUID) -> NextAction? {
        switch self {
        case .malformed: .openLibrary(dictionary)
        case .changed: .reopen
        case .tooLarge: nil
        case .serviceFailed: .retryLookup(dictionary)
        }
    }
}

/// What the reader can do about a section (Q11).
public enum NextAction: Hashable, Sendable {
    /// Nothing: it is asked again by itself when it can answer.
    case wait
    /// The library, at this dictionary: relink, replace or remove it.
    case openLibrary(UUID)
    /// Import this dictionary again.
    case retryImport(UUID)
    /// Ask this dictionary again.
    case retryLookup(UUID)
    /// Open the library's dictionaries again (a file changed under the service).
    case reopen
    /// Look the word up in every dictionary, as typed.
    case searchEverywhere(String)
    /// Nothing to do but check the query.
    case checkSpelling
}
