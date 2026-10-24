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

/// A health check under way (WI-12): its outcome, awaited, and how to stop it.
public struct HealthJob: Sendable {
    public let outcome: @Sendable () async -> Result<Health, ClientFailure>
    public let cancel: @Sendable () async -> Void

    public init(outcome: @escaping @Sendable () async -> Result<Health, ClientFailure>,
                cancel: @escaping @Sendable () async -> Void) {
        self.outcome = outcome
        self.cancel = cancel
    }
}

/// An examples build under way (ADR-0031 d.3): its outcome, awaited, and how to stop it.
public struct ExamplesJob: Sendable {
    public let outcome: @Sendable () async -> Result<ExamplesBuilt, ClientFailure>
    public let cancel: @Sendable () async -> Void

    public init(outcome: @escaping @Sendable () async -> Result<ExamplesBuilt, ClientFailure>,
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
    /// Checks an open dictionary's edition (WI-12); `progress` hears records checked of all.
    func beginHealth(_ dict: DictId, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async -> HealthJob
    /// Builds an open dictionary's example store (ADR-0031 d.3); `progress` hears records read of all.
    func beginExamplesBuild(_ dict: DictId, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async -> ExamplesJob
    /// What the reading style does to an open dictionary (ADR-0010), as the service computed it.
    func readingStyle(_ dict: DictId) async -> Result<ReadingStyle, ClientFailure>
    /// The display options an open dictionary's edition declares (ADR-0013), as the core read them in the service.
    func displayOptions(_ dict: DictId) async -> Result<DisplayOptions, ClientFailure>
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

    public func beginHealth(_ dict: DictId, progress: @escaping @Sendable (UInt64, UInt64) -> Void) -> HealthJob {
        let ticket = submitHealth(dict, progress: progress)
        return HealthJob(outcome: {
            await ticket.outcome().flatMap { delivered in
                guard case .health(let health) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not a health report")))
                }
                return .success(health)
            }
        }, cancel: { [self] in _ = await cancelImport(ticket) })
    }

    public func beginExamplesBuild(_ dict: DictId, progress: @escaping @Sendable (UInt64, UInt64) -> Void)
        -> ExamplesJob {
        let ticket = submitExamplesBuild(dict, progress: progress)
        return ExamplesJob(outcome: {
            await ticket.outcome().flatMap { delivered in
                guard case .examplesBuilt(let built) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not an examples build")))
                }
                return .success(built)
            }
        }, cancel: { [self] in _ = await cancelImport(ticket) })
    }

    public func readingStyle(_ dict: DictId) async -> Result<ReadingStyle, ClientFailure> {
        await call(.readingStyle(dict: dict)).flatMap { delivered in
            guard case .readingStyle(let style) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not a reading style")))
            }
            return .success(style)
        }
    }

    public func displayOptions(_ dict: DictId) async -> Result<DisplayOptions, ClientFailure> {
        await call(.displayOptions(dict: dict)).flatMap { delivered in
            guard case .displayOptions(let options) = delivered.answer else {
                return .failure(.wire(.undecodable(detail: "not display options")))
            }
            return .success(options)
        }
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
