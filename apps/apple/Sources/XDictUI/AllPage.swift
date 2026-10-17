import Foundation
import XDictContract
import XDictSearch

/// **Which entry each dictionary puts on the All page** (Apple Dictionary parity P15): every dictionary in scope that
/// has a result, in the reader's order (the sections' order), one entry each. The shown result keeps its own entry; the
/// others give their hit spelled exactly as the shown headword, else their first. A dictionary with no result, or one
/// still searching, has no frame (Apple's page shows only the dictionaries that have the word); one that could not
/// search says so in the page's notices.
public enum AllPage {
    /// Whether the window shows the All page for this lookup: a typed word, over every dictionary. A link's lookup is
    /// in its own dictionary, and one dictionary chosen in the scope bar shows only that one.
    public static func applies(scope: SearchScope, mode: MatchMode) -> Bool {
        scope == .all && mode == .reader
    }

    public static func results(sections: [ResultSection], shown: ResultID, headword: String?) -> [ResultID] {
        sections.compactMap { section -> ResultID? in
            if section.id == shown.dictionary { return shown }
            guard case .results(let results) = section.status, let first = results.hits.first else { return nil }
            let hit = headword.flatMap { word in results.hits.first { $0.headword == word } } ?? first
            return ResultID(dictionary: section.id, entry: hit.entry)
        }
    }
}
