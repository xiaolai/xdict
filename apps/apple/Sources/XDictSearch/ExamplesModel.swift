import Foundation
import Observation
import XDictClient
import XDictContract

/// **The reverse-example results for the main window** (ADR-0031, plan-reverse-examples WI-5): when the reader's
/// lookup is Chinese, the core is asked for the pairs whose Chinese carries it, from the dictionaries in scope.
///
/// - The core scans its stores; this model never reads a dictionary. A dictionary still building its store comes back
///   in `notReady`, and the model asks again when the library reports that build ready — never in the query itself.
/// - A newer lookup supersedes the older (`Caller`), so a late answer for the previous word is never painted.
/// - The hits are the core's: deduplicated, ranked by dictionary order and then shorter Chinese, each with the match's
///   byte range in the printed Chinese for the underline.
@MainActor
@Observable
public final class ExamplesModel {
    /// The query the hits belong to; empty when the lookup is not Chinese.
    public private(set) var query = ""
    public private(set) var hits: [ExampleHit] = []
    /// Every distinct pair found, before the page's 100.
    public private(set) var total: UInt64 = 0
    /// Dictionaries asked that have no store yet: still building, or never built.
    public private(set) var notReady: [DictId] = []
    public private(set) var capped = false
    /// The service failed the query; the section says so rather than showing the previous word's hits.
    public private(set) var failed = false
    /// A Chinese lookup was asked (whether or not it found anything yet).
    public private(set) var asked = false
    /// Dictionaries whose build failed this session (the library's `unavailable`): their missing store is a failure,
    /// not a build still running, and the section says so.
    public private(set) var unavailable: Set<DictId> = []
    /// Counts every completed answer, failure and clear: the pane observes it, because two queries that both have
    /// content leave `hasContent` true and would never reopen the section (audit, 2026-10-24).
    public private(set) var revision: UInt64 = 0

    /// Whether the pane has anything to show: hits, dictionaries still preparing, or a failure to report.
    public var hasContent: Bool { !hits.isEmpty || !notReady.isEmpty || failed }

    /// The dictionaries still preparing, which are not the ones whose build failed.
    public var preparing: [DictId] { notReady.filter { !unavailable.contains($0) } }

    /// **The unready dictionaries whose build failed this session** (audit round 2, 2026-10-25): a failure beside a
    /// dictionary still building is a failure to report, not just a build to wait for.
    public var failedToPrepare: [DictId] { notReady.filter { unavailable.contains($0) } }


    /// The page the pane asks for (ADR-0031 d.9).
    public static let page: UInt32 = 100

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let caller: Caller
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastHandles: [DictId] = []
    /// The query and handles whose answer is the one held: only that answer may be reused. A pending ask leaves it
    /// nil, so repeating a query while its first ask is still out never paints the previous query's hits under it
    /// (audit, 2026-10-24).
    @ObservationIgnored private var answered: (query: String, handles: [DictId])?
    @ObservationIgnored private var lastReady: Set<DictId> = []

    public init(backend: any SearchBackend, window: String) {
        self.backend = backend
        caller = Caller("examples.\(window)")
    }

    /// **A lookup changed**: ask for its examples when it carries Chinese, clear when it does not. The same query
    /// over the same dictionaries, while its hits are current, changes nothing and returns true — the pane reopens
    /// on what is already here; the same query over other dictionaries (a scope change, a disable, a reorder) is a
    /// new ask. `unavailable` is the library's failed-store set at this moment, so a store that failed while a
    /// Latin word was shown is still known to have failed.
    @discardableResult
    public func update(query: String, handles: [DictId], unavailable: [DictId] = []) -> Bool {
        self.unavailable = Set(unavailable)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasCJK(trimmed), !handles.isEmpty else {
            lastHandles = []
            clear()
            return false
        }
        if trimmed == self.query, handles == lastHandles, asked, !failed, notReady.isEmpty,
           answered?.query == trimmed, answered?.handles == handles {
            return true
        }
        lastHandles = handles
        ask(trimmed, handles)
        return false
    }

    /// **The library's example stores changed**: ask again once, when a dictionary that was still building is ready;
    /// a dictionary whose build failed is named so the section does not say it is still preparing.
    public func buildStateChanged(ready: [DictId], unavailable: [DictId] = []) {
        // **The snapshot is the library's, and comparisons are the query's** (audit round 4, 2026-10-25): keeping only the
        // last scope's ready set made a scope switch compare {B} with {A} and re-ask for nothing.
        let previousFailures = self.unavailable.intersection(lastHandles)
        let failures = Set(unavailable).intersection(lastHandles)
        let before = lastReady.intersection(lastHandles)
        let after = Set(ready).intersection(lastHandles)
        lastReady = Set(ready)
        self.unavailable = Set(unavailable)
        let readyChanged = after != before
        guard readyChanged || failures != previousFailures else { return }
        // **Only a visible change is announced**: a failure on a dictionary the answer did not name changes nothing.
        if answered != nil, failures.intersection(notReady) != previousFailures.intersection(notReady) {
            revision &+= 1
        }
        guard asked, readyChanged else { return }
        ask(query, lastHandles)
    }

    public func clear() {
        serial += 1
        let mine = serial
        task?.cancel()
        // **Clearing withdraws the query still out** (audit round 3, 2026-10-25): the service does not run a query no pane
        // shows. A later ask advances `serial` first, so this withdrawal cannot cancel it.
        task = Task { [weak self] in
            guard let self, self.serial == mine else { return }
            await self.backend.supersede(self.caller)
        }
        query = ""
        hits = []
        total = 0
        notReady = []
        capped = false
        failed = false
        asked = false
        unavailable = []
        lastReady = []
        answered = nil
        revision &+= 1
    }

    private func ask(_ query: String, _ handles: [DictId]) {
        serial += 1
        let mine = serial
        self.query = query
        asked = true
        failed = false
        answered = nil
        // **The fields belong to the query that produced them** (audit round 4): a new query starts from nothing, never
        // under the previous query's hits.
        hits = []
        total = 0
        notReady = []
        capped = false
        task?.cancel()
        let operation = ServiceOperation.examples(query: query, dicts: handles, limit: Self.page)
        let (backend, caller) = (backend, caller)
        task = Task { [weak self] in
            // **A request cancelled before it started is never submitted** (audit round 3, 2026-10-25).
            guard !Task.isCancelled else { return }
            let pending = await backend.queue([operation], as: caller, superseding: true)
            guard let outcome = await pending.first?.outcome(), let self else { return }
            // **Every answer the model receives is counted** (audit round 4, 2026-10-25): a test can wait for a late
            // answer to have been read before asserting it changed nothing. Counted before the serial guard, which is
            // the decision this counter exists to make observable.
            self.answersRead &+= 1
            guard self.serial == mine else { return }
            switch outcome.examples {
            case .success(let examples):
                self.hits = examples.hits
                self.total = examples.total
                self.notReady = examples.notReady
                self.capped = examples.capped
                self.failed = false
            case .failure:
                self.hits = []
                self.total = 0
                self.notReady = []
                self.capped = false
                self.failed = true
            }
            self.answered = (query, handles)
            self.revision &+= 1
        }
    }

    /// **Answers this model has received** (audit round 4, 2026-10-25): not observable by the view, and read by the
    /// tests to wait for a late answer's arrival without a clock.
    @ObservationIgnored public private(set) var answersRead = 0

    /// Whether the text carries a CJK character, so the feature applies: the same ranges the core scans.
    public static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }
}
