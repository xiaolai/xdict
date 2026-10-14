import Foundation
import XDictLibrary

/// **What the library tells the reader, in their language** (ADR-0007 decision 10: the library hands kinds, the view
/// layer words them; AGENTS.md: a file XDict cannot read is refused with a sentence that names why). Every sentence is
/// in `Strings/Localizable.xcstrings`, in English and Simplified Chinese.
public enum LibrarySentences {
    public static func refusal(_ refusal: ImportRefusal) -> LocalizedStringResource {
        switch refusal {
        case .formatVersion(let version):
            LocalizedStringResource("This file uses MDict format \(version), which XDict does not read.")
        case .resourceLibraryV3:
            LocalizedStringResource("This resource file (.mdd) uses MDict format 3.0, which XDict cannot read yet.")
        case .registrationCode:
            LocalizedStringResource("""
                This dictionary is locked with a registration code. XDict opens it only with your own code, and cannot \
                take codes yet.
                """)
        case .encrypted:
            LocalizedStringResource("This dictionary is encrypted in a way XDict does not read.")
        case .compression:
            LocalizedStringResource("This dictionary is compressed in a way XDict does not read.")
        case .encoding(let name):
            LocalizedStringResource("This dictionary's text is in the \(name) encoding, which XDict does not read.")
        case .damaged:
            LocalizedStringResource("This file is damaged: a checksum or its structure is wrong.")
        case .tooLarge:
            LocalizedStringResource("This file is larger than XDict can hold.")
        case .missingFile(let name):
            LocalizedStringResource("“\(name)” is not where it was, and XDict cannot find where it went.")
        case .unreadable(let name):
            LocalizedStringResource("“\(name)” could not be opened. Check that you may read it.")
        case .changedDuringImport:
            LocalizedStringResource("The file changed while XDict was reading it. Try again.")
        case .cancelled:
            LocalizedStringResource("Import cancelled.")
        case .serviceFailed:
            LocalizedStringResource("The dictionary service stopped before it finished. Try again.")
        }
    }

    public static func note(_ note: EntryNote) -> LocalizedStringResource {
        switch note {
        case .missingVolume(let name):
            LocalizedStringResource("Resource volume “\(name)” is missing: pictures and sounds in it will not be found.")
        case .outsideChosenFolder(let name):
            LocalizedStringResource("“\(name)” points outside the folder you chose, so XDict does not read it.")
        case .sidecarsOmitted(let count):
            LocalizedStringResource("""
                \(count) files beside the dictionary were left out: one dictionary takes at most 64 files.
                """)
        case .volumeUnreadable(let name, let reason):
            LocalizedStringResource("Resource volume “\(name)” could not be read. \(String(localized: refusal(reason)))")
        }
    }

    /// What a speaker icon says (L6): the recording plays, is in a format macOS does not play, or is not there.
    public static func sound(_ sound: SoundDiagnosis) -> LocalizedStringResource {
        switch sound {
        case .playable:
            LocalizedStringResource("Plays the dictionary's own recording.")
        case .unsupported(let format):
            LocalizedStringResource("This recording is in a format macOS does not play (\(format)).")
        case .missing(let path):
            LocalizedStringResource("This recording is not among the dictionary's files (\(path)).")
        }
    }

    public static func notice(_ notice: LibraryNotice) -> LocalizedStringResource {
        switch notice {
        case .finder(.notADictionaryFile(let name)):
            LocalizedStringResource("“\(name)” is not a dictionary file (.mdx or .mdd).")
        case .finder(.noDictionaryIn(let folder)):
            LocalizedStringResource("No dictionary was found in “\(folder)”.")
        case .finder(.volumesWithoutDictionary(let names)):
            LocalizedStringResource("No dictionary (.mdx) was found for “\(names.joined(separator: "”, “"))”.")
        case .finder(.outsideChosenFolder(let name)):
            LocalizedStringResource("“\(name)” points outside the folder you chose, so it was not added.")
        case .finder(.unreadable(let name)):
            LocalizedStringResource("“\(name)” could not be read.")
        case .alreadyInLibrary(let name):
            LocalizedStringResource("Already in your library, as “\(name)”.")
        case .relinked(let name):
            LocalizedStringResource("Found “\(name)” again.")
        case .notSaved:
            LocalizedStringResource("Your library could not be saved.")
        }
    }

    /// Why the library itself cannot be used, and that it was left alone.
    public static func unreadable(_ error: LibraryStoreError) -> LocalizedStringResource {
        switch error {
        case .newerVersion:
            LocalizedStringResource("Your library was saved by a newer XDict. Update XDict to use it; it was left as it is.")
        case .damaged, .unavailable:
            LocalizedStringResource("Your library file could not be read, so XDict leaves it as it is and adds nothing to it.")
        }
    }

    /// One line for where a dictionary is.
    public static func phase(_ phase: EntryPhase) -> LocalizedStringResource {
        switch phase {
        case .waiting: LocalizedStringResource("Waiting to import")
        case .importing: LocalizedStringResource("Importing…")
        case .cancelling: LocalizedStringResource("Cancelling…")
        case .opening: LocalizedStringResource("Opening…")
        case .ready: LocalizedStringResource("Ready")
        case .cancelled: refusal(.cancelled)
        case .refused(let why), .failed(let why): refusal(why)
        case .missing(let name): refusal(.missingFile(name))
        case .outsideItsFolder(let name):
            LocalizedStringResource("“\(name)” has become a link or has left its folder, so XDict will not read it.")
        }
    }
}
