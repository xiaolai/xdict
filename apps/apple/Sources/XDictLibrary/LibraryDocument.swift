import Foundation
import XDictAppleSource
import XDictContract

/// Where a file or a folder was, kept two ways (ADR-0009 decision 1): a security-scoped bookmark, which follows the file
/// when it moves, and the canonical path it was last found at.
public struct StoredLocation: Codable, Hashable, Sendable {
    public var bookmark: Data
    public var path: String

    public init(bookmark: Data, path: String) {
        self.bookmark = bookmark
        self.path = path
    }
}

/// One file of a dictionary: its persisted id (the core's location name for an MDX or a volume, ADR-0009 decision 1),
/// its role and place in the package, and where it is.
public struct StoredFile: Codable, Hashable, Sendable {
    public let id: UUID
    public let role: FileSpec.Role
    public let order: Int
    /// A sidecar's name in the package; nil for the MDX and the volumes, which are named by `id`.
    public let pathInPackage: String?
    /// The name as the folder spelled it when the reader added it, for the reader.
    public let fileName: String
    public var location: StoredLocation

    public init(id: UUID, role: FileSpec.Role, order: Int, pathInPackage: String?, fileName: String,
                location: StoredLocation) {
        self.id = id
        self.role = role
        self.order = order
        self.pathInPackage = pathInPackage
        self.fileName = fileName
        self.location = location
    }

    /// The contract's description of this file.
    public var spec: FileSpec {
        switch role {
        case .mdx: .mdx(id: id)
        case .mdd: .volume(id: id, order: order)
        case .sidecar: .sidecar(id: id, pathInPackage: pathInPackage ?? fileName, order: order)
        }
    }
}

/// The reader's languages for one dictionary (L3): proposed from the file name, and confirmed by the reader unless the
/// name stated them.
public struct Languages: Codable, Hashable, Sendable {
    public var pair: LanguagePair
    public var basis: LanguageBasis
    /// The reader said so, or the file name stated it: nothing to ask.
    public var confirmed: Bool

    public init(proposal: LanguageProposal) {
        pair = proposal.pair
        basis = proposal.basis
        confirmed = !proposal.needsAsking
    }

    public var needsAsking: Bool { !confirmed }
}

/// **A changed edition, and the reader's question about it** (ADR-0002 decision 3): the file was rewritten, its import
/// is a new edition with a lineage of its own, and only the reader may say it is the same dictionary.
public struct JoinOffer: Codable, Hashable, Sendable {
    /// The new edition, and the lineage the import gave it.
    public let edition: Edition
    public let mintedLineage: LineageId
    /// The edition the dictionary had, and its lineage: the one a join would give the new edition.
    public let earlierEdition: Edition
    public let earlierLineage: LineageId

    public init(edition: Edition, mintedLineage: LineageId, earlierEdition: Edition, earlierLineage: LineageId) {
        self.edition = edition
        self.mintedLineage = mintedLineage
        self.earlierEdition = earlierEdition
        self.earlierLineage = earlierLineage
    }
}

/// **A join the reader made**, with what undoes it exactly: `splitLineage(edition, previous)` returns the edition to the
/// lineage it had before (ADR-0002 decision 3, as amended 2026-10-14).
public struct LineageJoin: Codable, Hashable, Sendable {
    public let edition: Edition
    public let joinedTo: LineageId
    public let previous: LineageId
    /// The question it answered, asked again if the join is undone.
    public let offer: JoinOffer

    public init(edition: Edition, joinedTo: LineageId, previous: LineageId, offer: JoinOffer) {
        self.edition = edition
        self.joinedTo = joinedTo
        self.previous = previous
        self.offer = offer
    }
}

/// **Where an Apple dictionary came from** (ADR-0011 decision 10): kept beside its entry by the library, never by the
/// service, so a later launch can say whether Apple changed the bundle or XDict changed the converter (decision 7).
public struct AppleSourceRecord: Codable, Hashable, Sendable {
    /// `CFBundleIdentifier` of the installed bundle.
    public let bundleIdentifier: String
    /// `CFBundleVersion`, for the reader; the revision decides.
    public let bundleVersion: String?
    /// The manifest hash of the snapshot converted (`Manifest`).
    public let sourceRevision: String
    public let converterRevision: UInt32
    /// The folder `AppleImports/<conversion>/` the files were published into.
    public let conversion: UUID

    public init(bundleIdentifier: String, bundleVersion: String?, sourceRevision: String, converterRevision: UInt32,
                conversion: UUID) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.sourceRevision = sourceRevision
        self.converterRevision = converterRevision
        self.conversion = conversion
    }

    /// What a conversion published, for the bundle it was made of.
    public init(_ converted: Converted, bundle: InstalledBundle) {
        self.init(bundleIdentifier: bundle.identifier, bundleVersion: bundle.version,
                  sourceRevision: converted.sourceRevision, converterRevision: converted.converterRevision,
                  conversion: converted.conversion)
    }

    /// A record this version could have written: a bundle identifier, a revision in the manifest's shape, a converter
    /// revision. Anything else is a damaged library, never a dictionary with no source.
    var isWellFormed: Bool {
        !bundleIdentifier.isEmpty && Manifest.isRevision(sourceRevision) && converterRevision > 0
    }
}

