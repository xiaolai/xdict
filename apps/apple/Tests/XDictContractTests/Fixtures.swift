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
    static let studyStamp = StudyStamp(at: 1_790_643_600, device: "fixture")
    static let studyPolicy = StudyPolicy(retention: 0.9, maximumDays: 36_500)
    static let studyTarget = StudyTarget(lineage: lineage.rawValue, entryKey: "run", occurrence: 0, kind: .entry,
                                         edition: edition.rawValue,
                                         definitionHash: String(repeating: "ab", count: 32))
    static let studyNote = StudyNote(target: studyTarget, text: "my own words", at: 1_790_643_600,
                                     device: "fixture")
    static let studyCard = StudyCard(target: studyTarget, note: studyNote,
                                     state: StudyCardState(stability: 1.5, difficulty: 5, phase: .learning,
                                                           lastReview: 1_790_643_600, due: 1_790_644_200),
                                     head: "grade-event", noteHead: "note-event", grades: 1)
    static let reviewSummary = ReviewSummary(due: 0, nextDue: 1_790_644_200)
    static let studyOutcome = StudyOutcome(outcome: .recorded, card: studyCard)
    /// The readings a history card is made of, hidden or shown again (ADR-0024).
    static let removal = Removal(eventIds: ["0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"], at: 1_790_643_600,
                                 device: "fixture")
    /// Two devices' answers to one revision (ADR-0027), the shape the review window draws.
    static let cardConflict = CardConflict(target: studyTarget, note: studyNote, candidates: [
        ConflictCandidate(id: "grade-event", grade: .good, at: 1_790_643_600, device: "fixture",
                          after: studyCard.state),
        ConflictCandidate(id: "grade-event-b", grade: .again, at: 1_790_643_700, device: "fixture-b",
                          after: studyCard.state),
    ])
    static let reanchorReport = ReanchorReport(outcomes: [
        ReanchorOutcome(target: studyTarget, result: .reanchored),
    ])
    static let ledgerReading = LedgerReading(
        surface: "hold", lemma: "hold", sentence: "They hold that view.", span: LedgerSpan(start: 5, len: 4),
        cut: 0, quality: "complete", edition: edition.rawValue, entryKey: "hold", occurrence: 0,
        dictionaryName: "Tiny", language: "en", at: 1_790_643_600, device: "fixture")
    static let ledgerHistory = LedgerHistory(days: [
        LedgerDay(id: "2026-09-29", start: 1_790_640_000, label: .today, cards: [
            LedgerCard(reading: ledgerReading, times: 2,
                       events: ["0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b", "1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809"]),
        ]),
    ])

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
        .entryText(dict: dict, entry: entryRef, text: TextRenderContext(maxBodyBytes: 1 << 20, maxTextBytes: 64 << 10)),
        .link(dict: dict, url: "entry://hold#sense2", origin: .entry(entry: entryRef), render: .reader),
        .link(dict: dict, url: "../fonts/a.woff2", origin: .resource(path: "styles/main.css"),
              render: RenderContext(maxBodyBytes: 1 << 20)),
        .resource(dict: dict, path: "images/a%20b.png", render: .reader),
        .joinLineage(edition: edition, lineage: lineage),
        .splitLineage(edition: edition, newLineage: newLineage),
        .lineageOf(edition: edition),
        .health(dict: dict),
        .readingStyle(dict: dict),
        .convertApple(staging: staging),
        .cancelConversion,
        .displayOptions(dict: dict),
        .ledgerRecord(reading: ledgerReading, operation: "3E2D1C0B-9A87-4655-8433-221100FFEEDD", targetLanguages: ["en"]),
        .ledgerHistory(now: 1_790_643_600, utcOffsetSeconds: 0),
        .studyNote(dict: dict, entry: entryRef, text: "my own words", name: "Tiny", stamp: studyStamp,
                   operation: "op-study"),
        .studyNotes,
        .reviewQueue(now: 1_790_643_600, limit: 10),
        .reviewGrade(target: studyTarget.key, revision: "grade-event", grade: .good, policy: studyPolicy,
                     stamp: studyStamp, operation: "op-grade"),
        .reviewUndo(target: studyTarget.key, gradeEvent: "grade-event", stamp: studyStamp, operation: "op-undo"),
        .reviewSummary(now: 1_790_643_600),
        .definitionHash(dict: dict, entry: entryRef),
        .studyReanchor(oldEdition: edition,
                       newEdition: Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "cd", count: 32)),
                       stamp: studyStamp, operationPrefix: "reanchor"),
        .studyNoteAt(entry: entryRef, text: "my own words", name: "Tiny", stamp: studyStamp,
                     operation: "op-study-at"),
        .exportData,
        .eraseData(stamp: studyStamp, operation: "op-erase"),
        .studyConflicts,
        .reviewResolve(target: studyTarget.key, keep: "grade-event", stamp: studyStamp, operation: "op-resolve"),
        .ledgerSync(input: "/tmp/xdict-sync/in", output: "/tmp/xdict-sync/out", device: "device-a"),
        .ledgerRemove(removal: removal, operation: "op-remove"),
        .ledgerRestore(removal: removal, operation: "op-restore"),
        .words(dict: dict, from: 0, limit: 1_000),
    ]

    /// A staging folder's name, as the app mints it (ADR-0011 decision 4).
    static let staging = UUID(uuidString: "6B1F3C2A-9E4D-4F0B-8A51-0C7D2E9F1A3B") ?? UUID()

    static let operationCases = 38
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
        case .entryText: 8
        case .link: 9
        case .resource: 10
        case .joinLineage: 11
        case .splitLineage: 12
        case .lineageOf: 13
        case .health: 14
        case .readingStyle: 15
        case .convertApple: 16
        case .cancelConversion: 17
        case .displayOptions: 18
        case .ledgerRecord: 19
        case .ledgerHistory: 20
        case .studyNote: 21
        case .studyNotes: 22
        case .reviewQueue: 23
        case .reviewGrade: 24
        case .reviewUndo: 25
        case .reviewSummary: 26
        case .definitionHash: 27
        case .studyReanchor: 28
        case .studyNoteAt: 29
        case .exportData: 30
        case .eraseData: 31
        case .studyConflicts: 32
        case .reviewResolve: 33
        case .ledgerSync: 34
        case .ledgerRemove: 35
        case .ledgerRestore: 36
        case .words: 37
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

    static let words = Words(edition: edition, words: ["hold", "abbé"], total: 66_355, next: 2)

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
        .entryText(EntryText(entry: entryRef, text: "hold\n  to keep\n  an opinion", spans: [
            TextSpan(start: 0, len: 4, role: "headword", label: nil, section: nil),
            TextSpan(start: 6, len: 29, role: "definition", label: "1", section: "verb", sense: 1),
        ], senses: [
            Sense(id: 1, start: 6, len: 9, label: "1", section: "verb", parent: nil, whole: true),
            Sense(id: 2, start: 17, len: 18, label: "2", section: "verb", parent: nil, whole: true),
        ], style: 13, complete: false, omittedBytes: 12, cutAt: 35, spansDropped: 1)),
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
        .converted(converted),
        .displayOptions(displayOptions),
        .ledgerRecord(.recorded),
        .ledgerHistory(ledgerHistory),
        .studyNote(studyNote),
        .studyNotes([studyNote]),
        .reviewQueue([studyCard]),
        .reviewOutcome(studyOutcome),
        .reviewSummary(reviewSummary),
        .definitionHash(String(repeating: "ab", count: 32)),
        .reanchored(reanchorReport),
        .exported(#"{"version":1,"events":[]}"#),
        .erased(StudyEraseReport(clearedReadings: 0, clearedNotes: 0, clearedGrades: 0, recoverable: .freeBlocks)),
        .conflicts([cardConflict]),
        .synced(SyncReport(exported: 4_096, peers: 1, added: 3, skipped: 41)),
        .words(words),
    ]

    /// ADR-0013: the core's answer for an edition carrying both pronunciation variants, as NOAD (IPA by default).
    static let displayOptions = DisplayOptions(
        version: 1,
        options: [DisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                values: ["respell", "ipa", "both"], defaultValue: "ipa")],
        css: ":root[data-xdict-opt-pronunciation=\"respell\"] .t_IPA { display: none !important; }\n")

    static let converted = Converted(
        conversion: UUID(uuidString: "0D6E8C4B-1A2F-4E3D-9B7C-5F6A8E2D1C0B") ?? UUID(),
        sourceRevision: "m1:" + String(repeating: "ab", count: 32), converterRevision: 1,
        files: ["dictionary.mdx", "dictionary.mdd"], entries: 101_283, redirects: 243_907, resources: 61)

    static let health = Health(version: 1, entries: 706_524, findings: [
        HealthFinding(kind: .missingFile, count: 609_710, name: "oed.css",
                      examples: [HealthExample(key: "abandon", text: "<link href=\"OED.css\">")]),
        HealthFinding(kind: .repaired, count: 764, name: nil, examples: []),
    ], classes: [HealthClass(name: "text.repaired", count: 764)])

    static let readingStyle = ReadingStyle(
        version: 1, basePx: 14, baseFrom: .text(chars: 6_120, share: 0.81),
        fonts: [KeptFont(family: "Kingsoft Phonetic Plain", reason: .phonetic, selector: ".phon")],
        sheets: ["oalecd.css", "in/icons.css"], skipped: [
            SkippedSheet(path: "big.css", reason: .tooLarge(limit: 33_554_432, detail: "40 MiB")),
            SkippedSheet(path: "gone.css", reason: .notFound),
        ],
        changes: StyleChanges(important: 3, page: 2, family: 9, size: 40, lineHeight: 4, colour: 17, weight: 5, space: 8,
                              dropped: 11))

    static let answerCases = 30
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
        case .entryText: 8
        case .link: 9
        case .resource: 10
        case .lineage: 11
        case .health: 12
        case .readingStyle: 13
        case .converted: 14
        case .displayOptions: 15
        case .ledgerRecord: 16
        case .ledgerHistory: 17
        case .studyNote: 18
        case .studyNotes: 19
        case .reviewQueue: 20
        case .reviewOutcome: 21
        case .reviewSummary: 22
        case .definitionHash: 23
        case .reanchored: 24
        case .exported: 25
        case .erased: 26
        case .conflicts: 27
        case .synced: 28
        case .words: 29
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
        .renderLimitOutOfRange(requested: 64 << 20, ceiling: 16 << 20),
        .textLimitOutOfRange(requested: 2 << 20, ceiling: 1 << 20), .duplicateToken(file: mdxID),
        .unsupportedOperation, .missingToken(file: volumeID), .handleIsNotThePathsFile(file: mdxID),
        .notARegularReadOnlyFile(file: sidecarID), .envelopeTooLarge(bytes: 5 << 20, limit: 4 << 20),
        .suggestLimitOutOfRange(requested: 101, ceiling: 100),
    ]

    static let refusalCases = 15
    static func index(_ refusal: Refusal) -> Int {
        switch refusal {
        case .tooManyInFlight: 0
        case .payloadTooLarge: 1
        case .handleCountMismatch: 2
        case .missingHandle: 3
        case .unexpectedHandles: 4
        case .invalidPackage: 5
        case .renderLimitOutOfRange: 6
        case .textLimitOutOfRange: 7
        case .duplicateToken: 8
        case .unsupportedOperation: 9
        case .missingToken: 10
        case .handleIsNotThePathsFile: 11
        case .notARegularReadOnlyFile: 12
        case .envelopeTooLarge: 13
        case .suggestLimitOutOfRange: 14
        }
    }

    static let appleBounds: [AppleImportBound] = [
        .fileCount(limit: 512), .snapshotBytes(limit: 512 << 20), .sourceFile(name: "Body.data", limit: 512 << 20),
        .inflatedBlock(claimed: 1 << 30), .decompression(limit: 2 << 30), .output(limit: 2 << 30), .keyLength(units: 70_000),
    ]

    static let appleBoundCases = 7
    static func index(_ bound: AppleImportBound) -> Int {
        switch bound {
        case .fileCount: 0
        case .snapshotBytes: 1
        case .sourceFile: 2
        case .inflatedBlock: 3
        case .decompression: 4
        case .output: 5
        case .keyLength: 6
        }
    }

    static let appleRefusals: [AppleImportRefusal] = appleBounds.map(AppleImportRefusal.boundExceeded) + [
        .noContainer, .stagingNotFound, .stagingNotAFolder, .symbolicLink(path: "Contents/Resources/x"),
        .notARegularFile(path: "Contents/fifo"), .notVersion3(found: 4), .notVersion3(found: nil), .noKeyTextIndex,
        .malformedInfoPlist(detail: "unparsable"), .unsupported(detail: "bodyCompression(1)"),
        .corrupt(detail: "body(offset: 64)"), .unsafeName(name: "../x"), .unreadable(file: "Body.data", code: 5),
        .unwritable(file: "dictionary.mdx", code: 28), .noEntries,
    ]

    static let appleRefusalCases = 15
    static func index(_ refusal: AppleImportRefusal) -> Int {
        switch refusal {
        case .noContainer: 0
        case .stagingNotFound: 1
        case .stagingNotAFolder: 2
        case .symbolicLink: 3
        case .notARegularFile: 4
        case .notVersion3: 5
        case .noKeyTextIndex: 6
        case .malformedInfoPlist: 7
        case .unsupported: 8
        case .boundExceeded: 9
        case .corrupt: 10
        case .unsafeName: 11
        case .unreadable: 12
        case .unwritable: 13
        case .noEntries: 14
        }
    }

    static let wireErrors: [WireError] = coreFailures.map(WireError.core) + refusals.map(WireError.refused) + [
        .interrupted, .invalidated, .timedOut(deadline: .milliseconds(5_250)), .undecodable(detail: "not JSON"),
        .contractMismatch(service: 1, client: 2),
    ] + appleRefusals.map(WireError.appleImport)

    static let wireErrorCases = 8
    static func index(_ error: WireError) -> Int {
        switch error {
        case .core: 0
        case .interrupted: 1
        case .invalidated: 2
        case .timedOut: 3
        case .undecodable: 4
        case .contractMismatch: 5
        case .refused: 6
        case .appleImport: 7
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
