import AppKit
import XDictSearch

/// **"Did you mean?"'s guesses** (Apple parity P13): the system spell checker's, in the reader's own language and in
/// English, the language most dictionaries look words up in; the model keeps only those the library has.
struct SystemSpellingGuesser: SpellingGuesser {
    @MainActor
    func guesses(for word: String) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(word.startIndex..., in: word)
        var out: [String] = []
        for language in [checker.language(), "en"] {
            let found = checker.guesses(forWordRange: range, in: word, language: language,
                                        inSpellDocumentWithTag: 0) ?? []
            for guess in found where !out.contains(guess) { out.append(guess) }
        }
        return out
    }
}
