import Foundation
import XDictContract
import XDictSearch

/// **The panel's words** (plan-word-exploration WI-3): the core carries labels, never sentences, so every sentence a
/// reader reads is written here.
enum ExploreSentences {
    /// A tab's name.
    static func tab(_ tab: ExploreModel.Tab) -> LocalizedStringResource {
        switch tab {
        case .rhymes: "Rhymes"
        case .family: "Family"
        case .roots: "Roots"
        case .forms: "Forms"
        case .collocations: "Collocations"
        }
    }

    /// Why a row is in the answer, under its word.
    static func reason(_ reason: ExploreReason) -> LocalizedStringResource {
        switch reason {
        case .exact: "the word itself"
        case .endsWith: "ends with it"
        case .spelling(let distance): distance == 1 ? "one letter away" : "\(distance) letters away"
        case .rhyme: "same rime"
        case .inflection: "same paradigm"
        case .derivation: "same family"
        case .sharedOrigin: "same root"
        case .collocation(let frame): frameText(frame)
        }
    }

    /// **A frame, in the reader's words** — `HW` is the word they are looking at.
    static func frameText(_ frame: CollocationFrame) -> LocalizedStringResource {
        switch frame {
        case .adjective: "adjective"
        case .adverb: "adverb"
        case .noun: "noun"
        case .verb: "verb"
        case .verbs: "verbs"
        case .preposition: "preposition"
        case .phrases: "phrase"
        case .adjectivePlusHeadword: "adjective + this word"
        case .verbPlusHeadword: "verb + this word"
        case .headwordPlusVerb: "this word + verb"
        case .headwordPlusNoun: "this word + noun"
        case .nounPlusHeadword: "noun + this word"
        case .phraseOfHeadword: "this word’s own phrase"
        }
    }

    /// What an empty, an unanswered or a cut page says. **Never a bare blank**: each state names what happened.
    static func state(_ page: ExploreModel.Page, tab: ExploreModel.Tab, word: String) -> LocalizedStringResource? {
        if let failure = page.failure { return LocalizedStringResource("The dictionaries could not be searched: \(failure)") }
        if page.loading { return "Looking…" }
        switch page.state {
        case .noData: return LocalizedStringResource("This needs the word data, which is not installed yet.")
        case .unknown: return LocalizedStringResource("The word data has nothing for “\(word)”.")
        case .answered: break
        }
        if page.rows.isEmpty { return LocalizedStringResource("Nothing in this mode for “\(word)”.") }
        if page.cut { return LocalizedStringResource("Cut short by the work budget: there may be more.") }
        return nil
    }
}
