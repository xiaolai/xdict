import Foundation
import XDictContract

/// One value of every case of every enum the contract carries, and the switches that prove it: each `index` below is
/// exhaustive, so a case added to the contract stops this file compiling until it has an index here, and
/// `expectEveryCase` then fails until a fixture of that case exists. A round trip over a list that silently missed a
/// case would pass forever.
enum Fixtures {
    static let dict = DictId(rawValue: "1a2b3c4d00000001")
    static let other = DictId(rawValue: "1a2b3c4d00000002")
    static let edition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32))
    static let lineage = LineageId(rawValue: "6F1C2B8E-0D4A-4E7B-9C3F-2A5D8E1B7C40")
    static let entryRef = EntryRef(edition: edition, key: "hold", occurrence: 1)
    static let info = DictInfo(title: "Tiny", description: "A <b>test</b> dictionary", formatVersion: "2.0", keys: 3)
    static let mdxID = UUID(uuidString: "0B9F3C1E-7A2D-4C55-8E61-3D2F9A0B1C2D") ?? UUID()
    static let volumeID = UUID(uuidString: "5E8A1F20-3B4C-4D6E-9F70-81A2B3C4D5E6") ?? UUID()
    static let secondVolumeID = UUID(uuidString: "7C6B5A49-3827-4165-9A8B-7C6D5E4F3A2B") ?? UUID()
    static let sidecarID = UUID(uuidString: "C0FFEE00-1234-4567-89AB-CDEF01234567") ?? UUID()
    static let package = PackageSpec(files: [
        .mdx(id: mdxID), .volume(id: volumeID, order: 0), .volume(id: secondVolumeID, order: 1),
        .sidecar(id: sidecarID, pathInPackage: "styles/Tiny.css", order: 0),
    ])
    static let identity = FileIdentity(device: 16_777_231, inode: 42, size: 4096, mtimeNs: 1_760_000_000_123_456_789,
                                       ctimeNs: 1_760_000_001_000_000_000)
    /// The file the second dictionary is made of.
    static let otherMDXID = UUID(uuidString: "9D8C7B6A-5948-4736-A251-403F2E1D0C9B") ?? UUID()
    static let newLineage = LineageId(rawValue: "1E2D3C4B-5A69-4788-97A6-B5C4D3E2F100")

    /// Each file's identity as both the app's `stat` and the service's `fstat` see it: one inode each.
    static let identities: [UUID: FileIdentity] = Dictionary(uniqueKeysWithValues: zip(
        [mdxID, volumeID, secondVolumeID, sidecarID, otherMDXID], UInt64(40)...).map { id, inode in
            (id, FileIdentity(device: 16_777_231, inode: inode, size: 4096, mtimeNs: 5, ctimeNs: 6))
        })
    /// A token for every file of both dictionaries, as the app sends them.
    static let tokens: [FileToken] = [mdxID, volumeID, secondVolumeID, sidecarID, otherMDXID].enumerated().map { n, id in
        FileToken(file: id, observed: UInt64(100 + n), state: .present(identities[id] ?? identity))
    }
    /// The service's map of what each open dictionary is made of.
    static let filesOf: [DictId: [UUID]] = [dict: package.files.map(\.id), other: [otherMDXID]]

    // MARK: - Operations

    static let operations: [ServiceOperation] = [
        .versions,
        .importPackage(spec: package),
        .cancel(request: 41),
        .openPackage(spec: package),
        .close(dict: dict),
        .lookup(query: "abbé", dicts: [dict, other], options: LookupOptions(limit: 100, offset: 0, mode: .reader, generation: nil)),
        .lookup(query: "run", dicts: [dict], options: LookupOptions(limit: 1_000, offset: 1_000, mode: .link, generation: 77)),
        .suggest(prefix: "ab", dicts: [dict], limit: 20),
        .entry(dict: dict, entry: entryRef, render: .reader),
        .link(dict: dict, url: "entry://hold#sense2", origin: .entry(entry: entryRef), render: .reader),
        .link(dict: dict, url: "../fonts/a.woff2", origin: .resource(path: "styles/main.css"),
              render: RenderContext(maxBodyBytes: 1 << 20)),
        .resource(dict: dict, path: "images/a%20b.png", render: .reader),
        .joinLineage(edition: edition, lineage: lineage),
        .splitLineage(edition: edition, newLineage: newLineage),
        .lineageOf(edition: edition),
        .health(dict: dict),
        .readingStyle(dict: dict),
    ]

    static let operationCases = 15
    static func index(_ operation: ServiceOperation) -> Int {
        switch operation {
        case .versions: 0
        case .importPackage: 1
        case .cancel: 2
        case .openPackage: 3
        case .close: 4
        case .lookup: 5
        case .suggest: 6
        case .entry: 7
        case .link: 8
        case .resource: 9
        case .joinLineage: 10
        case .splitLineage: 11
        case .lineageOf: 12
        case .health: 13
        case .readingStyle: 14
        }
    }

    // MARK: - Answers

    static let page = Page(
        hits: [
            Hit(dict: dict, entry: entryRef, headword: "hold", how: .exact, problems: []),
            Hit(dict: dict, entry: entryRef, headword: "Hold", how: .folded, problems: []),
            Hit(dict: other, entry: entryRef, headword: "abbé", how: .unmarked, problems: []),
            Hit(dict: dict, entry: entryRef, headword: "held", how: .redirect(chain: ["held", "hold"]),
                problems: [.redirectLimit(chain: ["a", "b", "c"])]),
        ],
        total: 66_355, generation: 0xDEAD_BEEF,
        problems: [.danglingRedirect(from: "x", target: "y"), .redirectLoop(chain: ["a", "a"])])

    static let answers: [Answer] = [
        .versions(Versions(protocolVersion: 1, core: "0.1.0", indexFormat: 3, normalization: 2)),
        .imported(Imported(edition: edition, lineage: lineage, info: info, problems: [
            .volumeUnreadable(name: volumeID.uuidString, error: .unsupported(feature: .resourceLibraryV3, detail: "v3 mdd")),
        ])),
        .cancellation(.stopping),
        .cancellation(.notRunning),
        .opened(.ready(dict: dict, edition: edition, info: info)),
        .opened(.needsImport(reason: .new)),
        .opened(.needsImport(reason: .changed)),
        .opened(.needsImport(reason: .indexMissing)),
        .opened(.needsImport(reason: .indexOutdated)),
        .opened(.needsImport(reason: .noIdentity)),
        .closed,
        .page(page),
        .suggestions(["abandon", "abbé", "a priori"]),
        .entry(Entry(entry: entryRef, csp: "default-src 'none'; img-src xdict://d/ data:", lossyBytes: 2)),
        .link(.lookup(query: "hold", anchor: "sense2")),
        .link(.lookup(query: "hold", anchor: nil)),
        .link(.resource(path: "images/a%20b.png")),
        .link(.sound(path: "us/hold.mp3")),
        .link(.speak(text: "hold")),
        .link(.anchor(name: "sense2")),
        .link(.blocked(why: .remote(url: "https://example.com/x"))),
        .link(.blocked(why: .script)),
        .link(.blocked(why: .unknownScheme(scheme: "help"))),
        .resource(.found(path: "images/a b.png", mime: "image/png")),
        .resource(.missing(path: "images/none.png")),
        .lineage(lineage),
        .lineage(nil),
        .health(health),
        .readingStyle(readingStyle),
    ]

    static let health = Health(version: 1, entries: 706_524, findings: [
        HealthFinding(kind: .missingFile, count: 609_710, name: "oed.css",
                      examples: [HealthExample(key: "abandon", text: "<link href=\"OED.css\">")]),
        HealthFinding(kind: .repaired, count: 764, name: nil, examples: []),
    ], classes: [HealthClass(name: "text.repaired", count: 764)])

    static let readingStyle = ReadingStyle(
        version: 1, basePx: 14, baseFrom: .text(chars: 6_120, share: 0.81),
        fonts: [KeptFont(family: "Kingsoft Phonetic Plain", reason: .phonetic, selector: ".phon")],
        sheets: ["oalecd.css", "in/icons.css"], skipped: ["big.css: larger than 32 MiB"],
        changes: StyleChanges(important: 3, page: 2, family: 9, size: 40, lineHeight: 4, colour: 17, weight: 5, space: 8,
                              dropped: 11))

    static let answerCases = 13
    static func index(_ answer: Answer) -> Int {
        switch answer {
        case .versions: 0
        case .imported: 1
        case .cancellation: 2
        case .opened: 3
        case .closed: 4
        case .page: 5
        case .suggestions: 6
        case .entry: 7
        case .link: 8
        case .resource: 9
        case .lineage: 10
        case .health: 11
        case .readingStyle: 12
        }
    }

    // MARK: - Errors

    static let features: [Feature] = [
        .formatVersion(version: "3.0"), .resourceLibraryV3, .registrationCode, .encryptionFlags(flags: 2), .lzoInV3,
        .compressionType(code: 9), .blockEncryption(code: 1), .encoding(name: "x-mac-roman"),
    ]

    static let featureCases = 8
    static func index(_ feature: Feature) -> Int {
        switch feature {
        case .formatVersion: 0
        case .resourceLibraryV3: 1
        case .registrationCode: 2
        case .encryptionFlags: 3
        case .lzoInV3: 4
        case .compressionType: 5
        case .blockEncryption: 6
        case .encoding: 7
        }
    }

    static let coreFailures: [CoreFailure] = features.map { .unsupported(feature: $0, detail: "refused") } + [
        .malformed(detail: "bad checksum"),
        .tooLarge(limit: .file, detail: "key block"), .tooLarge(limit: .page, detail: "1001"),
        .tooLarge(limit: .body, detail: "17 MiB"),
        .notFound(what: .file, detail: "gone"), .notFound(what: .entry, detail: "no record"),
        .notFound(what: .edition, detail: "never imported"), .notFound(what: .lineage, detail: "no such dictionary"),
        .io(kind: .notFound, detail: "ENOENT"), .io(kind: .permissionDenied, detail: "EPERM"),
        .io(kind: .shortRead, detail: "3 of 4"), .io(kind: .outOfMemory, detail: "64 MiB"), .io(kind: .other, detail: "EIO"),
        .staleHandle(detail: "another core"), .editionMismatch(detail: "other edition"),
        .sourceChanged(detail: "the source changed"), .cancelled(detail: "the import was cancelled"),
        .incompatible(core: 1, client: 999, detail: "protocol"), .internalFault(detail: "panic"),
    ]

    static let coreFailureCases = 11
    static func index(_ failure: CoreFailure) -> Int {
        switch failure {
        case .unsupported: 0
        case .malformed: 1
        case .tooLarge: 2
        case .notFound: 3
        case .io: 4
        case .staleHandle: 5
        case .editionMismatch: 6
        case .sourceChanged: 7
        case .cancelled: 8
        case .incompatible: 9
        case .internalFault: 10
        }
    }

    static let refusals: [Refusal] = [
        .tooManyInFlight, .payloadTooLarge(bytes: 70 << 20, limit: 64 << 20), .handleCountMismatch(files: 4, handles: 3),
        .missingHandle, .unexpectedHandles(count: 1), .invalidPackage(.mdxCount(found: 0)),
        .invalidPackage(.duplicateFile(mdxID)), .invalidPackage(.notNamedByID(file: volumeID)),
        .invalidPackage(.sidecarNotAPackagePath(file: sidecarID)), .invalidPackage(.orderNotContiguous(role: .mdd)),
        .invalidPackage(.tooManyFiles(found: 65, limit: 64)),
        .renderLimitOutOfRange(requested: 64 << 20, ceiling: 16 << 20), .duplicateToken(file: mdxID),
        .unsupportedOperation, .missingToken(file: volumeID), .handleIsNotThePathsFile(file: mdxID),
        .notARegularReadOnlyFile(file: sidecarID), .envelopeTooLarge(bytes: 5 << 20, limit: 4 << 20),
        .suggestLimitOutOfRange(requested: 101, ceiling: 100),
    ]

    static let refusalCases = 14
    static func index(_ refusal: Refusal) -> Int {
        switch refusal {
        case .tooManyInFlight: 0
        case .payloadTooLarge: 1
        case .handleCountMismatch: 2
        case .missingHandle: 3
        case .unexpectedHandles: 4
        case .invalidPackage: 5
        case .renderLimitOutOfRange: 6
        case .duplicateToken: 7
        case .unsupportedOperation: 8
        case .missingToken: 9
        case .handleIsNotThePathsFile: 10
        case .notARegularReadOnlyFile: 11
        case .envelopeTooLarge: 12
        case .suggestLimitOutOfRange: 13
        }
    }

    static let wireErrors: [WireError] = coreFailures.map(WireError.core) + refusals.map(WireError.refused) + [
        .interrupted, .invalidated, .timedOut(deadline: .milliseconds(5_250)), .undecodable(detail: "not JSON"),
        .contractMismatch(service: 1, client: 2),
    ]

    static let wireErrorCases = 7
    static func index(_ error: WireError) -> Int {
        switch error {
        case .core: 0
        case .interrupted: 1
        case .invalidated: 2
        case .timedOut: 3
        case .undecodable: 4
        case .contractMismatch: 5
        case .refused: 6
        }
    }

    /// A request for `operation`, with the handles it needs counted.
    /// A request for `operation` carrying a token for every file of both dictionaries.
    static func request(_ operation: ServiceOperation, id: UInt64 = 7) -> Request {
        Request(id: id, tokens: tokens, operation: operation)
    }

    /// What the service learns of each handle that travels with `operation`: one per file of its package, each a
    /// regular file opened read-only and the very file its token names; none for any other operation.
    static func handles(for operation: ServiceOperation) -> [HandleFacts] {
        (operation.packageSpec?.files ?? []).map { HandleFacts(identity: identities[$0.id], isRegularReadOnly: true) }
    }
}
