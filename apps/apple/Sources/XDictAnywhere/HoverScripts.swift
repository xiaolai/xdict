import Foundation
import XDictCapture

/// **The scripts hover may look up, from the enabled dictionaries' search languages** (plan-capture WI-3; ADR-0014
/// decision 10: capture's own filter, handed in by its consumer, never a stored setting). A hovered word is worth looking
/// up only where some enabled dictionary is searched in its script; scripts, not languages, because one word cannot tell
/// English from German (XiaolaiDict ADR-0015).
public enum HoverScripts {
    /// The union of each language's scripts, or **nil — filter nothing — where any dictionary could hold any script**: a
    /// search language not known, a tag that cannot be read, no dictionary at all, or a set left empty because every
    /// language is written in a script capture cannot name.
    public static func allowed(searchLanguages: [String?]) -> Set<CaptureScript>? {
        var scripts: Set<CaptureScript> = []
        for language in searchLanguages {
            guard let language, let written = self.scripts(of: language) else { return nil }
            scripts.formUnion(written)
        }
        return scripts.isEmpty ? nil : scripts
    }

    /// The scripts a BCP 47 tag is written in — its own script subtag, else its likely one — or nil where the tag names no
    /// language or script. A script `CaptureScript` cannot name gives an empty set: its words carry no script capture
    /// knows, and `HoverPolicy.allows` admits them whatever the set.
    static func scripts(of language: String) -> Set<CaptureScript>? {
        let tag = Locale.Language(identifier: language)
        guard tag.languageCode != nil else { return nil }
        guard let script = tag.script ?? Locale.Language(identifier: tag.maximalIdentifier).script else { return nil }
        switch script.identifier {
        case "Latn": return [.latin]
        case "Hans", "Hant", "Hani": return [.han]
        case "Jpan": return [.han, .kana]
        case "Hira", "Kana", "Hrkt": return [.kana]
        case "Kore", "Hang": return [.hangul]
        default: return []
        }
    }
}
