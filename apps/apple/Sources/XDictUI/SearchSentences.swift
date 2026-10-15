import Foundation
import XDictContract
import XDictLibrary
import XDictSearch

/// **What the main window tells the reader, in their language** (plan-macos-v1 WI-6; ADR-0007 decision 10: the model
/// hands kinds, the view layer words them). Every sentence is in `Strings/Localizable.xcstrings`, in English and
/// Simplified Chinese.
public enum SearchSentences {
    /// Why a dictionary's section shows no results, one sentence per state (Q11); nil for one that has results.
    public static func status(_ status: SectionStatus) -> LocalizedStringResource? {
        switch status {
        case .searching:
            LocalizedStringResource("Searching…")
        case .results:
            nil
        case .noMatch(let query, .reader):
            LocalizedStringResource("No entry for “\(query)”.")
        case .noMatch(let query, .link):
            LocalizedStringResource("This dictionary has no entry named “\(query)”.")
        case .unavailable(.indexing(let fraction?)):
            LocalizedStringResource("Being indexed (\(Int((fraction * 100).rounded()))%).")
        case .unavailable(.indexing(nil)):
            LocalizedStringResource("Being indexed.")
        case .unavailable(.missingFile(let name)):
            LibrarySentences.refusal(.missingFile(name))
        case .unavailable(.outsideItsFolder(let name)):
            LibrarySentences.phase(.outsideItsFolder(fileName: name))
        case .unavailable(.malformed):
            LibrarySentences.refusal(.damaged)
        case .unavailable(.unsupported(let why)), .unavailable(.notImported(let why)):
            LibrarySentences.refusal(why)
        case .failed(.malformed):
            LocalizedStringResource("Part of this dictionary is damaged, so this lookup could not be read.")
        case .failed(.changed):
            LocalizedStringResource("This dictionary’s file changed while XDict was reading it.")
        case .failed(.tooLarge):
            LocalizedStringResource("This lookup asks for more than XDict reads at once.")
        case .failed(.serviceFailed):
            LocalizedStringResource("The dictionary service did not answer this lookup.")
        }
    }

    /// What the reader can do next (Q11): a button's title, or a sentence where there is nothing to press.
    public static func action(_ next: NextAction) -> LocalizedStringResource {
        switch next {
        case .wait: LocalizedStringResource("It is looked up as soon as it is ready.")
        case .openLibrary: LocalizedStringResource("Show in Library")
        case .retryImport: LocalizedStringResource("Import Again")
        case .retryLookup: LocalizedStringResource("Try Again")
        case .reopen: LocalizedStringResource("Open Again")
        case .searchEverywhere(let query): LocalizedStringResource("Look Up “\(query)” in Every Dictionary")
        case .checkSpelling: LocalizedStringResource("Check the spelling, or try a shorter form of the word.")
        }
    }

    /// Whether `next` is something to press, rather than something to read.
    public static func isButton(_ next: NextAction) -> Bool {
        switch next {
        case .wait, .checkSpelling: false
        case .openLibrary, .retryImport, .retryLookup, .reopen, .searchEverywhere: true
        }
    }

    /// Why a result matched (Q4).
    public static func reason(_ how: How) -> LocalizedStringResource {
        switch how {
        case .exact: LocalizedStringResource("Exact match")
        case .folded: LocalizedStringResource("Matched ignoring case or punctuation, as this dictionary does")
        case .unmarked: LocalizedStringResource("Matched without accents or marks")
        case .redirect(let chain): LocalizedStringResource("Reached from \(chain.joined(separator: " → "))")
        }
    }

    /// Which of the records under one key a result is, counted from 1.
    public static func record(_ number: Int) -> LocalizedStringResource {
        LocalizedStringResource("record \(number)")
    }

    /// A result as VoiceOver reads it (R10), naming its dictionary (R11).
    public static func result(headword: String, how: How, record number: Int?, dictionary: String)
        -> LocalizedStringResource {
        let why = String(localized: reason(how))
        guard let number else { return LocalizedStringResource("\(headword), \(why), in \(dictionary)") }
        return LocalizedStringResource("\(headword), \(String(localized: record(number))), \(why), in \(dictionary)")
    }

    /// An edition, shortened to the first eight digits of its hash (the whole one is in the library's details). Not
    /// words: the same in every language.
    public static func edition(_ edition: Edition) -> String {
        guard let colon = edition.rawValue.lastIndex(of: ":") else { return edition.rawValue }
        return String(edition.rawValue[edition.rawValue.index(after: colon)...].prefix(8))
    }

    /// How many results a dictionary has, and how many are shown (Q10).
    public static func count(loaded: Int, total: UInt64) -> LocalizedStringResource {
        if UInt64(loaded) >= total {
            return total == 1 ? LocalizedStringResource("1 result") : LocalizedStringResource("\(total) results")
        }
        return LocalizedStringResource("\(loaded) of \(total) shown")
    }

    /// The button that shows the next page.
    public static func more(_ count: UInt64, remaining: UInt64) -> LocalizedStringResource {
        LocalizedStringResource("Show \(min(count, remaining)) More")
    }

    /// What the scope picker calls every enabled dictionary.
    public static let allDictionaries = LocalizedStringResource("All Dictionaries")

    /// The header of a section with nothing to count, as VoiceOver reads it: whose, which edition.
    public static func section(name: String, edition: Edition?) -> LocalizedStringResource {
        guard let edition else { return LocalizedStringResource("\(name)") }
        return LocalizedStringResource("\(name), edition \(self.edition(edition))")
    }

    /// A section's header as VoiceOver reads it: whose results, which edition, how many.
    public static func section(name: String, edition: Edition?, loaded: Int, total: UInt64) -> LocalizedStringResource {
        let counted = String(localized: count(loaded: loaded, total: total))
        guard let edition else { return LocalizedStringResource("\(name), \(counted)") }
        return LocalizedStringResource("\(name), edition \(self.edition(edition)), \(counted)")
    }
}
