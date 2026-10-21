import Foundation
import Testing
import XDictClient
import XDictContract

/// **The reading history through the real service** (contract 9; ADR-0023, ADR-0024): recorded, read back by day, the
/// language filter before any byte is written, and a retried operation's one event. The service's core keeps its log in
/// the harness's own storage, so this runs the production file store, not a stand-in.
struct LedgerServiceTests {
    /// 2026-09-29 00:00 UTC: a whole day, so a reading an hour in is still that day.
    static let day: Double = 1_790_640_000
    /// 2026-09-30 01:00 UTC: the clock the drawer asks at, when the readings' day is yesterday.
    static let now: Double = 1_790_730_000

    static func reading(surface: String, sentence: String, language: String, at: Double) -> LedgerReading {
        LedgerReading(surface: surface, lemma: surface, sentence: sentence,
                      span: LedgerSpan(start: 0, len: UInt32(surface.utf16.count)), cut: 0, quality: "complete",
                      edition: "mdx-sha256-v1:" + String(repeating: "ab", count: 32), entryKey: surface,
                      occurrence: 0, dictionaryName: "Tiny", language: language, at: at, device: "test")
    }

    static func outcome(_ result: ClientOutcome) -> LedgerRecordOutcome? {
        guard case .success(let delivered) = result, case .ledgerRecord(let outcome) = delivered.answer else { return nil }
        return outcome
    }

    @Test func aReadingComesBackOnItsCalendarDayAndRepeatsCollapse() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let hold = Self.reading(surface: "hold", sentence: "They hold that view.", language: "en", at: Self.day + 1_800)

        #expect(Self.outcome(await client.call(.ledgerRecord(reading: hold, operation: "op-1", targetLanguages: [])))
                == .recorded)
        // The same reading met again, a new operation: a second event, which the day collapses into one card.
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: hold, operation: "op-2", targetLanguages: [])))
                == .recorded)

        let result = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let delivered) = result, case .ledgerHistory(let history) = delivered.answer else {
            Issue.record("no history: \(result)")
            return
        }
        #expect(delivered.payload == nil)
        #expect(history.days.count == 1)
        let day = try #require(history.days.first)
        #expect(day.id == "2026-09-29")
        #expect(day.start == Self.day)
        #expect(day.label == .yesterday)
        #expect(day.cards.count == 1)
        #expect(day.cards.first?.times == 2)
        #expect(day.cards.first?.events.count == 2, "the two meetings, each an event a removal can name")
        #expect(day.cards.first?.reading == hold, "the card carries the reading whole, the sentence included")
    }

    /// **A removed reading leaves the history and the restore brings it back** (owner, 2026-10-21; ADR-0024): the
    /// tombstone names the card's own events and carries no content, so a misread word can be repaired.
    @Test func aRemovedReadingLeavesTheHistoryAndTheRestoreBringsItBack() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let hold = Self.reading(surface: "hold", sentence: "They hold that view.", language: "en", at: Self.day + 1_800)
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: hold, operation: "op-remove-1",
                                                             targetLanguages: []))) == .recorded)
        let listed = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let delivered) = listed, case .ledgerHistory(let history) = delivered.answer,
              let events = history.days.first?.cards.first?.events else {
            Issue.record("no history: \(listed)")
            return
        }
        let removal = Removal(eventIds: events, at: Self.day + 3_600, device: "test")
        #expect(Self.outcome(await client.call(.ledgerRemove(removal: removal, operation: "op-remove-2"))) == .recorded)
        let afterRemoval = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let removed) = afterRemoval, case .ledgerHistory(let emptied) = removed.answer else {
            Issue.record("no history: \(afterRemoval)")
            return
        }
        #expect(emptied.days.isEmpty, "the removed reading is not drawn")

        #expect(Self.outcome(await client.call(.ledgerRestore(removal: removal, operation: "op-remove-3"))) == .recorded)
        let afterRestore = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let restored) = afterRestore, case .ledgerHistory(let back) = restored.answer else {
            Issue.record("no history: \(afterRestore)")
            return
        }
        #expect(back.days.first?.cards.first?.reading.surface == "hold", "the undo shows the reading again")
    }

    @Test func aRetriedOperationIsOneEvent() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let run = Self.reading(surface: "run", sentence: "They run each day.", language: "en", at: Self.day + 7_200)

        #expect(Self.outcome(await client.call(.ledgerRecord(reading: run, operation: "retry", targetLanguages: [])))
                == .recorded)
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: run, operation: "retry", targetLanguages: [])))
                == .duplicate)

        let result = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let delivered) = result, case .ledgerHistory(let history) = delivered.answer else {
            Issue.record("no history: \(result)")
            return
        }
        #expect(history.days.first?.cards.first?.times == 1, "one operation, one event")
    }

    @Test func aReadingOutsideTheTargetLanguagesWritesNothingNotEvenItsSentence() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let english = Self.reading(surface: "hold", sentence: "They hold that view.", language: "en",
                                   at: Self.day + 1_800)
        let chinese = Self.reading(surface: "词", sentence: "这是一个词。", language: "zh-Hans", at: Self.day + 3_600)
        let unknown = Self.reading(surface: "keep", sentence: "They keep that view.", language: "",
                                   at: Self.day + 5_400)

        #expect(Self.outcome(await client.call(.ledgerRecord(reading: english, operation: "en", targetLanguages: [])))
                == .recorded)
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: chinese, operation: "zh",
                                                             targetLanguages: ["en"]))) == .skippedLanguage)
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: unknown, operation: "unknown",
                                                             targetLanguages: ["en"]))) == .skippedLanguage)

        // The canary (ADR-0023, capture contract §6): the log exists, holds the kept sentence, and holds neither skipped
        // sentence — a skipped reading leaves no bytes at all.
        let log = harness.storage.appending(path: "registry/ledger/history.log")
        let bytes = try Data(contentsOf: log)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("They hold that view."))
        #expect(!text.contains("这是一个词。"))
        #expect(!text.contains("They keep that view."))

        let result = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let delivered) = result, case .ledgerHistory(let history) = delivered.answer else {
            Issue.record("no history: \(result)")
            return
        }
        #expect(history.days.first?.cards.map(\.reading.surface) == ["hold"])
    }

    @Test func anEmptyTargetSetKeepsEveryLanguageTheUnknownOneIncluded() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let unknown = Self.reading(surface: "keep", sentence: "They keep that view.", language: "",
                                   at: Self.day + 5_400)
        #expect(Self.outcome(await client.call(.ledgerRecord(reading: unknown, operation: "keep", targetLanguages: [])))
                == .recorded)
        let result = await client.call(.ledgerHistory(now: Self.now, utcOffsetSeconds: 0))
        guard case .success(let delivered) = result, case .ledgerHistory(let history) = delivered.answer else {
            Issue.record("no history: \(result)")
            return
        }
        #expect(history.days.first?.cards.first?.reading.language == "")
    }
}
