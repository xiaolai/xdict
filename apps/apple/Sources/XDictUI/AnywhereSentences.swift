import Foundation
import XDictAnywhere
import XDictCaptureMac

/// **What lookup from anywhere tells the reader, in their language** (plan-macos-v1 WI-8): the selection reader and the
/// shortcut hand kinds, these word them. Every sentence is in `Strings/Localizable.xcstrings`, in English and Simplified
/// Chinese.
public enum AnywhereSentences {
    /// Why the selection could not be looked up: each reason its own sentence, naming the app.
    public static func refusal(_ refusal: SelectionRefusal) -> LocalizedStringResource {
        switch refusal {
        case .nothingSelected(let app):
            LocalizedStringResource("Nothing is selected in \(app), or \(app) does not share its selection. Select a word and try again.")
        case .searchLimitReached(let app, let limit):
            LocalizedStringResource("\(app)'s window is too large to search for a selection (over \(limit) elements). Select the word again and try once more.")
        case .noWord(let app):
            LocalizedStringResource("The selection in \(app) has no word in it, only spaces or punctuation.")
        case .tooLong(let app, let characters):
            LocalizedStringResource("The selection in \(app) is \(characters) characters long, more than XDict looks up at once. Select a word or a phrase.")
        case .failed(.notResponding, let app):
            LocalizedStringResource("\(app) did not answer when asked for its selection. Try again in a moment.")
        case .failed(.deadlineExceeded, let app):
            LocalizedStringResource("Reading the selection in \(app) took too long. Try again.")
        case .failed(.accessibilityDisabled, let app):
            LocalizedStringResource("XDict may not read the selection in \(app): Accessibility is turned off for XDict.")
        case .failed(.appUnavailable, let app):
            LocalizedStringResource("\(app) quit before its selection could be read.")
        case .failed(.accessibilityRefused, let app):
            LocalizedStringResource("\(app) refused to share its selection. If the screen is locked, unlock it and try again.")
        case .failed(.cancelled, let app):
            LocalizedStringResource("The lookup in \(app) was replaced by a newer one.")
        case .notTrusted:
            LocalizedStringResource("To look up what you select, allow XDict in the request macOS just showed, or turn XDict on in System Settings › Privacy & Security › \(PrivacySettings.accessibility()); the lookup continues once you do.")
        case .noApp:
            LocalizedStringResource("No app is in front, so there is no selection to look up.")
        case .tooLongToRead(let app):
            LocalizedStringResource("The selection in \(app) is too long to read at once. Select a word or a phrase.")
        }
    }

    /// What went wrong with the lookup shortcut.
    public static func problem(_ problem: ShortcutProblem) -> LocalizedStringResource {
        switch problem {
        case .unavailable(let shortcut, let why):
            LocalizedStringResource("\(shortcut.label()) is unavailable. \(String(localized: reason(why)))")
        case .refused(let chosen, let why, let kept?):
            LocalizedStringResource("\(chosen.label()) is unavailable. \(String(localized: reason(why))) Still using \(kept.label()).")
        case .refused(let chosen, let why, nil):
            LocalizedStringResource("\(chosen.label()) is unavailable. \(String(localized: reason(why))) The previous shortcut could not be put back either, so no shortcut is set.")
        case .reserved(let shortcut):
            LocalizedStringResource("\(shortcut.label()) is a standard command other apps rely on. Choose another combination.")
        case .unusable(let shortcut):
            LocalizedStringResource("\(shortcut.label()) has no ⌘, ⌃ or ⌥, so it would fire while you type. Choose another combination.")
        case .notSaved(let shortcut):
            LocalizedStringResource("\(shortcut.label()) works now but could not be saved, so it will not survive a restart.")
        }
    }

    /// Why a combination could not be registered.
    static func reason(_ why: RegistrationRefusal) -> LocalizedStringResource {
        switch why {
        case .heldByXDict:
            LocalizedStringResource("XDict already uses this shortcut for something else.")
        case .unreleasedByXDict:
            LocalizedStringResource("This shortcut could not be released earlier. Quit and reopen XDict to free it.")
        case .takenByAnotherApp:
            LocalizedStringResource("Another app has claimed this shortcut.")
        case .status(let status):
            LocalizedStringResource("The system would not register this shortcut (error \(String(status))).")
        }
    }
}
