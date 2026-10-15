import Foundation
import XDictClient
import XDictContract
import XDictLibrary

/// **The dictionary service as the library sees it, faked**: an import answers an edition made from the MDX's bytes as
/// read through the package's own `locate` (so a moved file is read where the library says it is), and mints a lineage
/// per new edition; lineage joins and splits are kept as the core keeps them (minted, then the last association). An
/// import can be held until released or cancelled, and any file's import can be scripted to fail.
actor FakeBackend: LibraryBackend {
    private(set) var imports: [String] = []
    private(set) var opens: [String] = []
    /// The package of each MDX's last open, by file name: its `locate` is what the service's client would ask.
    private(set) var opened: [String: DictionaryPackage] = [:]
    private(set) var lineageCalls: [LineageOperation] = []
    private(set) var closed: [DictId] = []
    var failures: [String: ClientFailure] = [:]
    var problems: [String: @Sendable (String) -> [Problem]] = [:]
    var holding = false
    private var held: [Job] = []
    private var minted: [Edition: LineageId] = [:]
    private var associated: [Edition: LineageId] = [:]
    /// Where each MDX was imported: an open of the same edition at another identity answers `changed`.
    private var registered: [String: Edition] = [:]
    private var nextDict = 0

    func fail(_ fileName: String, with failure: ClientFailure) { failures[fileName] = failure }
    func hold() { holding = true }

    func release() {
        holding = false
        for job in held { job.waiting?.resume(returning: true); job.waiting = nil }
        held = []
    }

    var heldCount: Int { held.count }

    static func edition(_ package: DictionaryPackage) -> Edition? {
        guard let mdx = package.files.first(where: { $0.spec.role == .mdx }),
              let bytes = try? Data(contentsOf: mdx.locate()) else { return nil }
        return Edition(rawValue: "mdx-sha256-v1:" + bytes.map { String(format: "%02x", $0) }.joined())
    }

    static func mdxName(_ package: DictionaryPackage) -> String {
        package.files.first { $0.spec.role == .mdx }.map { $0.locate().lastPathComponent } ?? ""
    }

    func lineage(of edition: Edition) -> LineageId? { associated[edition] ?? minted[edition] }

    func beginImport(_ package: DictionaryPackage, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async
        -> ImportJob {
        let name = Self.mdxName(package)
        imports.append(name)
        let job = Job()
        Task { await self.run(package, name: name, job: job, progress: progress) }
        return ImportJob(outcome: { await job.outcome() }, cancel: { await self.cancel(job) })
    }

    private func run(_ package: DictionaryPackage, name: String, job: Job,
                     progress: @escaping @Sendable (UInt64, UInt64) -> Void) async {
        progress(1, 2)
        if holding {
            let released = await withCheckedContinuation { job.waiting = $0; held.append(job) }
            guard released else { return job.finish(.failure(.wire(.core(.cancelled(detail: "cancelled"))))) }
        }
        if let failure = failures[name] { return job.finish(.failure(failure)) }
        guard let edition = Self.edition(package) else { return job.finish(.failure(.fileUnavailable(file: UUID(), errno: ENOENT))) }
        if minted[edition] == nil { minted[edition] = LineageId(rawValue: UUID().uuidString.lowercased()) }
        let mdx = package.files.first { $0.spec.role == .mdx }
        registered[mdx?.spec.name ?? ""] = edition
        progress(2, 2)
        let info = DictInfo(title: "Title of \(name)", description: "", formatVersion: "2.0", keys: 1)
        job.finish(.success(Imported(edition: edition, lineage: lineage(of: edition) ?? LineageId(rawValue: ""), info: info,
                                     problems: problems[name]?(mdx?.spec.name ?? "") ?? [])))
    }

    private func cancel(_ job: Job) {
        guard let waiting = job.waiting else { return }
        job.waiting = nil
        held.removeAll { $0 === job }
        waiting.resume(returning: false)
    }

    func open(_ package: DictionaryPackage) async -> Result<Opened, ClientFailure> {
        let name = Self.mdxName(package)
        opens.append(name)
        opened[name] = package
        for file in package.files where !FileManager.default.fileExists(atPath: file.locate().path) {
            return .failure(.fileUnavailable(file: file.spec.id, errno: ENOENT))
        }
        let mdx = package.files.first { $0.spec.role == .mdx }
        guard let known = registered[mdx?.spec.name ?? ""] else { return .success(.needsImport(reason: .new)) }
        guard let edition = Self.edition(package), edition == known else { return .success(.needsImport(reason: .changed)) }
        nextDict += 1
        return .success(.ready(dict: DictId(rawValue: String(format: "%016x", nextDict)), edition: edition,
                               info: DictInfo(title: "Title of \(name)", description: "", formatVersion: "2.0", keys: 1)))
    }

    func close(_ dict: DictId) async -> ClientOutcome {
        closed.append(dict)
        return .success(Delivered(answer: .closed, payload: nil))
    }

    // MARK: - Health (WI-12)

    /// Every dictionary checked, in order, and every check cancelled.
    private(set) var checked: [DictId] = []
    private(set) var checksCancelled: [DictId] = []
    /// What a check answers; held checks wait until `releaseChecks`.
    var healthAnswer = Health(version: 1, entries: 1, findings: [], classes: [])
    var holdingChecks = false
    private var heldChecks: [(DictId, CheckedContinuation<Bool, Never>)] = []

    func setHealthAnswer(_ health: Health) { healthAnswer = health }
    func holdChecks() { holdingChecks = true }
    var heldCheckCount: Int { heldChecks.count }

    func beginHealth(_ dict: DictId, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async -> HealthJob {
        checked.append(dict)
        progress(0, 1)
        return HealthJob(outcome: { await self.check(dict) }, cancel: { await self.cancelCheck(dict) })
    }

    private func check(_ dict: DictId) async -> Result<Health, ClientFailure> {
        if holdingChecks, !checksCancelled.contains(dict) {
            let released = await withCheckedContinuation { heldChecks.append((dict, $0)) }
            guard released else { return .failure(.wire(.core(.cancelled(detail: "cancelled")))) }
        }
        return checksCancelled.contains(dict) ? .failure(.wire(.core(.cancelled(detail: "cancelled")))) : .success(healthAnswer)
    }

    private func cancelCheck(_ dict: DictId) {
        checksCancelled.append(dict)
        for (held, waiting) in heldChecks where held == dict { waiting.resume(returning: false) }
        heldChecks.removeAll { $0.0 == dict }
    }

    func lineage(_ operation: LineageOperation) async -> Result<LineageId?, ClientFailure> {
        lineageCalls.append(operation)
        switch operation {
        case .join(let edition, let lineage), .split(let edition, let lineage):
            associated[edition] = lineage
            return .success(lineage)
        case .of(let edition):
            return .success(lineage(of: edition))
        }
    }

    /// One import's outcome, set once.
    final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Imported, ClientFailure>?
        private var waiters: [CheckedContinuation<Result<Imported, ClientFailure>, Never>] = []
        var waiting: CheckedContinuation<Bool, Never>?

        func finish(_ outcome: Result<Imported, ClientFailure>) {
            lock.lock()
            guard result == nil else { return lock.unlock() }
            result = outcome
            let ready = waiters
            waiters = []
            lock.unlock()
            for waiter in ready { waiter.resume(returning: outcome) }
        }

        func outcome() async -> Result<Imported, ClientFailure> {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
}
