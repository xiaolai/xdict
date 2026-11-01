import Foundation
import Observation
import XDictAI
import XDictCapture
import XDictContract

/// **The reader's answers, while the app runs** (ADR-0037): one meaning answer per reading, kept in memory so a history
/// card can show what the word meant after the answer pane has moved on. Never written, never logged, never sent
/// anywhere — the AI contract's no-persistence rule stands (§8, ADR-0021 d.8). Every entry goes at quit.
///
/// The key is the reading itself: the edition, the entry's key and occurrence, the sentence (hashed), the term and its
/// span. A different sentence, edition, occurrence or word is a different reading and never reuses an answer. Only a
/// meaning ask whose answer states a meaning is kept: `grounded` and `sentenceOnly`, `matched` and `explanationOnly`.
/// A translation, a grammar reading, a sense verdict, a phrase ask, a refusal or an ambiguity never replaces the last
/// valid answer, and a failed ask never evicts it.
@MainActor
@Observable
public final class MeaningAnswerMemory {
    /// What the card shows and the moment it was learnt.
    public struct Answer: Equatable, Sendable {
        public let text: String
        public let at: Date

        public init(text: String, at: Date) {
            self.text = text
            self.at = at
        }
    }

    /// One reading's identity, minus the text: the sentence is hashed so the key itself holds no reader words.
    private struct Key: Hashable {
        let edition: String
        let entryKey: String
        let occurrence: UInt32
        let sentence: UInt64
        let term: String
        let start: UInt32?
        let len: UInt32?
        let cut: UInt8
    }

    /// The most readings this memory holds; the oldest leaves first. A session asks about a few dozen cards, so the
    /// bound is a guard against a long-running app, not a working limit.
    public static let capacity = 200

    private var answers: [Key: Answer] = [:]
    /// Least recently stored first. A key stored again moves to the end.
    private var order: [Key] = []
    /// **Every clear or removal advances the epoch** (audit 2026-10-31): an ask that began before it holds the old
    /// value and its late answer is never stored. A removal is rare, and the cost of over-invalidating an unrelated
    /// ask in flight is one answer missing from the cards — never an erased one retained.
    public private(set) var epoch: UInt64 = 0
    /// **The app's reading-history switch**, read when an answer would be stored (ADR-0037: the history going off
    /// clears the memory and nothing repopulates it). Nil in tests, which store.
    @ObservationIgnored public var isHistoryEnabled: (@MainActor () -> Bool)?
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// **What the reader's last answer for `reading` says**, or nil when none was given, the answer was not a meaning,
    /// or it was for another sentence of the same word.
    public func answer(for reading: LedgerReading) -> String? {
        answers[Self.key(for: reading)]?.text
    }

    /// **Publishes one finished ask** — called once from `MeaningSession.finish`, after the generation check, with the
    /// epoch the ask began under. States that are not a validated answer, and answers that do not state a meaning, leave
    /// the last good one alone; an answer that began before a clear, a removal or the history switch going off is not
    /// stored at all.
    public func publish(_ state: MeaningSession.State, sent: MeaningSent?, epoch: UInt64 = 0) {
        guard epoch == self.epoch else { return }
        guard isHistoryEnabled?() ?? true else { return }
        guard case .answer(let answer, let mode) = state, let sent else { return }
        // The entry-text switch defaults off, so `sentenceOnly` is the ordinary ask; both are meanings the reader
        // asked for. `explainSense` is a verdict about a chosen sense, not a definition.
        guard mode == .grounded || mode == .sentenceOnly else { return }
        guard answer.outcome == .matched || answer.outcome == .explanationOnly else { return }
        // **The reading, not the transmitted entry** (audit 2026-10-31): a sentence-only request carries no entry, and
        // its answer still belongs to the card whose sentence was asked about.
        guard let target = sent.reading, let context = sent.questionContext else { return }
        // A phrase ask is not this word's reading; its sentence and term belong to the phrase.
        guard context.phrase == nil else { return }
        let text = answer.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = Key(edition: target.entry.edition.rawValue,
                      entryKey: target.entry.key,
                      occurrence: target.entry.occurrence,
                      sentence: Self.hash(context.sentence),
                      term: context.term,
                      start: context.range.map { UInt32(clamping: $0.location) },
                      len: context.range.map { UInt32(clamping: $0.length) },
                      cut: UInt8(truncatingIfNeeded: context.cut.rawValue))
        store(key, Answer(text: text, at: now()))
    }

    /// **The reader removed a reading**: its answer goes with it, so an undo finds the dictionary gloss, never an answer
    /// the reader had hidden. The epoch moves so an answer already on its way for it is not stored.
    public func forget(_ reading: LedgerReading) {
        epoch += 1
        remove(Self.key(for: reading))
    }

    /// The history was turned off, or the ledger erased: nothing about a reading stays in memory, and every ask in
    /// flight is stale.
    public func clear() {
        epoch += 1
        answers.removeAll()
        order.removeAll()
    }

    private func store(_ key: Key, _ answer: Answer) {
        if answers[key] == nil {
            order.append(key)
        } else {
            order.removeAll { $0 == key }
            order.append(key)
        }
        answers[key] = answer
        while answers.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            answers[oldest] = nil
        }
    }

    private func remove(_ key: Key) {
        answers[key] = nil
        order.removeAll { $0 == key }
    }

    private static func key(for reading: LedgerReading) -> Key {
        Key(edition: reading.edition,
            entryKey: reading.entryKey,
            occurrence: reading.occurrence,
            sentence: hash(reading.sentence),
            term: reading.surface,
            start: reading.span?.start,
            len: reading.span?.len,
            cut: reading.cut)
    }

    /// **FNV-1a with the final mix `HistoryCardTint` uses**: a session's handful of readings need a key, not a
    /// cryptographic digest, and the view layer binds no cryptography library (ModuleBoundaryTests). The sentence's
    /// words stay out of the key; a collision could only show another sentence's answer, and the key's other fields
    /// (entry, term, span, cut) separate readings of the same word.
    private static func hash(_ sentence: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sentence.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return hash
    }
}

extension MeaningAnswerMemory: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// **Nothing to describe**: the default mirror would print the stored answers, which the privacy tests (and any
    /// future diagnostic) must never see. Every description names the type and nothing else.
    public nonisolated var description: String { "MeaningAnswerMemory" }

    public nonisolated var debugDescription: String { "MeaningAnswerMemory" }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .class)
    }
}
