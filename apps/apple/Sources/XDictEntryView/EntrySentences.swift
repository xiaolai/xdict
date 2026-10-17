import Foundation

/// **Everything the entry view says to the reader**, in one place, each a catalogued sentence in English and Simplified
/// Chinese (`Strings/Localizable.xcstrings`; `StringCatalogTests`). The rest of this module's text is log and
/// diagnostic text, which is not shown.
public enum EntrySentences {
    /// Why no entry is shown, one sentence per reason: a reader — and a bug report — can tell them apart.
    public static func refusal(_ why: EntryRefusal) -> LocalizedStringResource {
        switch why {
        case .switchMissing(let name):
            LocalizedStringResource("Entries are not shown: this version of macOS lacks the WebKit switch “\(name)” that keeps them off the internet.")
        case .switchUnverifiable(let name):
            LocalizedStringResource("Entries are not shown: XDict cannot confirm that the WebKit switch “\(name)” is off.")
        case .switchStillOn(let name):
            LocalizedStringResource("Entries are not shown: the WebKit switch “\(name)” stayed on after XDict turned it off.")
        case .ruleListUnavailable:
            LocalizedStringResource("Entries are not shown: XDict could not set up the rules that keep them off the internet.")
        case .noPolicy:
            LocalizedStringResource("This entry is not shown: it came without the policy that confines it.")
        }
    }

    /// A speaker's VoiceOver name (reading-style §5.2): verb first, the same whatever the playing state.
    public static let speakerUK = LocalizedStringResource("Play British pronunciation")
    public static let speakerUS = LocalizedStringResource("Play American pronunciation")
    public static let speakerOther = LocalizedStringResource("Play recording")
    /// The accent tag drawn after a speaker's glyph.
    public static let accentTagUK = LocalizedStringResource("UK", comment: "Accent tag after a speaker: British")
    public static let accentTagUS = LocalizedStringResource("US", comment: "Accent tag after a speaker: American")
    public static let pictures = LocalizedStringResource("Pictures", comment: "The fold at an entry's end holding the pictures the dictionary hides")
    public static let entryFailed = LocalizedStringResource("This entry could not be shown.")
    public static let ready = LocalizedStringResource("Entries are shown confined: nothing in them reaches the internet.")

    // The reader's consent to a remote link (ADR-0009 decision 7).
    public static func openRemote(host: String) -> LocalizedStringResource {
        LocalizedStringResource("Open \(host) in your browser?")
    }

    public static func openRemoteDetail(url: String) -> LocalizedStringResource {
        LocalizedStringResource("This link leaves the dictionary for \(url). XDict does not load it here; your browser will, if you say so.")
    }

    public static let openInBrowser = LocalizedStringResource("Open in Browser")
    public static let cancel = LocalizedStringResource("Cancel")

    /// The placeholder a remote image becomes, naming its host. Clicking it asks the same question as a link.
    public static func remoteImage(host: String) -> LocalizedStringResource {
        LocalizedStringResource("Image from \(host)")
    }

    // Find within the entry (R3).
    public static let findPlaceholder = LocalizedStringResource("Find in Entry")
    public static let noMatches = LocalizedStringResource("No matches")
    public static func matchPosition(_ current: Int, of total: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(current) of \(total)")
    }

    /// Matches inside a folded section are counted apart: they are not stepped to until the section is opened.
    public static func hiddenMatches(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) more in folded sections")
    }

    public static let next = LocalizedStringResource("Next")
    public static let previous = LocalizedStringResource("Previous")
    public static let done = LocalizedStringResource("Done")

    // Appearance (R4).
    public static func theme(_ theme: EntryTheme) -> LocalizedStringResource {
        switch theme {
        case .matchApp: LocalizedStringResource("Match the App")
        case .original: LocalizedStringResource("Dictionary’s Own Colors")
        case .dark: LocalizedStringResource("Dark")
        }
    }
}
