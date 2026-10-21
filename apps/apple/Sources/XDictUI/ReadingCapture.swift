import Foundation
import XDictCapture
import XDictContract
import XDictLibrary

/// **When a finished document is a reading** (plan-history-and-learning §2.2): only an entry that actually drew. The
/// four facts are the entry host's — the panel is on screen, the document belongs to the lookup shown now, an entry
/// exists (not a no-results placeholder), and a sentence was captured — and the decision is one value so each of the
/// cases that must record nothing is a test rather than a hope.
public struct HistoryCapture: Equatable, Sendable {
    public let onScreen: Bool
    public let current: Bool
    public let hasEntry: Bool
    public let hasSentence: Bool

    public init(onScreen: Bool, current: Bool, hasEntry: Bool, hasSentence: Bool) {
        self.onScreen = onScreen
        self.current = current
        self.hasEntry = hasEntry
        self.hasSentence = hasSentence
    }

    /// True only when all four hold: a panel closed before its entry loaded, a no-results lookup and a stale completion
    /// each record zero readings.
    public var records: Bool { onScreen && current && hasEntry && hasSentence }
}

/// **One reading, as the history records it** (ADR-0023): the app's facts into the contract's record, one for one. The
/// app computes no identity, grouping or filter — the core does — it only says what was on screen.
public enum ReadingCapture {
    /// `cut` is the capture's own ends, in the ledger's bits (bit 0 the start, bit 1 the end); `quality` says whether the
    /// capture doubted the sentence. A missing dictionary's name and language are empty, which the core keeps as unknown.
    public static func reading(handoff: MeaningHandoff, entry: EntryRef, dictionary: LibraryEntry?,
                               at: Date, device: String) -> LedgerReading {
        let span = handoff.range.flatMap { range -> LedgerSpan? in
            guard range.location >= 0, range.length >= 0 else { return nil }
            return LedgerSpan(start: UInt32(clamping: range.location), len: UInt32(clamping: range.length))
        }
        return LedgerReading(
            surface: handoff.term,
            lemma: entry.key,
            sentence: handoff.sentence,
            span: span,
            cut: UInt8(truncatingIfNeeded: handoff.cut.rawValue),
            quality: handoff.cut.isEmpty ? "complete" : "mayBeCut",
            edition: entry.edition.rawValue,
            entryKey: entry.key,
            occurrence: entry.occurrence,
            dictionaryName: dictionary?.displayName ?? "",
            language: dictionary?.languages.pair.search ?? "",
            at: at.timeIntervalSince1970.rounded(.down),
            device: device)
    }
}

/// **Which device recorded a reading** (ADR-0025): minted once per Mac and kept in the app's defaults; the lineage stays
/// the core's. It is evidence on the card, never identity.
public enum DeviceIdentity {
    static let key = "learning.device"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let known = defaults.string(forKey: key), !known.isEmpty { return known }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: key)
        return minted
    }
}
