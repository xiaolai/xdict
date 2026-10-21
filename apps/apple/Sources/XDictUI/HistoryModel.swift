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
    /// confirmation dialog — `E4` in XiaolaiDict's UX ledger): what was hidden, until the toast goes or the next removal.
    public private(set) var lastRemoval: Removal?

    /// **Hides a card's readings behind a tombstone that carries no content** (ADR-0024): the card's own event ids, the
    /// stamp, and nothing of the sentence.
    @discardableResult
    public func remove(_ card: LedgerCard) async -> LedgerRecordOutcome? {
        let removal = Removal(eventIds: card.events, at: now().timeIntervalSince1970.rounded(.down), device: device())
        let result = await service.call(.ledgerRemove(removal: removal, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .ledgerRecord(let outcome) = delivered.answer else {
            return nil
        }
        lastRemoval = removal
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
        await refresh()
        return outcome
    }

    /// The undo window closed: the toast goes and the removal stays.
    public func clearRemoval() {
        lastRemoval = nil
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
            state = .off
            return
        }
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
