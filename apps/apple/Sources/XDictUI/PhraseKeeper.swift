import Foundation
import Observation
import XDictClient
import XDictContract
import XDictSearch

/// **The keep's mechanism, apart from the window** (plan-context-tools WI-3; ADR-0034 d.1): one lookup finds the phrase's
/// own entry, one note makes the card — a card is a note in the ledger (`Projection::cards`), so nothing new is recorded
/// and the sentence is never written. Its own type because the rule deserves a test without a window: the calls it makes,
/// the ref it chooses, and what a superseded keep does with its late answer.
@MainActor
@Observable
public final class PhraseKeeper {
    public enum State: Equatable, Sendable {
        case idle
        case keeping
        case kept
        /// A note already exists on the phrase's entry: only the reader's yes may replace it.
        case needsReplacement
        case failed
    }

    public private(set) var state: State = .idle
    /// A newer keep supersedes an older one's late answer, as the phrase ask's serial does.
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let backend: any SearchBackend
    /// The note's write, as the window's own Save as Note path makes it.
    @ObservationIgnored private let save: @MainActor (MeaningTarget, String, Bool) async -> StudyModel.NoteSave

    public init(backend: any SearchBackend,
                save: @escaping @MainActor (MeaningTarget, String, Bool) async -> StudyModel.NoteSave) {
        self.backend = backend
        self.save = save
    }

    /// The phrase's dictionary is no longer in the library: the keep cannot name its entry, and says so.
    public func fail() {
        serial += 1
        state = .failed
    }

    /// The sentence moved on, or the presentation ended: nothing is kept and no late answer lands.
    public func reset() {
        serial += 1
        state = .idle
    }

    /// **Keep the phrase as a card**: the row's own lookup finds the entry the reader could open, and the note's text is
    /// the dictionary's spelling. `replacing` is the reader's yes after `needsReplacement`.
    public func keep(_ candidate: PhraseRow.Candidate, replacing: Bool = false) async {
        serial += 1
        let mine = serial
        state = .keeping
        let options = LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil)
        let answer = await backend.request(.lookup(query: candidate.phrase, dicts: [candidate.dict], options: options))
        // **A superseded keep presents nothing** (the phrase ask's rule): its answer belongs to a sentence the reader
        // has left, and a card written from it would name the wrong entry.
        guard serial == mine else { return }
        guard case .success(let delivered) = answer, case .page(let page) = delivered.answer,
              let hit = page.hits.first else {
            state = .failed
            return
        }
        let target = MeaningTarget(dictionary: candidate.dict, entry: hit.entry)
        switch await save(target, candidate.phrase, replacing) {
        case .saved: state = .kept
        case .needsReplacement: state = .needsReplacement
        case .failed: state = .failed
        }
    }
}
