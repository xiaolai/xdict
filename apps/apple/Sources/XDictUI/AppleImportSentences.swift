import Foundation
import XDictContract
import XDictLibrary

/// **Why an Apple dictionary was not converted, in the reader's language** (ADR-0011 decision 11; ADR-0007 decision 10:
/// the service hands kinds, the view layer words them). Every sentence is in `Strings/Localizable.xcstrings`, in English
/// and Simplified Chinese. The Add Apple Dictionaries… sheet (plan WI-5) shows them.
public enum AppleImportSentences {
    public static func refusal(_ refusal: AppleImportRefusal) -> LocalizedStringResource {
        switch refusal {
        case .noContainer:
            LocalizedStringResource("XDict’s dictionary service cannot reach its shared folder, so it cannot convert Apple dictionaries. Reinstall XDict.")
        case .stagingNotFound, .stagingNotAFolder:
            LocalizedStringResource("The copy of this dictionary was gone before XDict could convert it. Try again.")
        case .symbolicLink, .notARegularFile:
            LocalizedStringResource("This dictionary holds a link or a special file where a plain file belongs, so XDict does not convert it.")
        case .notVersion3:
            LocalizedStringResource("This dictionary is in an older format than the one macOS installs, so XDict does not convert it.")
        case .noKeyTextIndex:
            LocalizedStringResource("This dictionary has no search words, so XDict cannot convert it.")
        case .malformedInfoPlist:
            LocalizedStringResource("This dictionary’s description file is damaged, so XDict does not convert it.")
        case .unsupported:
            LocalizedStringResource("This dictionary uses something XDict does not convert yet.")
        case .boundExceeded(let bound):
            Self.bound(bound)
        case .corrupt, .noEntries:
            LocalizedStringResource("This dictionary is damaged or empty, so XDict does not convert it.")
        case .unsafeName:
            LocalizedStringResource("This dictionary names a file outside itself, so XDict does not convert it.")
        case .unreadable:
            LocalizedStringResource("Part of this dictionary could not be read. Try again.")
        case .unwritable:
            LocalizedStringResource("XDict could not save the converted dictionary. Check that your disk has room, then try again.")
        }
    }

    static func bound(_ bound: AppleImportBound) -> LocalizedStringResource {
        switch bound {
        case .fileCount(let limit):
            LocalizedStringResource("This dictionary has more than \(Int(clamping: limit)) files, more than XDict converts.")
        case .snapshotBytes(let limit), .sourceFile(_, let limit):
            LocalizedStringResource("This dictionary is larger than XDict converts (\(Self.size(limit))).")
        case .inflatedBlock, .decompression, .output, .keyLength:
            LocalizedStringResource("This dictionary would grow larger than XDict converts.")
        }
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    // MARK: - The sheet (plan WI-5)

    public static let title = LocalizedStringResource("Add Apple Dictionaries")
    public static let intro = LocalizedStringResource("""
        Choose the dictionaries installed on this Mac to add. XDict converts a copy of each once; the dictionaries \
        themselves are not changed.
        """)
    /// ADR-0011 decision 1: how to get one that is not listed.
    public static let howToDownload = LocalizedStringResource("""
        To add a dictionary that is not listed, download it in Dictionary.app ▸ Settings, then open this list again.
        """)
    public static let none = LocalizedStringResource("No Apple dictionaries are installed on this Mac.")
    public static let finding = LocalizedStringResource("Finding the dictionaries installed on this Mac…")
    public static let alreadyImported = LocalizedStringResource("Already imported")
    public static let importButton = LocalizedStringResource("Import")

    // MARK: - Available in Dictionary.app (plan-setup-v2 WI-3)

    /// The second section: what Dictionary.app knows this Mac could download.
    public static let availableSection = LocalizedStringResource("Available in Dictionary.app")
    /// Under the list: who does the downloading, since XDict cannot.
    public static let availableNote = LocalizedStringResource("""
        macOS downloads dictionaries in Dictionary ▸ Settings. XDict cannot start the download.
        """)
    public static let notInstalled = LocalizedStringResource("Not installed")
    /// Dictionary.app's own list could not be read: said, rather than leaving only the download instructions.
    public static let availableUnreadable = LocalizedStringResource(
        "XDict could not read which dictionaries Dictionary.app knows about on this Mac.")
    public static let download = LocalizedStringResource("Download in Dictionary.app…")
    public static let rescan = LocalizedStringResource("Rescan")
    public static let openDictionary = LocalizedStringResource("Open Dictionary.app")

    /// Where one import is, in the row's own words; nil while nothing was asked.
    /// The line over a conversion's bar in the dictionary's own box.
    public static func converting(name: String) -> LocalizedStringResource {
        LocalizedStringResource("Converting \(name) again…")
    }

    public static func step(_ step: AppleImportStep?) -> LocalizedStringResource? {
        switch step {
        case nil: nil
        case .waiting: LocalizedStringResource("Waiting")
        case .copying: LocalizedStringResource("Copying…")
        case .converting: LocalizedStringResource("Converting…")
        case .cancelling: LocalizedStringResource("Cancelling…")
        case .added: LocalizedStringResource("Added")
        case .cancelled: LocalizedStringResource("Cancelled")
        case .failed(let failure): Self.failure(failure)
        }
    }

    public static func failure(_ failure: AppleImportFailure) -> LocalizedStringResource {
        switch failure {
        case .refused(let refusal): Self.refusal(refusal)
        case .noContainer: Self.refusal(.noContainer)
        case .service: LocalizedStringResource("XDict’s dictionary service did not finish converting this dictionary. Try again.")
        case .notAdded: LocalizedStringResource("XDict converted this dictionary but could not add it. Try again.")
        }
    }

    // MARK: - Settings ▸ Dictionaries' problem row (decisions 7–9)

    /// Apple changed the bundle, or XDict changed the converter: Convert Again is offered.
    public static func updated(name: String) -> LocalizedStringResource {
        LocalizedStringResource("Apple updated \(name).")
    }

    public static let convertAgain = LocalizedStringResource("Convert Again")
    public static let convertAgainHelp = LocalizedStringResource("""
        Converts the installed dictionary again and keeps the result as this dictionary. You can undo it.
        """)
    public static let removed = LocalizedStringResource("Apple removed this dictionary’s files; this copy still reads.")
}
