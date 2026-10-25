import Foundation
import Observation
import XDictClient
import XDictContract

/// **What the panel says about the phrase around the captured term**, decided from the core's answer alone
/// (contract 15; `dev-docs/plan-phrase-recognition.md` WI-8): a store still being read and one that could not be built
/// are rows of their own, never a quiet `none`, and a capped list says so beside the phrase it shows.
public enum PhraseRow: Equatable, Sendable {
    /// One candidate: the dictionary's own spelling, the separation it came with, and the span in the sentence.
    public struct Candidate: Equatable, Sendable {
        public let dict: DictId
        /// The dictionary's spelling, slots and all — the string a tap looks up.
        public let phrase: String
        public let separation: PhraseSeparation
        /// How many words the span stepped over.
        public let gap: UInt64
        /// The phrase's span in the sentence, UTF-16 units, gap included: what the row marks.
        public let span: NSRange

        public init(dict: DictId, phrase: String, separation: PhraseSeparation, gap: UInt64, span: NSRange) {
            self.dict = dict
            self.phrase = phrase
            self.separation = separation
            self.gap = gap
            self.span = span
        }
    }

    case hidden
    case building
    case unavailable
    /// The core's best match (the first), how many matches there were before the cap, and whether the list stopped at
    /// it. Every match is a candidate: the row says so where the gap is the matcher's own.
    case found(Candidate, total: UInt64, capped: Bool)

    /// **Every answer has its own row** (WI-8's first verification): `notAsked` and `none` have nothing to say, a
    /// building or failed store says which it is, and a found answer shows its best candidate.
    public init(_ answer: PhraseAnswer?) {
        guard let answer else { self = .hidden; return }
        switch answer.state {
        case .notAsked, .none:
            self = .hidden
        case .building:
            self = .building
        case .unavailable:
            self = .unavailable
        case .found:
            guard let first = answer.matches.first else { self = .hidden; return }
            self = .found(
                Candidate(dict: first.dict, phrase: first.phrase, separation: first.separation, gap: first.gap,
                          span: NSRange(location: Int(clamping: first.location), length: Int(clamping: first.length))),
                total: answer.total, capped: answer.capped)
        }
    }
}

/// **The phrase the captured sentence holds around its term** (contract 15; plan-phrase-recognition WI-8): one
/// question per capture, over the dictionaries that answer, and a row the panel draws.
///
/// - The question is asked when the sentence is handed in — the capture is the reader's tap — and never from a
///   lookup's text: the AI pane's sentence is the only sentence the model holds.
/// - A dictionary whose inventory is not built yet is built here once, through `phrasesBuild`, and the question asked
///   once more: the row's "reading" state ends by itself rather than waiting for another capture.
/// - A newer capture supersedes the older question (`Caller`), and a late answer is dropped by the serial, so a
///   stale phrase never lands under the newer sentence.
@MainActor
@Observable
public final class PhrasesModel {
    public private(set) var row: PhraseRow = .hidden
    /// The sentence the row's span is in: the capture's own, never a lookup's query.
    public private(set) var sentence = ""

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let caller: Caller
    /// Builds are the reader's dictionaries', not a capture's: a new capture never cancels one already running.
    @ObservationIgnored private let buildCaller: Caller
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The question whose answer is the row's: asking it again while that answer stands changes nothing.
    @ObservationIgnored private var asked: (sentence: String, term: PhraseTerm, handles: [DictId])?

    public init(backend: any SearchBackend, window: String) {
        self.backend = backend
        caller = Caller("phrases.\(window)")
        buildCaller = Caller("phrasesBuild.\(window)")
    }

    /// **A sentence was captured**: ask for the phrase covering `term`, over `handles`. The same question again while
    /// its answer stands is not re-asked; an empty sentence or no dictionary clears the row.
    public func update(sentence: String, term: PhraseTerm, handles: [DictId]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !handles.isEmpty else {
            clear()
            return
        }
        if let asked, asked.sentence == trimmed, asked.term == term, asked.handles == handles {
            return
        }
        serial += 1
        let mine = serial
        self.sentence = trimmed
        asked = nil
        row = .hidden
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(trimmed, term, handles, mine)
        }
    }

    public func clear() {
        serial += 1
        let mine = serial
        task?.cancel()
        // Withdraw a question still out, as the examples pane does: the service does not run a call no pane shows.
        task = Task { [weak self] in
            guard let self, self.serial == mine else { return }
            await self.backend.supersede(self.caller)
        }
        row = .hidden
        sentence = ""
        asked = nil
    }

    private func run(_ sentence: String, _ term: PhraseTerm, _ handles: [DictId], _ mine: Int) async {
        guard let answer = await ask(sentence, term, handles), serial == mine else { return }
        row = PhraseRow(answer)
        let building = answer.coverage.filter { $0.state == .building }.map(\.dict)
        guard !building.isEmpty else {
            asked = (sentence, term, handles)
            return
        }
        for dict in building {
            let pending = await backend.queue([.phrasesBuild(dict: dict)], as: buildCaller, superseding: false)
            _ = await pending.first?.outcome()
            guard serial == mine else { return }
        }
        guard let again = await ask(sentence, term, handles), serial == mine else { return }
        row = PhraseRow(again)
        asked = (sentence, term, handles)
    }

    private func ask(_ sentence: String, _ term: PhraseTerm, _ handles: [DictId]) async -> PhraseAnswer? {
        let pending = await backend.queue([.phrases(sentence: sentence, term: term, dicts: handles)], as: caller,
                                          superseding: true)
        guard let call = pending.first else { return nil }
        guard case .success(let answer) = await call.outcome().phraseAnswer else { return nil }
        return answer
    }

    /// Where a row's span lies in its sentence, clamped to what the sentence holds: the capture validates both, and the
    /// row never traps on a promise it did not check.
    public nonisolated static func span(_ candidate: PhraseRow.Candidate, in sentence: String) -> Range<String.Index>? {
        let length = sentence.utf16.count
        guard candidate.span.location >= 0, candidate.span.location <= length else { return nil }
        let end = min(candidate.span.location + candidate.span.length, length)
        guard end > candidate.span.location else { return nil }
        guard let start = String.Index(utf16Offset: candidate.span.location, in: sentence).samePosition(in: sentence),
              let finish = String.Index(utf16Offset: end, in: sentence).samePosition(in: sentence)
        else { return nil }
        return start..<finish
    }
}
