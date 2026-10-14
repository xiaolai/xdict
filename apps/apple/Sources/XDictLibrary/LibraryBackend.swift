import Foundation
import XDictClient
import XDictContract

/// A lineage operation of the contract (ADR-0002 decision 3, as amended 2026-10-14).
public enum LineageOperation: Hashable, Sendable {
    case join(Edition, LineageId)
    case split(Edition, LineageId)
    case of(Edition)

    var operation: ServiceOperation {
        switch self {
        case .join(let edition, let lineage): .joinLineage(edition: edition, lineage: lineage)
        case .split(let edition, let lineage): .splitLineage(edition: edition, newLineage: lineage)
        case .of(let edition): .lineageOf(edition: edition)
        }
    }
}

/// An import under way: its outcome, awaited, and how to stop it.
public struct ImportJob: Sendable {
    public let outcome: @Sendable () async -> Result<Imported, ClientFailure>
    public let cancel: @Sendable () async -> Void

    public init(outcome: @escaping @Sendable () async -> Result<Imported, ClientFailure>,
                cancel: @escaping @Sendable () async -> Void) {
        self.outcome = outcome
        self.cancel = cancel
    }
}

/// **What the library asks of the dictionary service**: `ServiceClient` in the app, a fake in the library's own tests.
public protocol LibraryBackend: Sendable {
    func beginImport(_ package: DictionaryPackage, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async
        -> ImportJob
    func open(_ package: DictionaryPackage) async -> Result<Opened, ClientFailure>
    func close(_ dict: DictId) async -> ClientOutcome
    /// A join, a split, or the lineage an edition has; for a join or a split, the lineage the edition now has.
    func lineage(_ operation: LineageOperation) async -> Result<LineageId?, ClientFailure>
}

extension ServiceClient: LibraryBackend {
    public func beginImport(_ package: DictionaryPackage, progress: @escaping @Sendable (UInt64, UInt64) -> Void)
        -> ImportJob {
        let ticket = submitImport(package, progress: progress)
        return ImportJob(outcome: {
            await ticket.outcome().flatMap { delivered in
                guard case .imported(let imported) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not imported")))
                }
                return .success(imported)
            }
        }, cancel: { [self] in _ = await cancelImport(ticket) })
    }

    public func lineage(_ operation: LineageOperation) async -> Result<LineageId?, ClientFailure> {
        await call(operation.operation).flatMap { delivered in
            guard case .lineage(let lineage) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not a lineage")))
            }
            return .success(lineage)
        }
    }
}
