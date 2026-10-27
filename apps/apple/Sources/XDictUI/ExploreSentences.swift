import Foundation
import XDictContract
import XDictSearch

/// **The panel's words** (plan-word-exploration WI-3): the core carries labels, never sentences, so every sentence a
/// reader reads is written here.
enum ExploreSentences {
    /// A tab's name.
    static func tab(_ tab: ExploreModel.Tab) -> String {
        switch tab {
        case .rhymes: "Rhymes"
        case .family: "Family"
        case .roots: "Roots"
        case .forms: "Forms"
        case .collocations: "Collocations"
        }
    }

    /// Why a row is in the answer, under its word.
    static func reason(_ reason: ExploreReason) -> String {
        switch reason {
        case .exact: "the word itself"
        case .endsWith: "ends with it"
        case .spelling(let distance): distance == 1 ? "one letter away" : "\(distance) letters away"
        case .rhyme: "same rime"
        case .inflection: "same paradigm"
        case .derivation: "same family"
        case .sharedOrigin: "same root"
        }
    }

    /// What an empty, an unanswered or a cut page says. **Never a bare blank**: each state names what happened.
    static func state(_ page: ExploreModel.Page, tab: ExploreModel.Tab, word: String) -> String? {
        if let failure = page.failure { return "The dictionaries could not be searched: \(failure)" }
        if page.loading { return "Looking…" }
        switch page.state {
        case .noData: return "This needs the word data, which is not installed yet."
        case .unknown: return "The word data has nothing for “\(word)”."
        case .answered: break
        }
        if page.rows.isEmpty && tab == .collocations {
            return "Collocations are not built yet: they come from the dictionaries' own collocation sections."
        }
        if page.rows.isEmpty { return "Nothing in this mode for “\(word)”." }
        if page.cut { return "Cut short by the work budget: there may be more." }
        return nil
    }
}
