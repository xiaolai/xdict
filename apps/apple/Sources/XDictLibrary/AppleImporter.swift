import Foundation
import Observation
import XDictAppleSource
import XDictClient
import XDictContract
import os

/// A conversion under way in the service: its outcome, awaited, and how to stop it.
public struct ConversionJob: Sendable {
    public let outcome: @Sendable () async -> Result<Converted, ClientFailure>
    public let cancel: @Sendable () async -> Void

    public init(outcome: @escaping @Sendable () async -> Result<Converted, ClientFailure>,
                cancel: @escaping @Sendable () async -> Void) {
        self.outcome = outcome
        self.cancel = cancel
    }
}

/// **What the Apple import asks of the dictionary service** (contract 6): `ServiceClient` in the app, a fake in tests.
public protocol AppleConversionBackend: Sendable {
    func beginConversion(staging: UUID, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async -> ConversionJob
}

extension ServiceClient: AppleConversionBackend {
    public func beginConversion(staging: UUID, progress: @escaping @Sendable (UInt64, UInt64) -> Void) -> ConversionJob {
        let ticket = submitConvertApple(staging: staging, progress: progress)
        return ConversionJob(outcome: {
            await ticket.outcome().flatMap { delivered in
                guard case .converted(let converted) = delivered.answer else {
                    return .failure(.wire(.undecodable(detail: "not a conversion")))
                }
                return .success(converted)
            }
        }, cancel: { [self] in _ = await cancelConversion(ticket) })
    }
}

/// Where one bundle's import is, this session.
public enum AppleImportStep: Hashable, Sendable {
    case waiting
    /// Its files being copied into the shared container.
    case copying
    /// The service converting the copy: its own count of all.
    case converting(done: UInt64, total: UInt64)
    case cancelling
    /// Converted and handed to the library, whose import of it shows in Settings like any other.
    case added(UUID)
    case cancelled
    case failed(AppleImportFailure)
}

/// Why a bundle was not imported. Kinds, never sentences.
public enum AppleImportFailure: Error, Hashable, Sendable {
    /// The service (or the copy) refused it, for a named reason.
    case refused(AppleImportRefusal)
    /// The app has no shared container (unsigned, or no entitlement).
    case noContainer
    /// The service did not answer, or answered something else: try again.
    case service
    /// What the service published is not a dictionary the library could add.
    case notAdded
}

/// **Add Apple Dictionaries…, and Convert Again** (ADR-0011 decisions 4, 8, 9 and 10; plan WI-5): each chosen bundle is
/// copied byte for byte into `AppleImports/staging/<uuid>/`, converted by the service into `AppleImports/<conversion>/`,
/// and handed to the library's ordinary import with its source record. One at a time, each cancellable. A crash or a lost
/// reply at any step leaves a staging folder or an unnamed output folder, which the launch sweep removes; never a second
/// lineage or a false "Already imported", since only the library's entry says a bundle is imported.
@MainActor
@Observable
public final class AppleImporter {
    public private(set) var steps: [String: AppleImportStep] = [:]

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let backend: any AppleConversionBackend
    @ObservationIgnored private let root: URL?
    @ObservationIgnored private let bounds: SnapshotBounds
    @ObservationIgnored private let log = Logger(subsystem: "ai.xdict.app", category: "apple-import")
    @ObservationIgnored private var queue: [Work] = []
    @ObservationIgnored private var running: Running?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A bundle to import, or to convert again for the dictionary it already is.
    private struct Work {
        let bundle: InstalledBundle
        let again: UUID?
    }

    private final class Running {
        let identifier: String
        var job: ConversionJob?
        var cancelled = false

        init(identifier: String) {
            self.identifier = identifier
        }
    }

    /// `root` is `AppleImports/` in the shared container (`SharedContainer.appleImports()`), nil when there is none.
    public init(library: Library, backend: any AppleConversionBackend, root: URL?, bounds: SnapshotBounds = .production) {
        self.library = library
        self.backend = backend
        self.root = root
        self.bounds = bounds
    }

    /// Whether any bundle is waiting or under way.
    public var isWorking: Bool { running != nil || !queue.isEmpty }

    /// Queues the chosen bundles' imports; one already imported, refused or under way is left as it is.
    public func importBundles(_ bundles: [InstalledBundle]) {
        let imported = library.importedAppleBundles
        for bundle in bundles where bundle.refusal == nil && !imported.contains(bundle.identifier) {
            enqueue(Work(bundle: bundle, again: nil))
        }
    }

    /// Convert Again for the dictionary `id`, from `bundle` as installed now.
    public func convertAgain(_ id: UUID, from bundle: InstalledBundle) {
        enqueue(Work(bundle: bundle, again: id))
    }

    /// Stops a bundle's import: one waiting never starts; one copying or converting stops at its next step.
    public func cancel(_ identifier: String) async {
        if let at = queue.firstIndex(where: { $0.bundle.identifier == identifier }) {
            queue.remove(at: at)
            steps[identifier] = .cancelled
            return wake()
        }
        guard let current = running, current.identifier == identifier, !current.cancelled else { return }
        current.cancelled = true
        steps[identifier] = .cancelling
        await current.job?.cancel()
    }

