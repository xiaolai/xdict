import XDictContract
import XDictSearch

/// **Which entry each dictionary puts on the All page** (Apple Dictionary parity P15): every dictionary in scope that
/// has a result, in the reader's order (the sections' order), one entry each. The shown result keeps its own entry; the
/// others give their hit spelled exactly as the shown headword, else their first. A dictionary with no result, or one
/// still searching, has no frame (Apple's page shows only the dictionaries that have the word); one that could not
/// search says so in the page's notices.
public enum AllPage {
    /// Whether the window shows the All page for this lookup: a typed word, over every dictionary. A link's lookup is
    /// in its own dictionary, and one dictionary chosen in the search field's scope menu shows only that one.
    public static func applies(scope: SearchScope, mode: MatchMode) -> Bool {
        scope == .all && mode == .reader
    }

    public static func results(sections: [ResultSection], shown: ResultID, headword: String?) -> [ResultID] {
        sections.compactMap { section -> ResultID? in
            // **The shown dictionary obeys its own status too** (audit round 3, 2026-10-25): `SearchModel.begin()` can
            // keep a previous lookup's shown result while its section is searching or has nothing, and that frame must
            // not appear on the new page.
            if section.id == shown.dictionary {
                guard case .results = section.status else { return nil }
                return shown
            }
            guard let hit = hit(in: section, headword: headword) else { return nil }
            return ResultID(dictionary: section.id, entry: hit.entry)
        }
    }

    /// **The hit one dictionary's frame shows**: the hit spelled exactly as the shown headword when it has one, else its
    /// first — the rule `results` uses for every other dictionary, read here by any caller that needs one frame's word
    /// (the recording fallback; audit round 2, 2026-10-25).
    public static func hit(in section: ResultSection, headword: String?) -> Hit? {
        guard case .results(let results) = section.status, let first = results.hits.first else { return nil }
        return headword.flatMap { word in results.hits.first { $0.headword == word } } ?? first
    }
}
