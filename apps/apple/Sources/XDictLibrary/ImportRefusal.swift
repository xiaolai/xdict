import Foundation
import XDictClient
import XDictContract

/// **Why a dictionary could not be imported or opened, as the reader is told** (ADR-0007 decision 10: kinds here, the
/// sentences in the view layer; AGENTS.md: a file XDict cannot read is refused with a sentence that names why). The
/// permanent ones are the file's own — reading it again gives the same answer — and are kept with the dictionary; the
/// rest offer a retry.
public enum ImportRefusal: Codable, Hashable, Sendable {
    /// A format version XDict does not read (`4.0`, say).
    case formatVersion(String)
    /// A format 3.0 resource library (`.mdd`), which XDict cannot read yet (ADR-0005).
    case resourceLibraryV3
    /// Locked with a registration code: refused at import, always; XDict never takes a code (owner, 2026-10-17; ADR-0005).
    case registrationCode
    /// Encrypted in a way XDict does not read.
    case encrypted
    /// Compressed in a way XDict does not read.
    case compression
    /// Text in an encoding XDict does not read, named.
    case encoding(String)
    /// The file's own checks failed: a bad checksum, or a structure that does not add up.
    case damaged
    /// Past one of XDict's limits on a file.
    case tooLarge
    /// A file of the dictionary is not where the library last found it, nor where its bookmark leads. Named.
    case missingFile(String)
    /// A file of the dictionary is there and could not be opened (permissions, most likely). Named.
    case unreadable(String)
    /// Something else has taken a file's place: a link (never followed, in its place or in a folder above it), a folder,
    /// a pipe. Named.
    case notAFile(String)
    /// The file changed while it was being read.
    case changedDuringImport
    /// The reader cancelled the import.
    case cancelled
    /// The dictionary service failed, stopped or could not be reached.
    case serviceFailed

    /// The kind of `failure`; `fileName` names a package file by its id.
    public init(_ failure: ClientFailure, fileName: (UUID) -> String?) {
        switch failure {
        case .fileUnavailable(let file, let errno):
            let name = fileName(file) ?? ""
            switch errno {
            case ENOENT, ENOTDIR: self = .missingFile(name)
            case ELOOP, EFTYPE: self = .notAFile(name)
            default: self = .unreadable(name)
            }
        case .wire(.core(let core)):
            self = Self(core)
        case .wire(.interrupted), .wire(.invalidated), .wire(.timedOut), .wire(.undecodable), .wire(.contractMismatch),
             .wire(.refused), .wire(.appleImport), .superseded, .reopenNeedsImport, .needsFiles:
            self = .serviceFailed
        }
    }

    init(_ failure: CoreFailure) {
        switch failure {
        case .unsupported(let feature, _):
            switch feature {
            case .formatVersion(let version): self = .formatVersion(version)
            case .resourceLibraryV3: self = .resourceLibraryV3
            case .registrationCode: self = .registrationCode
            case .encryptionFlags, .blockEncryption: self = .encrypted
            case .lzoInV3, .compressionType: self = .compression
            case .encoding(let name): self = .encoding(name)
            }
        case .malformed: self = .damaged
        case .tooLarge: self = .tooLarge
        case .sourceChanged: self = .changedDuringImport
        case .cancelled: self = .cancelled
        case .notFound, .io, .staleHandle, .editionMismatch, .incompatible, .internalFault: self = .serviceFailed
        }
    }

    /// The file itself is the reason: importing it again would answer the same.
    public var isPermanent: Bool {
        switch self {
        case .formatVersion, .resourceLibraryV3, .registrationCode, .encrypted, .compression, .encoding, .damaged,
             .tooLarge: true
        case .missingFile, .unreadable, .notAFile, .changedDuringImport, .cancelled, .serviceFailed: false
        }
    }
}