    /// Forgets finished steps (the sheet closed): what is waiting or under way stays.
    public func clearFinished() {
        steps = steps.filter { _, step in
            switch step {
            case .waiting, .copying, .converting, .cancelling: true
            case .added, .cancelled, .failed: false
            }
        }
    }

    /// **The launch sweep** (decision 9), run once the library is read; never while it cannot be, when every folder
    /// would look unnamed.
    @discardableResult
    public func sweep(now: Date = Date()) -> AppleImportSweep.Report? {
        guard let root, let referenced = library.appleConversions else { return nil }
        let report = AppleImportSweep.sweep(root, referenced: referenced, now: now)
        if report != AppleImportSweep.Report() {
            log.notice("swept \(report.staging.count) staging and \(report.outputs.count) unnamed conversion folders")
        }
        return report
    }

    /// **Compares every Apple dictionary with its installed bundle** (decision 7) and records it in the library.
    public func checkForUpdates(installed: [InstalledBundle]) async {
        let wanted = library.importedAppleBundles
        guard !wanted.isEmpty else { return library.setAppleStatus(installed: [:]) }
        library.setAppleStatus(installed: await InstalledSource.current(of: installed, wanted: wanted))
    }

    /// Whether nothing is waiting or under way by `limit`: true as soon as that is so.
    public func settled(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        let alarm = Task { [weak self] in
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            self?.wakeEveryWaiter()
        }
        defer { alarm.cancel() }
        while isWorking {
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { waiters.append($0) }
        }
        return true
    }

    // MARK: - The work

    private func enqueue(_ work: Work) {
        let identifier = work.bundle.identifier
        guard running?.identifier != identifier, !queue.contains(where: { $0.bundle.identifier == identifier }) else { return }
        queue.append(work)
        steps[identifier] = .waiting
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return wake() }
        let work = queue.removeFirst()
        let current = Running(identifier: work.bundle.identifier)
        running = current
        Task { await self.run(work, current) }
    }

    private func run(_ work: Work, _ current: Running) async {
        defer {
            running = nil
            pump()
        }
        let identifier = work.bundle.identifier
        steps[identifier] = finish(work, current, await convert(work, current))
    }

    /// Copy, then convert: the conversion, or why not.
    private func convert(_ work: Work, _ current: Running) async -> Result<(Converted, URL), AppleImportFailure> {
        guard let root else { return .failure(.noContainer) }
        steps[work.bundle.identifier] = .copying
        let (bundle, bounds) = (work.bundle.url, bounds)
        let copied = await Task.detached(priority: .userInitiated) { () -> Result<UUID, AppleImportRefusal> in
            do throws(AppleImportRefusal) { return .success(try SnapshotCopy.copy(bundle, into: root, bounds: bounds)) } catch {
                return .failure(error)
            }
        }.value
        let staging: UUID
        switch copied {
        case .success(let id): staging = id
        case .failure(let refusal): return .failure(.refused(refusal))
        }
        let folder = SharedContainer.staging(in: root).appending(path: staging.uuidString, directoryHint: .isDirectory)
        // The service removes its staging folder whatever happens; one it never received goes here, or at the sweep.
        defer { try? FileManager.default.removeItem(at: folder) }
        guard !current.cancelled else { return .failure(.service) }
        let identifier = work.bundle.identifier
        steps[identifier] = .converting(done: 0, total: 0)
        let job = await backend.beginConversion(staging: staging) { [weak self] done, total in
            Task { @MainActor in
                guard let self, let running = self.running, running.identifier == identifier, !running.cancelled else { return }
                self.steps[identifier] = .converting(done: done, total: total)
            }
        }
        current.job = job
        if current.cancelled { await job.cancel() }
        switch await job.outcome() {
        case .success(let converted):
            return .success((converted, root.appending(path: converted.conversion.uuidString, directoryHint: .isDirectory)))
        case .failure(.wire(.appleImport(let refusal))):
            return .failure(.refused(refusal))
        case .failure(let failure):
            log.error("a conversion failed: \(String(describing: failure), privacy: .public)")
            return .failure(.service)
        }
    }

    /// Hands a conversion to the library, with its source record (decision 10).
    private func finish(_ work: Work, _ current: Running, _ outcome: Result<(Converted, URL), AppleImportFailure>)
        -> AppleImportStep {
        if current.cancelled { return .cancelled }
        switch outcome {
        case .failure(let failure):
            return .failed(failure)
        case .success(let (converted, folder)):
            let source = AppleSourceRecord(converted, bundle: work.bundle)
            if let id = work.again {
                return library.convertAgain(id, in: folder, source: source) ? .added(id) : .failed(.notAdded)
            }
            let languages = LanguagePair(search: work.bundle.searchLanguage, explanation: work.bundle.explanationLanguage)
            return library.addConversion(in: folder, source: source, languages: languages).map(AppleImportStep.added)
                ?? .failed(.notAdded)
        }
    }

    private func wake() {
        guard !isWorking else { return }
        wakeEveryWaiter()
    }

    private func wakeEveryWaiter() {
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}
