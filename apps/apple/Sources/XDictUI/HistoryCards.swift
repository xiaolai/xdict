import Foundation
import XDictContract

/// **What a history card says, as values** (ADR-0037): the word, its lemma when the dictionary's form differs, the gloss
/// the card shows, the one-line context, and the provenance. The view draws these; the precedence between an AI answer
/// and the dictionary's own gloss is decided here, where it can be tested without a window.
public struct HistoryCardContent: Equatable, Sendable {
    public let word: String
    /// The dictionary's form, only when it differs from the word as read.
    public let lemma: String?
    public let gloss: HistoryCardGloss?
    /// The collapsed context: a window around the word, with ellipses where it was cut.
    public let context: [HistoryRuns.Run]
    public let dictionaryName: String
    public let at: Double
    public let times: UInt32

    /// **The gloss order** (ADR-0037): the reader's last answer for this exact reading, else the recorded edition's own
    /// first sense, else nothing. An answer carries the dictionary's part of speech when one was fetched, so the card
    /// keeps the word's grammar even when the wording is the model's.
    public init(card: LedgerCard, answer: String?, dictionaryGloss: HistoryCardGloss?) {
        let reading = card.reading
        word = reading.surface
        lemma = reading.lemma.isEmpty || reading.lemma == reading.surface ? nil : reading.lemma
        if let answer, !answer.isEmpty {
            gloss = HistoryCardGloss(text: answer, pos: dictionaryGloss?.pos, source: .ai)
        } else {
            gloss = dictionaryGloss
        }
        context = HistoryPreview.context(sentence: reading.sentence, span: reading.span, cut: reading.cut)
        dictionaryName = reading.dictionaryName
        at = reading.at
        times = card.times
    }
}

extension HistoryCardContent {
    /// **The card as one spoken reading** (plan item 7): its four lines in the order the card draws them, one per
    /// line. The words that are labels ("as %@", "AI answer", "Unknown dictionary") come from the catalog; the line
    /// break is the separator, so no locale's punctuation is imposed. The context is the caller's: the preview at
    /// rest, the whole sentence when opened.
    public func spoken(context: String, time: String) -> String {
        var lines: [String] = []
        var head = word
        if let lemma {
            head += " " + String(localized: "as \(lemma)")
        }
        if times > 1 {
            head += " ×\(times)"
        }
        lines.append(head)
        if let gloss {
            var parts: [String] = []
            if let pos = gloss.pos, !pos.isEmpty {
                parts.append(pos)
            }
            if gloss.source == .ai {
                parts.append(String(localized: "AI answer"))
            }
            parts.append(gloss.text)
            lines.append(parts.joined(separator: " "))
        }
        if !context.isEmpty {
            lines.append(context)
        }
        lines.append(dictionaryName.isEmpty ? String(localized: "Unknown dictionary") : dictionaryName)
        lines.append(time)
        return lines.joined(separator: "\n")
    }
}

/// A gloss and where it came from. The card says "AI" for the reader's own answer and names the dictionary for the
/// edition's text; it never presents one as the other.
public struct HistoryCardGloss: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case ai
        case dictionary
    }

    public let text: String
    /// The entry's part of speech, when the extraction found one; the AI answer may borrow it.
    public let pos: String?
    public let source: Source

    public init(text: String, pos: String? = nil, source: Source) {
        self.text = text
        self.pos = pos
        self.source = source
    }
}

/// **A sentence's one-line window around its word** (ADR-0037): graphemes from both sides, never the word itself, and an
/// ellipsis only at an end the window (or the capture) actually cut. The card's expanded state shows the whole sentence
/// instead; this is the resting cue, not a second truncation of the whole line.
public enum HistoryPreview {
    /// How many characters the resting line spends, word included. A character budget, not a layout length: at the
    /// drawer's width this leaves the word near the middle on a Latin line and still inside the visible length on a CJK
    /// one, whose characters are about twice as wide. The line limit is the visual guard; a narrower drawer clips the
    /// line's tail rather than moving the word out of it.
    public static let contextGraphemes = 40

    public static func context(sentence: String, span: LedgerSpan?, cut: UInt8,
                               budget: Int = contextGraphemes) -> [HistoryRuns.Run] {
        guard !sentence.isEmpty, budget > 0 else { return [] }
        // **The span is validated, not just clamped** (audit 2026-10-31): a corrupt record whose span falls inside a
        // surrogate pair or grapheme names no word, and the line shows the sentence's leading window instead.
        guard let range = HistoryRuns.wordRange(sentence: sentence, span: span) else {
            return first(sentence, budget: budget, cut: cut)
        }
        let wordStart = range.lowerBound
        let wordEnd = range.upperBound
        let word = String(sentence[range])
        guard !word.isEmpty else { return first(sentence, budget: budget, cut: cut) }

        let wordCount = word.count
        let remaining = max(0, budget - wordCount)
        let leftWanted = remaining / 2
        let rightWanted = remaining - leftWanted

        var leftStart = sentence.index(wordStart, offsetBy: -leftWanted, limitedBy: sentence.startIndex)
            ?? sentence.startIndex
        let leftTaken = sentence.distance(from: leftStart, to: wordStart)
        let rightEnd = sentence.index(wordEnd, offsetBy: rightWanted + (leftWanted - leftTaken),
                                      limitedBy: sentence.endIndex) ?? sentence.endIndex
        let rightTaken = sentence.distance(from: wordEnd, to: rightEnd)
        // One side ran out of sentence: spend the rest on the other rather than leave the line short.
        if rightEnd == sentence.endIndex, rightTaken < rightWanted + (leftWanted - leftTaken) {
            let extra = rightWanted + (leftWanted - leftTaken) - rightTaken
            leftStart = sentence.index(leftStart, offsetBy: -extra, limitedBy: sentence.startIndex) ?? sentence.startIndex
        }

        var runs: [HistoryRuns.Run] = []
        // The window's own cut subsumes the capture's: when the window starts later than the sentence, the capture's
        // start ellipsis would be a second one for the same end.
        if leftStart > sentence.startIndex || (leftStart == sentence.startIndex && cut & 1 != 0) {
            runs.append(.text("…"))
        }
        if leftStart < wordStart {
            runs.append(.text(String(sentence[leftStart..<wordStart])))
        }
        runs.append(.word(word))
        if rightEnd > wordEnd {
            runs.append(.text(String(sentence[wordEnd..<rightEnd])))
        }
        if rightEnd < sentence.endIndex || (rightEnd == sentence.endIndex && cut & 2 != 0) {
            runs.append(.text("…"))
        }
        return runs
    }

    /// No span (or one that names nothing): the sentence's first `budget` graphemes, with the capture's own cut marks.
    private static func first(_ sentence: String, budget: Int, cut: UInt8) -> [HistoryRuns.Run] {
        let end = sentence.index(sentence.startIndex, offsetBy: budget, limitedBy: sentence.endIndex)
            ?? sentence.endIndex
        var runs: [HistoryRuns.Run] = []
        if cut & 1 != 0 { runs.append(.text("…")) }
        runs.append(.text(String(sentence[..<end])))
        if end < sentence.endIndex || cut & 2 != 0 { runs.append(.text("…")) }
        return runs
    }
}
