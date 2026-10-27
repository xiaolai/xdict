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
        case rhymes, family, roots, forms, collocations

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
        /// What went wrong, in the shell's words; nil when nothing did.
        public var failure: String?
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
                self.page = Page(failure: String(describing: failure))
            case .none:
                self.page = Page()
            }
        }
    }

    private func load(mode: ExploreMode, word: String, dicts: [DictId]) {
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
            let pending = await backend.queue(
                [.explore(dicts: dicts, mode: mode, text: word, offset: 0, limit: limit)], as: caller, superseding: true)
            let outcome = await pending.first?.outcome()
            guard let self, mine == self.generation else { return }
            switch outcome?.explored {
            case .success(let answer):
                self.page = Page(rows: answer.rows, state: answer.state, cut: answer.exhausted)
            case .failure(let failure):
                self.page = Page(failure: String(describing: failure))
            case .none:
                self.page = Page()
            }
        }
    }
}
