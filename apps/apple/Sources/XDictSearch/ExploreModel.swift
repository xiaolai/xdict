import Foundation
import Observation
import XDictClient
import XDictContract

/// **Word exploration as the panel drives it** (plan-word-exploration WI-3, WI-4): one tab at a time, a page of rows
/// for the word on screen, and the states a reader must be told apart — *no word data installed*, *nothing for this
/// word*, *the answer was cut short* — drawn rather than implied.
///
/// **A late answer never lands**: every load carries a generation, and an answer whose generation is no longer the
/// current one is dropped. Superseding by generation is how a build that cannot be interrupted is left behind (the
/// catalog's own construction has no cancellation point; see the handoff).
@MainActor
@Observable
public final class ExploreModel {
    /// The questions the panel offers. **Rhymes, families, roots and forms need the word data; collocations need the
    /// per-edition store** (WI-6), which is not built yet and says so.
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case rhymes, family, roots, forms, synonyms, antonyms, collocations

        public var id: String { rawValue }

        /// Whether this tab asks the collocation call rather than an exploration mode.
        public var asksCollocations: Bool { self == .collocations }

        /// The core's mode for this tab, or nil for one nothing answers yet.
        public var mode: ExploreMode? {
            switch self {
            case .rhymes: .rhyme
            case .family: .derivations
            // Twelve edges: the depth the core measured on the reader's dictionaries (`heart` → `cordial`).
            case .roots: .roots(maxDepth: 12)
            case .forms: .inflections
            case .synonyms: .synonyms
            case .antonyms: .antonyms
            case .collocations: nil
            }
        }
    }

    /// What one tab holds now.
    public struct Page: Equatable, Sendable {
        public var rows: [ExploreRow] = []
        public var state: ExploreState = .answered
        public var cut = false
        public var loading = false
        /// The offset the service says the next page starts at, when it holds more than this page reached
        /// (audit, 2026-10-28: it was discarded, so results past the first page vanished with nothing said).
        public var next: UInt32?
        /// What went wrong, as a kind the view words; nil when nothing did (audit, 2026-10-28: it was
        /// `String(describing:)`, which showed a reader a Swift case).
        public var failure: ExploreFailure?
    }

    public private(set) var tab: Tab = .rhymes
    public private(set) var page = Page()
    /// The word the page was asked for.
    public private(set) var word = ""

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let caller: Caller
    @ObservationIgnored private let limit: UInt32
    @ObservationIgnored private var generation = 0

    public init(backend: any SearchBackend, window: String, limit: UInt32 = 100) {
        self.backend = backend
        caller = Caller("explore.\(window)")
        self.limit = limit
    }

    /// Shows `tab` for `word` in this scope, asking only when the tab can answer.
    public func show(_ tab: Tab, word: String, dicts: [DictId]) {
        self.tab = tab
        self.word = word
        if tab.asksCollocations {
            loadCollocations(word: word, dicts: dicts)
            return
        }
        guard let mode = tab.mode else {
            generation += 1
            page = Page()
            return
        }
        load(mode: mode, word: word, dicts: dicts)
    }

    /// **One more page, when the service says there is one** (audit, 2026-10-28): the rows are appended, and the tab's
    /// word is the word the pages already belong to.
    public func more(dicts: [DictId]) {
        guard let next = page.next, let mode = tab.mode else { return }
        load(mode: mode, word: word, dicts: dicts, offset: next, appending: true)
    }

    /// Asks again for the tab on screen — after the dictionaries changed, or on a retry.
    public func reload(dicts: [DictId]) {
        show(tab, word: word, dicts: dicts)
    }

    /// **The collocations the reader's own dictionaries write** (WI-6): a row per partner, the frame as its label, and
    /// the entry the dictionary said it in.
    private func loadCollocations(word: String, dicts: [DictId]) {
        generation += 1
        let mine = generation
        guard !dicts.isEmpty else {
            page = Page()
            return
        }
        page = Page(loading: true)
        let backend = self.backend
        let caller = self.caller
        let limit = self.limit
        Task { [weak self] in
            let pending = await backend.queue([.collocates(query: word, dicts: dicts, limit: limit)], as: caller,
                                              superseding: true)
            let outcome = await pending.first?.outcome()
            guard let self, mine == self.generation else { return }
            switch outcome?.collocations {
            case .success(let pairs):
                let rows = pairs.map {
                    ExploreRow(word: $0.partner, dict: $0.dict, entry: $0.entry, reason: .collocation($0.frame))
                }
                self.page = Page(rows: rows)
            case .failure(let failure):
                self.page = Page(failure: ExploreFailure(failure))
            case .none:
                self.page = Page()
            }
        }
    }

    private func load(mode: ExploreMode, word: String, dicts: [DictId], offset: UInt32 = 0,
                      appending: Bool = false) {
        generation += 1
        let mine = generation
        guard !dicts.isEmpty else {
            page = Page()
            return
        }
        page = appending ? page : Page(loading: true)
        if appending { page.loading = true }
        let backend = self.backend
        let caller = self.caller
        let limit = self.limit
        Task { [weak self] in
            let pending = await backend.queue(
                [.explore(dicts: dicts, mode: mode, text: word, offset: offset, limit: limit)], as: caller,
                superseding: !appending)
            let outcome = await pending.first?.outcome()
            guard let self, mine == self.generation else { return }
            switch outcome?.explored {
            case .success(let answer):
                let rows = appending ? self.page.rows + answer.rows : answer.rows
                self.page = Page(rows: rows, state: answer.state, cut: answer.exhausted, next: answer.next)
            case .failure(let failure):
                self.page = Page(failure: ExploreFailure(failure))
            case .none:
                self.page = Page()
            }
        }
    }
}

/// **Why an exploration could not be answered, as a kind** (ADR-0007 decision 10): the service sends kinds and the view
/// writes the sentences, so no Swift case name ever reaches a reader.
public enum ExploreFailure: Equatable, Sendable {
    /// The service is not there, or the connection has gone.
    case serviceUnavailable
    /// No answer by the call's deadline.
    case timedOut
    /// The service refused the call before it was made.
    case refused
    /// A reply that could not be read, or two contracts that differ.
    case undecodable
    /// The dictionaries themselves could not answer.
    case core
    /// A newer question replaced this one.
    case superseded
    case other

    public init(_ failure: ClientFailure) {
        switch failure {
        case .wire(.interrupted), .wire(.invalidated): self = .serviceUnavailable
        case .wire(.timedOut): self = .timedOut
        case .wire(.refused), .needsFiles: self = .refused
        case .wire(.undecodable), .wire(.contractMismatch): self = .undecodable
        case .wire(.core), .reopenNeedsImport, .fileUnavailable: self = .core
        case .superseded: self = .superseded
        case .wire(.appleImport): self = .other
        }
    }
}
