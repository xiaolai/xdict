import Foundation
import Synchronization
import XDictAppleImport
import XDictContract
@testable import XDictService
import XDictTestSupport

/// **An `AppleImports/` folder of the test's own**, standing in for the app-group container's, and snapshots staged in
/// it as the app stages them: a synthetic bundle (ADR-0011: no Apple content in a test), its folder renamed to
/// `staging/<uuid>/`.
final class AppleStaging: Sendable {
    let base: URL
    let store: AppleImportStore

    init(snapshot: SnapshotBounds = .production, converter: Bounds = .production,
         onStep: (@Sendable (ConversionStep) -> Void)? = nil) throws {
        base = FileManager.default.temporaryDirectory.appending(path: "xdict-apple-staging-\(UUID().uuidString)")
        store = AppleImportStore(root: base.appending(path: "AppleImports"), snapshot: snapshot, converter: converter,
                                 onStep: onStep)
        try FileManager.default.createDirectory(at: store.staging, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// Stages a bundle `make` writes into the folder it is given, and returns its staging UUID.
    func stage(_ make: (URL) throws -> URL) throws -> UUID {
        let scratch = base.appending(path: "scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try make(scratch)
        let id = UUID()
        try FileManager.default.moveItem(at: bundle, to: store.staging.appending(path: id.uuidString))
        return id
    }

    func stage(entries: [SyntheticAppleBundle.Entry] = SyntheticAppleBundle.defaultEntries,
               _ overrides: SyntheticAppleBundle.Overrides = .init()) throws -> UUID {
        try stage { try SyntheticAppleBundle.make(in: $0, entries: entries, overrides) }
    }

    func folder(_ id: UUID) -> URL {
        store.staging.appending(path: id.uuidString)
    }

    /// Everything in `AppleImports/` but the staging folder itself, and everything left in that: after a refused or
    /// cancelled conversion, nothing (ADR-0011 decision 5); after a published one, its folder alone.
    var leftovers: [String] {
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(atPath: store.root.path)) ?? []).filter { $0 != "staging" }
        let staged = ((try? fm.contentsOfDirectory(atPath: store.staging.path)) ?? []).map { "staging/\($0)" }
        return (top + staged).sorted()
    }

    func convert(_ id: UUID, progress: ImportProgress? = nil) -> Result<Converted, WireError> {
        AppleImports.convert(staging: id, in: store, progress: progress)
    }
}

/// Holds a conversion at its first `reading` step until the test lets it go, so the test can act while one runs.
final class StepHold: Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let held = Atomic<Bool>(false)

    var onStep: @Sendable (ConversionStep) -> Void {
        { [self] step in
            guard step.phase == .reading, !held.exchange(true, ordering: .relaxed) else { return }
            reached.signal()
            release.wait()
        }
    }

    /// Waits until a conversion is held; false after `seconds` without one.
    func waitUntilHeld(seconds: Double = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [reached] in
                continuation.resume(returning: reached.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    func letGo() {
        release.signal()
    }
}

/// Polls `condition` until it holds or `seconds` pass.
func eventually(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