/// **The edition and lineage an Apple dictionary last settled on**, by bundle identifier, kept after the dictionary is
/// removed: a fresh import of the same bundle is a new lineage, and this is the join it suggests (ADR-0011 decision 8).
public struct AppleLineage: Codable, Hashable, Sendable {
    public let edition: Edition
    public let lineage: LineageId

    public init(edition: Edition, lineage: LineageId) {
        self.edition = edition
        self.lineage = lineage
    }
}

/// One dictionary in the reader's library.
public struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The folder the reader chose (or the folder of the file they chose): every file stays inside it.
    public var root: StoredLocation
    /// The MDX first, then the volumes in order, then the sidecars.
    public var files: [StoredFile]
    /// Set by the last import that answered.
    public var edition: Edition?
    public var lineage: LineageId?
    public var info: DictInfo?
    /// The reader's own name for it, if they gave one.
    public var readersName: String?
    public var enabled = true
    public var languages: Languages
    public var notes: [EntryNote] = []
    /// Why its last import was refused, when the file itself is the reason.
    public var refusal: ImportRefusal?
    /// A changed edition awaiting the reader's answer.
    public var offer: JoinOffer?
    /// The reader's join, until undone.
    public var join: LineageJoin?
    /// An Apple dictionary's source (ADR-0011 decision 10); nil for the reader's own MDX files.
    public var appleSource: AppleSourceRecord?

    /// What the reader's choices for this dictionary are kept under (zoom, theme, "Original style"): its lineage, which
    /// survives a new edition and a moved file (ADR-0002); its own id until it has one.
    public var preferencesKey: String { lineage?.rawValue ?? id.uuidString }

    public init(id: UUID, root: StoredLocation, files: [StoredFile], languages: Languages) {
        self.id = id
        self.root = root
        self.files = files
        self.languages = languages
    }

    public var mdx: StoredFile? { files.first { $0.role == .mdx } }
}

/// The library as written to disk.
///
/// - **Version 2** (ADR-0011 decision 10, 2026-10-18): an entry may carry `appleSource`, and the document carries
///   `appleLineages`. A version 1 document is read as having neither; a version 2 document missing `appleLineages`, or
///   holding a source record this version could not have written, is damaged, never read as "no Apple dictionaries".
public struct LibraryDocument: Codable, Hashable, Sendable {
    /// Raised by any change a reader of an older version would misread.
    public static let currentVersion = 2

    public let version: Int
    public var entries: [LibraryEntry]
    public var appleLineages: [String: AppleLineage]

    public init(entries: [LibraryEntry], appleLineages: [String: AppleLineage] = [:]) {
        version = Self.currentVersion
        self.entries = entries
        self.appleLineages = appleLineages
    }

    enum CodingKeys: String, CodingKey {
        case version, entries, appleLineages
    }

    /// Reads any version up to this one, migrating as it goes; written back as this one at the next save.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let read = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(read) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "version \(read)")
        }
        let decoded = try container.decode([LibraryEntry].self, forKey: .entries)
        if read >= 2 {
            appleLineages = try container.decode([String: AppleLineage].self, forKey: .appleLineages)
            guard decoded.allSatisfy({ $0.appleSource?.isWellFormed ?? true }) else {
                throw DecodingError.dataCorruptedError(forKey: .entries, in: container,
                                                       debugDescription: "an Apple source record is damaged")
            }
            entries = decoded
        } else {
            // Version 1 had no Apple dictionaries: nothing in it is a source record.
            appleLineages = [:]
            entries = decoded.map { entry in
                var migrated = entry
                migrated.appleSource = nil
                return migrated
            }
        }
        version = Self.currentVersion
    }
}

public enum LibraryStoreError: Error, Hashable, Sendable {
    /// The file is there and is not a library this version can read.
    case damaged
    /// A later XDict wrote it.
    case newerVersion(Int)
    /// The file could not be read or written at all.
    case unavailable(errno: Int32)
}

/// **The library's file**: `Library.json` in a directory of its own, the app's Application Support in the app.
public struct LibraryStore: Sendable {
    public static let fileName = "Library.json"
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var file: URL { directory.appending(path: Self.fileName) }

    /// The library, nil when there is none yet. **A file that is there and cannot be read is an error, never an empty
    /// library**: reading it as empty would have the next save write over the reader's dictionaries.
    public func load() throws(LibraryStoreError) -> LibraryDocument? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw .unavailable(errno: Self.errno(of: error))
        }
        struct Version: Decodable { let version: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else { throw .damaged }
        guard version.version <= LibraryDocument.currentVersion else { throw .newerVersion(version.version) }
        do {
            return try JSONDecoder().decode(LibraryDocument.self, from: data)
        } catch {
            throw .damaged
        }
    }

    /// Writes the whole library atomically (a temporary file renamed over the old), so a crash mid-write leaves the
    /// previous library, never half of one.
    public func save(_ document: LibraryDocument) throws(LibraryStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(document).write(to: file, options: [.atomic])
        } catch {
            throw .unavailable(errno: Self.errno(of: error))
        }
    }

    static func errno(of error: any Error) -> Int32 {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return Int32(truncatingIfNeeded: underlying?.domain == NSPOSIXErrorDomain ? underlying?.code ?? 0 : 0)
    }
}
