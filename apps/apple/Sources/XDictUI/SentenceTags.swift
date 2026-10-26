import Foundation
import NaturalLanguage
import SwiftUI
import XDictTokens

/// **One word of the sentence, as the system reads it** (contract 6; plan-context-tools WI-10; ADR-0034 d.6): the
/// token, its part of speech and its lemma when the tagger gives them. Evidence shown beside the model's prose, never
/// sent to it.
public struct SentenceTag: Equatable, Sendable {
    public let token: String
    public let lexicalClass: String?
    public let lemma: String?

    public init(token: String, lexicalClass: String?, lemma: String?) {
        self.token = token
        self.lexicalClass = lexicalClass
        self.lemma = lemma
    }
}

/// **The system's reading of one sentence**: its tokens, the language the tagger recognised, and whether the measurement
/// covers that language.
public struct SentenceReading: Equatable, Sendable {
    public let tags: [SentenceTag]
    /// The tagger's dominant language, as a BCP 47 tag; nil when it could not name one.
    public let language: String?
    /// Whether `SentenceTagReader.coveredLanguages` holds the recognised language: outside it the pane shows the stated
    /// sentence instead of a half-read table.
    public let covered: Bool

    public init(tags: [SentenceTag], language: String?, covered: Bool) {
        self.tags = tags
        self.language = language
        self.covered = covered
    }
}

/// **`NLTagger`, read for the grammar answer** (plan-context-tools WI-10): every word's lexical class and lemma, and the
/// sentence's dominant language. `TextSegmenter` already trusts this framework for boundaries; this asks it for tags,
/// which is the part no shell has asked for yet.
public enum SentenceTagReader {
    /// **The languages the tagger was measured to serve** (`dev-docs/measurements/2026-10-26-context-tools/coverage.tsv`,
    /// plan-context-tools WI-1): the pane shows the system's reading only here. Outside it — the 33 languages of Apple's
    /// dictionaries that were measured for scheme availability only — the pane says so rather than drawing half a table.
    /// The measurement: every sampled language classed every word (20 languages); lemmas came only for English, German
    /// and French, so a token without one shows its class alone, never an invented lemma.
    public static let coveredLanguages: Set<String> = [
        "ar", "de", "en", "es", "fr", "he", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "th", "tr", "vi",
        "zh-Hans", "zh-Hant",
    ]

    /// One sentence read: the tags, the language, and whether that language is covered.
    public static func read(_ sentence: String) -> SentenceReading {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = sentence
        let language = tagger.dominantLanguage?.rawValue
        var tags: [SentenceTag] = []
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            tags.append(SentenceTag(token: String(sentence[range]), lexicalClass: tag?.rawValue,
                                    lemma: lemma?.rawValue))
            return true
        }
        let covered = language.map(coveredLanguages.contains) ?? false
        return SentenceReading(tags: tags, language: language, covered: covered)
    }
}

/// **The system's reading, drawn under the model's analysis** (plan-context-tools WI-10; ADR-0034 d.6): the tokens with
/// their part of speech and lemma, titled with the language the system recognised. A language outside the measured set
/// gets the stated sentence, never an empty table drawn as a reading.
public struct SystemReadingView: View {
    let sentence: String
    @State private var reading: SentenceReading?

    public init(sentence: String) {
        self.sentence = sentence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reading {
                if reading.covered, !reading.tags.isEmpty {
                    tokens(reading.tags)
                } else {
                    Text("The system has no grammatical reading for this language; the explanation above is the model's alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meaning.grammar.system.uncovered")
                }
            }
        }
        .task(id: sentence) {
            reading = SentenceTagReader.read(sentence)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meaning.grammar.system")
    }

    private var title: String {
        guard let language = reading?.language, reading?.covered == true else {
            return String(localized: "The system's reading")
        }
        return String(localized: "The system's reading — \(MeaningSentences.languageName(language))")
    }

    private func tokens(_ tags: [SentenceTag]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    Text(verbatim: tag.token)
                        .font(.caption.monospaced())
                    Text(verbatim: Self.description(of: tag))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meaning.grammar.system.tokens")
    }

    /// A token's tags as one line: its class, then its lemma when the tagger gave one, and a stated dash when it gave
    /// neither — never an invented label.
    static func description(of tag: SentenceTag) -> String {
        var parts: [String] = []
        if let lexicalClass = tag.lexicalClass { parts.append(lexicalClass) }
        if let lemma = tag.lemma, lemma != tag.token { parts.append("→ \(lemma)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
