import Foundation
import Observation
import XDictClient
import XDictContract

/// What the drawer needs of the service: one call. The real client is `ServiceClient`; a test supplies its own.
public protocol HistoryService: Sendable {
    func call(_ operation: ServiceOperation) async -> ClientOutcome
}

extension ServiceClient: HistoryService {
    /// The client's one-argument call, the one the drawer and the recorder use: no caller to supersede, no generation.
    public func call(_ operation: ServiceOperation) async -> ClientOutcome {
        await call(operation, as: nil, supersedingEarlier: false)
    }
}

/// **The history the drawer draws, and the one place a reading is recorded** (ADR-0023, ADR-0024): the model asks the
/// core for the days and lets the core group, collapse and label them; it never sorts, counts or filters storage. The
/// drawer's language filter is applied to what was loaded, and nothing it does rewrites what is stored.
@MainActor
@Observable
public final class HistoryModel {
    public enum State: Equatable, Sendable {
        /// The reader's switch is off: nothing is read, and nothing is written.
        case off
        case loading
        case loaded(LedgerHistory)
        case failed
    }

    public let preferences: LearningPreferences
    public private(set) var state: State = .off

    @ObservationIgnored private let service: any HistoryService
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let utcOffset: @Sendable (Date) -> Int
    @ObservationIgnored private let device: @Sendable () -> String
    /// A refresh that a newer one replaced must not write its answer (audit rule: a superseded check cannot speak).
    @ObservationIgnored private var generation = 0

    public init(service: any HistoryService, preferences: LearningPreferences,
                now: @escaping @Sendable () -> Date = { Date() },
                utcOffset: @escaping @Sendable (Date) -> Int = { TimeZone.current.secondsFromGMT(for: $0) },
                device: @escaping @Sendable () -> String = { DeviceIdentity.current() }) {
        self.service = service
        self.preferences = preferences
        self.now = now
        self.utcOffset = utcOffset
        self.device = device
    }

    /// **The removal the drawer can undo** (owner, 2026-10-21: a misread word must be removable, and undo rather than a
    /// confirmation dialog — `E4` in XiaolaiDict's UX ledger): what was hidden, until it is undone or the next removal
    /// replaces it. **The notice's time running out does not spend it** (UI44): the header keeps Undo Remove for a reader
    /// who takes longer to find it.
    public private(set) var lastRemoval: Removal?
    /// Whether the removal's notice is up: it goes after its token-defined time, and the undo stays.
    public private(set) var removalNoticeShown = false
    /// The last removal the service refused: said in the notice, never a silent no-op.
    public private(set) var removalFailed = false

    /// What the drawer and the review window open a recorded entry through (UI46, UI48): the shell's library and main
    /// window. Nil until the app wires it; then the cards offer Open Entry.
    @ObservationIgnored public var entryLinks: HistoryEntryLinks?

    /// **The reader's answers, while the app runs** (ADR-0037): memory only, never written. A card shows one when it
    /// was given for the card's own reading. Nil until the app wires it.
    @ObservationIgnored public var answers: MeaningAnswerMemory?

    /// The answer for a card's exact reading, or nil when none was given.
    public func answer(for card: LedgerCard) -> String? {
        answers?.answer(for: card.reading)
    }

    // MARK: - The dictionary gloss (ADR-0037)

    /// What the recorded edition's gloss state is. `.loading` and `.failed` both show no line; the card keeps its other
    /// content, and nothing is said about a dictionary that cannot answer.
    public enum GlossState: Equatable, Sendable {
        case loading
        case loaded(EntryGloss)
        case failed
    }

    /// The glosses fetched this session, by the entry they belong to. A removed card's entry is forgotten.
    public private(set) var glosses: [EntryRef: GlossState] = [:]
    /// Bumped by each refresh: a card's gloss task re-runs for a failed state when the drawer opens again, and a loaded
    /// one is not asked for twice.
    public private(set) var glossRevision = 0
    /// What a card's gloss task watches: its own reading and the model's revision.
    public struct GlossRequest: Hashable, Sendable {
        public let reading: LedgerReading
        public let revision: Int

