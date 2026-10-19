import Foundation
import XDictAnywhere
import XDictCapture

/// **What hover's settings and the menu-bar menu say, in the reader's language** (plan-capture WI-3): capture hands kinds
/// (ADR-0014 decision 4) and the composition layer hands entries; these word them. Every sentence is in
/// `Strings/Localizable.xcstrings`, in English and Simplified Chinese.
public enum HoverSentences {
    public static func modifier(_ modifier: HoverModifier) -> LocalizedStringResource {
        switch modifier {
        case .option: LocalizedStringResource("Option \(modifier.symbol)", comment: "The Option key, in the hover key picker")
        case .control: LocalizedStringResource("Control \(modifier.symbol)", comment: "The Control key, in the hover key picker")
        case .command: LocalizedStringResource("Command \(modifier.symbol)", comment: "The Command key, in the hover key picker")
        case .shift: LocalizedStringResource("Shift \(modifier.symbol)", comment: "The Shift key, in the hover key picker")
        }
    }

    public static func gesture(_ gesture: HoverGesture) -> LocalizedStringResource {
        switch gesture {
        case .hold: LocalizedStringResource("Hold", comment: "Hover gesture: hold the key while the pointer rests")
        case .doubleTap: LocalizedStringResource("Press Twice", comment: "Hover gesture: press the key twice quickly")
        }
    }

    /// **Read text with**, each choice of the pop-up (owner, 2026-10-19).
    public static func readingMode(_ mode: HoverPolicy.ReadingMode) -> LocalizedStringResource {
        switch mode {
        case .automatic:
            LocalizedStringResource(
                "Automatic", comment: "Read text with: the text an app shares first, the screen where it shares none")
        case .screenOnly:
            LocalizedStringResource("Screen Only", comment: "Read text with: always read the screen, needing Screen Recording")
        }
    }

    /// Named the way a reader names them, not the way Unicode does.
    public static func script(_ script: CaptureScript) -> LocalizedStringResource {
        switch script {
        case .latin: LocalizedStringResource("Latin", comment: "A writing system hover looks up: English and most European languages")
        case .han: LocalizedStringResource("Chinese characters", comment: "A writing system hover looks up: Chinese characters and Japanese kanji")
        case .hangul: LocalizedStringResource("Korean", comment: "A writing system hover looks up: Hangul")
        case .kana: LocalizedStringResource("Japanese kana", comment: "A writing system hover looks up: hiragana and katakana")
        }
    }

    /// The scripts hover looks up now: every one where a dictionary could hold any, else the named ones, in one order.
    public static func scripts(_ scripts: Set<CaptureScript>?) -> LocalizedStringResource {
        guard let scripts, !scripts.isEmpty else {
            return LocalizedStringResource("Words in any writing system", comment: "Hover's scripts, when the dictionaries could hold any")
        }
        let names = scripts.sorted().map { String(localized: script($0)) }.formatted(.list(type: .and))
        return LocalizedStringResource("Words written in \(names)", comment: "Hover's scripts; the placeholder is a list such as 'Latin and Chinese characters'")
    }

    /// One rest of the rest-time picker, named by its length in the system's own words ("180 ms"), so the unit and the
    /// digits are the reader's locale's.
    public static func settle(_ settle: HoverPolicy.Settle, locale: Locale = .current) -> String {
        Duration.milliseconds(settle.milliseconds)
            .formatted(.units(allowed: [.milliseconds], width: .abbreviated).locale(locale))
    }

    /// What adding a site to exclude said: nothing when it was added.
    public static func excludedSite(_ answer: ExcludedSiteAnswer) -> LocalizedStringResource? {
        switch answer {
        case .added: nil
        case .alreadyExcluded(let host):
            LocalizedStringResource("\(host) is already excluded.", comment: "The placeholder is a site's host, such as 'example.com'")
        case .notASite:
            LocalizedStringResource("That is not a site. Type a name such as example.com, or paste an address.")
        case .tooBroad:
            LocalizedStringResource("A single name such as com would cover every site under it. Type a site such as example.com.")
        case .listFull:
            LocalizedStringResource("The list is full. Remove a site to add another.")
        }
    }

    /// What the reader is told about hover, each notice its own sentence.
    public static func notice(_ notice: CaptureNotice) -> LocalizedStringResource {
        switch notice {
        case .captureStuck:
            LocalizedStringResource("An app has stopped answering, so hover cannot read words until it does. Looking up a selection with the shortcut still works.")
        case .screenRecordingNeeded:
            LocalizedStringResource("Hover needs Screen Recording to read words in apps that do not share their text. Allow it in the Screen Recording row.")
        case .nothingUnderPointer:
            LocalizedStringResource("Hover found no word to read under the pointer.")
        }
    }

    /// **The brief line shown by the pointer** when a hover the reader asked for ends without a word (owner's report,
    /// 2026-10-19): short enough to take at a glance, and never the word or the sentence.
    public static func brief(_ notice: CaptureNotice) -> LocalizedStringResource {
        switch notice {
        case .nothingUnderPointer:
            LocalizedStringResource("No word found here", comment: "Shown briefly by the pointer when hover read no word")
        case .screenRecordingNeeded:
            LocalizedStringResource(
                "Hover needs Screen Recording here",
                comment: "Shown briefly by the pointer; the Screen Recording row is in Settings > General")
        case .captureStuck:
            LocalizedStringResource(
                "The screen is not answering yet", comment: "Shown briefly by the pointer when a screen capture is stuck")
        }
    }

    /// What the Screen Recording row says under its title, by what the grant is now.
    public static func screenRecording(_ row: ScreenRecordingRow) -> LocalizedStringResource {
        switch row {
        case .notSetUp:
            LocalizedStringResource("Lets hover read words in apps that do not share their text, such as terminals and images. macOS asks once.")
        case .allowed:
            LocalizedStringResource("Hover reads words from the screen where an app does not share its text.")
        case .notAllowed:
            LocalizedStringResource("Not allowed. Turn XDict on in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then check again.")
        case .couldNotTell:
            LocalizedStringResource("Could not tell whether Screen Recording is allowed. Check again in a moment.")
        }
    }

    /// One pause length of the menu's Pause Hover submenu: the length in the system's own words ("15 minutes", "1 hour"),
    /// so the plural is the system's.
    public static func pauseLength(_ duration: Duration, locale: Locale = .current) -> LocalizedStringResource {
        let length = duration.formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
        return LocalizedStringResource("For \(length)", comment: "A Pause Hover length; the placeholder is a length such as '15 minutes'")
    }

    /// One line of the menu-bar menu's pause group.
    public static func pauseEntry(_ entry: HoverPauseMenu.Entry, now: Date, locale: Locale = .current) -> String {
        switch entry {
        case .pause:
            return String(localized: LocalizedStringResource("Pause Hover", comment: "Menu bar item, parent of the pause lengths"))
        case .hoverIsOff:
            return String(localized: LocalizedStringResource(
                "Hover Is Off in Settings", comment: "Menu bar line, disabled: why Pause Hover is not offered"))
        case .resume:
            return String(localized: LocalizedStringResource("Resume Hover", comment: "Menu bar item"))
        case .resumesAt(let when):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.locale = locale
            let relative = formatter.localizedString(for: when, relativeTo: now)
            return String(localized: LocalizedStringResource(
                "Hover resumes \(relative)", comment: "Menu bar status line; the placeholder is a relative time such as 'in 14 minutes'"))
        }
    }
}
