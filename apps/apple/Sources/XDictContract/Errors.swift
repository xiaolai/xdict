import Foundation

/// **Why a call has no answer.** Kinds, never sentences: the app words each for the reader in its own language
/// (ADR-0007 decision 10), and `detail`s are for logs only, never parsed, never shown.
///
/// Who makes each: the service sends `core`, `undecodable`, `contractMismatch` and `refused`; the client makes
/// `interrupted`, `invalidated` and `timedOut` itself, and `contractMismatch`, `undecodable` and
/// `refused(.payloadTooLarge)` from a reply it cannot accept (`Response.read`).
public enum WireError: Error, Codable, Hashable, Sendable {
    /// The core refused or failed, as it said.
    case core(CoreFailure)
    /// The connection broke with the call in flight (`NSXPCConnectionInterrupted`): the service exited, crashed, or
    /// refused a message. The client fails every call in flight, reconnects and opens its packages again, expecting
    /// `staleHandle` for the old handles (spike 1).
    case interrupted
    /// The connection cannot be used (`NSXPCConnectionInvalid`): no such service, or one that refused this client.
    case invalidated
    /// No reply by the call's deadline (`Deadlines`). The service may still be working; its late reply is discarded.
    case timedOut(deadline: Duration)
    /// An envelope that could not be read, or a reply that broke the contract's rules (another request's id, another
    /// operation's answer, a payload where none belongs or none where one does).
    case undecodable(detail: String)
    /// The two sides speak different contract versions; nothing else of the message was read.
    case contractMismatch(service: UInt32, client: UInt32)
    /// Refused before the core was asked, or a reply refused before anything saw it.
    case refused(Refusal)
}

/// The core's `CoreError`, one case per variant with its typed payload (ADR-0007 decision 10).
public enum CoreFailure: Codable, Hashable, Sendable {
    /// The file uses something XDict refuses, named. Never defeated (AGENTS.md).
    case unsupported(feature: Feature, detail: String)
    /// The file is damaged.
    case malformed(detail: String)
    /// A valid request for more than XDict holds at once: a limit, not damage.
    case tooLarge(limit: Limit, detail: String)
    case notFound(what: Missing, detail: String)
    case io(kind: IoKind, detail: String)
    /// A handle from a closed dictionary, a restarted service, or another page generation: open again.
    case staleHandle(detail: String)
    /// An entry reference of one edition given to a dictionary opened at another.
    case editionMismatch(detail: String)
    /// The file changed under the service (ADR-0007 decision 13; `IdentityRule`). The client re-resolves the file,
    /// then opens it again, which answers `needsImport(.changed)` for a file that really changed.
    case sourceChanged(detail: String)
    /// The import was cancelled (`cancel`).
    case cancelled(detail: String)
    /// The service's core and the protocol it was built for differ (ADR-0007 decision 11).
    case incompatible(core: UInt32, client: UInt32, detail: String)
    /// A fault in the core itself, a panic included; never the dictionary's. The core's `Internal`, renamed because
    /// `internal` is a Swift keyword (AGENTS.md).
    case internalFault(detail: String)
}

/// What `CoreFailure.unsupported` refuses: the reader's own list.
public enum Feature: Codable, Hashable, Sendable {
    case formatVersion(version: String)
    case resourceLibraryV3
    case registrationCode
    case encryptionFlags(flags: UInt8)
    case lzoInV3
    case compressionType(code: UInt32)
    case blockEncryption(code: UInt8)
    case encoding(name: String)
}

/// Which limit `CoreFailure.tooLarge` met.
public enum Limit: String, Codable, Hashable, Sendable {
    /// One of the reader's limits on a file.
    case file
    /// More results than one page holds.
    case page
    /// A body over the render context's ceiling, or the core's own.
    case body
}

/// What `CoreFailure.notFound` did not find.
public enum Missing: String, Codable, Hashable, Sendable {
    case file, entry
}

public enum IoKind: String, Codable, Hashable, Sendable {
    case notFound, permissionDenied, shortRead, outOfMemory, other
}

/// Why a request was refused before the core was asked, or a reply before anything saw it.
public enum Refusal: Error, Codable, Hashable, Sendable {
    /// A call arrived while its connection already held every credit of its class (`Credits`: two bulk, four lookup).
    /// The client counts a credited call in flight from its send until its reply or the connection's end — not until
    /// its deadline — so the two sides' counts agree and this means a client defect, not a busy service.
    case tooManyInFlight
    /// A reply's payload over the ceiling the client holds for its kind (`Limits.payloadCeiling`).
    case payloadTooLarge(bytes: UInt64, limit: UInt64)
    /// Handles and the package's files differ in number.
    case handleCountMismatch(files: Int, handles: Int)
    /// A package arrived with no handle at all (through `call`, or with an empty list). Never answered by opening a
    /// path: the contract has none.
    case missingHandle
    /// Handles arrived with an operation that reads none.
    case unexpectedHandles(count: Int)
    case invalidPackage(PackageProblem)
    /// A render context asking for a body ceiling of 0 or above the contract's.
    case renderLimitOutOfRange(requested: UInt64, ceiling: UInt64)
    /// Two tokens for one file.
    case duplicateToken(file: UUID)
    /// An operation the contract reserves and this service does not implement yet (`joinLineage`, `splitLineage`,
    /// `lineageOf`).
    case unsupportedOperation
    /// A file the operation may read came with no token (Codex objection 4). The client sends one per file of every
    /// dictionary the operation names.
    case missingToken(file: UUID)
    /// The handle sent for a file is not the file its path names now (another device or inode, or nothing there):
    /// refused before the core binds one file's bytes to another's identity (Codex objection 1). Recovered as
    /// `sourceChanged` is: re-resolve the file, open it again, send the new handle.
    case handleIsNotThePathsFile(file: UUID)
    /// The handle sent for a file is not a regular file opened read-only: a pipe, a socket, a directory, or a file
    /// opened for writing (Codex objection 7).
    case notARegularReadOnlyFile(file: UUID)
    /// An envelope larger than `Limits.maxEnvelopeBytes`, refused before it was decoded.
    case envelopeTooLarge(bytes: UInt64, limit: UInt64)
    /// A `suggest` asking for more than `Limits.maxSuggestions`.
    case suggestLimitOutOfRange(requested: UInt32, ceiling: UInt32)
}