        public init(reading: LedgerReading, revision: Int) {
            self.reading = reading
            self.revision = revision
        }
    }
    @ObservationIgnored private var glossPending: [EntryRef] = []
    @ObservationIgnored private var glossInFlight = 0
    /// **The token of each entry's fetch** (audit 2026-10-31): a completion writes only while its request is still the
    /// entry's. A clear, a removal or the history switch ending the line of requests drops the answer already on its
    /// way; the slot it held is freed either way.
    @ObservationIgnored private var glossRequests: [EntryRef: UInt64] = [:]
    @ObservationIgnored private var glossNextRequest: UInt64 = 0
    /// Two at a time: one entry render each, and a drawer of visible cards must not ask the service for all of them at
    /// once. The rest wait in `glossPending` in the order they appeared.
    private static let glossLimit = 2

    /// The dictionary gloss a card shows, or nil while it is loading, after a failure, or when the edition has no
    /// usable first sense. The AI answer, when there is one, wins in `HistoryCardContent`.
    public func gloss(for card: LedgerCard) -> HistoryCardGloss? {
        let ref = EntryRef(reading: card.reading)
        guard let state = glosses[ref], case .loaded(let gloss) = state,
              let text = gloss.text, !text.isEmpty else { return nil }
        return HistoryCardGloss(text: text, pos: gloss.pos, source: .dictionary)
    }

    /// Asks for one card's gloss, once: the view calls this as a card appears. The core resolves the reading's edition
    /// itself, so a dictionary that is gone or off simply answers nothing.
    public func loadGloss(for card: LedgerCard) {
        let ref = EntryRef(reading: card.reading)
        guard glosses[ref] == nil else { return }
        glossNextRequest += 1
        glossRequests[ref] = glossNextRequest
        glosses[ref] = .loading
        glossPending.append(ref)
        pumpGlosses()
    }

    private func pumpGlosses() {
        while glossInFlight < Self.glossLimit, !glossPending.isEmpty {
            let ref = glossPending.removeFirst()
            glossInFlight += 1
            let token = glossRequests[ref]
            Task { [weak self] in
                guard let self else { return }
                let result = await self.service.call(.entryGloss(entry: ref))
                self.glossInFlight -= 1
                guard let token, self.glossRequests[ref] == token else {
                    self.pumpGlosses()
                    return
                }
                self.glossRequests[ref] = nil
                if case .success(let delivered) = result, case .entryGloss(let gloss) = delivered.answer {
                    self.glosses[ref] = .loaded(gloss)
                } else {
                    self.glosses[ref] = .failed
                }
                self.pumpGlosses()
            }
        }
    }

    /// **An erase took every reading** (ADR-0023, ADR-0037): the derived glosses go with them, and fetches already on
    /// their way are dropped. The card's AI answers are cleared by the same erase through the app's
    /// `StudyModel.onErased`.
    public func clearGlosses() {
        glosses.removeAll()
        glossPending.removeAll()
        glossRequests.removeAll()
    }

    /// **The history switch went off while the app runs** (ADR-0037): nothing about a reading stays in memory, and a
    /// refresh already on its way cannot write a loaded state over `off`.
    public func historySwitchedOff() {
        generation += 1
        answers?.clear()
        clearGlosses()
        state = .off
    }

    /// A dictionary enabled since the last open may answer now: a failed state is forgotten, and the card asks again
    /// when it appears. A loaded gloss stays: the edition's content cannot change under it.
    private func forgetFailedGlosses() {
        for (ref, state) in glosses where state == .failed {
            glosses[ref] = nil
        }
    }

    private func forgetGloss(_ reading: LedgerReading) {
        let ref = EntryRef(reading: reading)
        glosses[ref] = nil
        glossPending.removeAll { $0 == ref }
        glossRequests[ref] = nil
    }

