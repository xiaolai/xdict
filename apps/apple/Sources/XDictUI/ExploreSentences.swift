import Foundation
import XDictContract
import XDictSearch

/// **The panel's words** (plan-word-exploration WI-3): the core carries labels, never sentences, so every sentence a
/// reader reads is written here.
enum ExploreSentences {
    /// The row's second route: the entry the relation was read from (audit, 2026-10-28).
    static let openEntry = LocalizedStringResource("Open the Source Entry")
    /// A tab's name.
    static func tab(_ tab: ExploreModel.Tab) -> LocalizedStringResource {
        switch tab {
        case .rhymes: "Rhymes"
        case .family: "Family"
        case .roots: "Roots"
        case .forms: "Forms"
        case .synonyms: "Synonyms"
        case .antonyms: "Antonyms"
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
        case .synonym: "same meaning"
        case .antonym: "opposite meaning"
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

    /// **What went wrong, in the reader's words** (audit, 2026-10-28): each kind says what the reader can do next, and
    /// no Swift case name is ever shown.
    static func failure(_ failure: ExploreFailure) -> LocalizedStringResource {
        switch failure {
        case .serviceUnavailable: "The dictionary service is not answering. Try again."
        case .timedOut: "The dictionaries took too long. Try again."
        case .refused: "The dictionary service refused that question."
        case .undecodable: "The answer could not be read."
        case .core: "The dictionaries could not answer that question."
        case .superseded: "A newer question replaced this one."
        case .other: "That question could not be answered."
        }
    }

    /// The page's continuation, when the service says it holds more.
    static let more = LocalizedStringResource("More")

    /// **A tab that reads the word data, with none to read** (owner, 2026-10-31): a capability the system does not
    /// provide is named where the reader would choose it — what the data is, why XDict does not ship it (it is
    /// derived on this Mac from sources XDict does not redistribute), and where the reader builds it. The last
    /// sentence covers the core's second meaning of `noData`: a pack that is installed but holds none of this kind.
    static let wordDataMissing = LocalizedStringResource("""
        The word data this tab reads does not come with XDict: it is built on this Mac from its own sources' files, \
        which XDict does not redistribute. Build it with Build Word Data… in Settings ▸ Dictionaries ▸ Word data, \
        then choose this tab again. If the pack is installed already, it holds none of this kind of data.
        """, comment: "Explore: a tab that needs the word data, which is not installed or holds none of this kind")

    /// **The Collocations tab, empty** (owner, 2026-10-31): the collocation call answers an empty list both when no
    /// dictionary in the scope carries collocation sections and when the word has none in them, and the reply has no
    /// place to say which (the wire contract is unchanged), so the sentence covers both: what collocations come from,
    /// that XDict ships no dictionary, where the reader adds one, and what the other case means.
    static let noCollocations = LocalizedStringResource("""
        Collocations come from a dictionary's own collocation sections, such as the Oxford Collocations Dictionary. \
        XDict comes with no dictionaries: add it in Settings ▸ Dictionaries. If it is already in the library, this \
        word has no collocations.
        """, comment: "Explore: the Collocations tab came back with no rows")

    /// What an empty, an unanswered or a cut page says. **Never a bare blank**: each state names what happened.
    static func state(_ page: ExploreModel.Page, tab: ExploreModel.Tab, word: String) -> LocalizedStringResource? {
        if let failure = page.failure { return Self.failure(failure) }
        if page.loading { return "Looking…" }
        switch page.state {
        case .noData: return Self.wordDataMissing
        case .unknown: return LocalizedStringResource("The word data has nothing for “\(word)”.")
        case .answered: break
        }
        if page.rows.isEmpty {
            return tab == .collocations ? Self.noCollocations
                                        : LocalizedStringResource("Nothing in this mode for “\(word)”.")
        }
        if page.cut { return LocalizedStringResource("Cut short by the work budget: there may be more.") }
        return nil
    }
}
