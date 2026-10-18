import Foundation
import XDictContract

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

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