    /// **Hides a card's readings behind a tombstone that carries no content** (ADR-0024): the card's own event ids, the
    /// stamp, and nothing of the sentence.
    @discardableResult
    public func remove(_ card: LedgerCard) async -> LedgerRecordOutcome? {
        let removal = Removal(eventIds: card.events, at: now().timeIntervalSince1970.rounded(.down), device: device())
        let result = await service.call(.ledgerRemove(removal: removal, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .ledgerRecord(let outcome) = delivered.answer else {
            removalFailed = true
            removalNoticeShown = true
            return nil
        }
        lastRemoval = removal
        removalFailed = false
        removalNoticeShown = true
        // A removed reading takes its answer with it; an undo finds the dictionary gloss, never a hidden answer.
        answers?.forget(card.reading)
        forgetGloss(card.reading)
        await refresh()
        return outcome
    }

    /// Shows the last removal's readings again: the same tombstone's shape, applied in reverse.
    @discardableResult
    public func restoreLast() async -> LedgerRecordOutcome? {
        guard let removal = lastRemoval else { return nil }
        let result = await service.call(.ledgerRestore(removal: removal, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .ledgerRecord(let outcome) = delivered.answer else {
            return nil
        }
        lastRemoval = nil
        removalNoticeShown = false
        await refresh()
        return outcome
    }

    /// The notice's time is up: it goes, and the undo stays reachable from the header.
    public func dismissRemovalNotice() {
        removalNoticeShown = false
        removalFailed = false
    }

    /// The days the drawer shows after its language filter; a day with no card left is not shown.
    public var days: [LedgerDay] {
        guard case .loaded(let history) = state else { return [] }
        guard !preferences.drawerLanguages.isEmpty else { return history.days }
        return history.days.compactMap { day in
            let cards = day.cards.filter { preferences.shows($0.reading.language) }
            guard !cards.isEmpty else { return nil }
            return LedgerDay(id: day.id, start: day.start, label: day.label, cards: cards)
        }
    }

    /// Every language the stored history holds, for the drawer's menu; empty when nothing is loaded.
    public var storedLanguages: [String] {
        guard case .loaded(let history) = state else { return [] }
        return LearningPreferences.unique(history.days.flatMap { $0.cards.map(\.reading.language) }).sorted()
    }

    /// Asks the core for the days as of now, in the reader's own zone. A refresh after the switch was turned off says
    /// `off` rather than asking.
    public func refresh() async {
        // Counted before the switch is read: turning the history off supersedes a refresh already on its way, whose
        // answer must not write a loaded state over `off`.
        generation += 1
        let mine = generation
        guard preferences.historyEnabled else {
            // Off means nothing about a reading stays in memory either: the answers and the glosses go with the history,
            // and fetches already on their way are dropped.
            historySwitchedOff()
            return
        }
        forgetFailedGlosses()
        glossRevision += 1
        state = .loading
        let at = now()
        let outcome = await service.call(.ledgerHistory(now: at.timeIntervalSince1970.rounded(.down),
                                                        utcOffsetSeconds: Int32(utcOffset(at))))
        guard mine == generation else { return }
        if case .success(let delivered) = outcome, case .ledgerHistory(let history) = delivered.answer {
            state = .loaded(history)
        } else {
            state = .failed
        }
    }

    /// **Records one reading** (ADR-0023): nothing at all when the history is off — no call, no bytes, not the word.
    /// The operation id is the retry key; an uncertain commit is retried with the same id, which settles it to one event
    /// (ADR-0024).
    @discardableResult
    public func record(_ reading: LedgerReading) async -> LedgerRecordOutcome? {
        guard preferences.historyEnabled else { return nil }
        let operation = UUID().uuidString
        let targets = preferences.targetLanguages
        let first = await send(.ledgerRecord(reading: reading, operation: operation, targetLanguages: targets))
        guard first == .uncertain else { return first }
        return await send(.ledgerRecord(reading: reading, operation: operation, targetLanguages: targets))
    }

    private func send(_ operation: ServiceOperation) async -> LedgerRecordOutcome? {
        guard case .success(let delivered) = await service.call(operation),
              case .ledgerRecord(let outcome) = delivered.answer else { return nil }
        return outcome
    }
}
