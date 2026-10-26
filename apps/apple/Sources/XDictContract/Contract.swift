import Foundation

/// **The IPC contract between XDict.app and its dictionary service, frozen on 2026-10-14 at the end of plan-macos-v1
/// WI-1.** ADR-0009 records the macOS shell's architecture and why each part below is as it is; the measurements it
/// rests on are `dev-docs/measurements/2026-10-14-macos-xpc/README.md`, "Contract inputs".
///
/// **What is frozen**, and may change only together with a raised `Contract.version`: everything in the JSON, and what
/// one side accepts from the other —
/// - the JSON of every envelope (`Request`, `Response`, `ServiceEvent`) and of every type inside one: type shapes, case
///   names and labels, field names, raw values;
/// - the payload rule: the second `Data` of a reply is an entry's HTML as UTF-8 or a found resource's bytes, and is
///   never inside the JSON; nothing else has one;
/// - admission (`Request.refusal(handles:filesOf:)`), the package rules (`PackageSpec.problem`), the identity rule
///   (`IdentityRule`) and the order of observations (`TokenLedger`), the render base (`RenderContext.baseURL`), and the
///   limits a receiver enforces (`Limits`, `Credits`).
/// A raised version makes a mismatched app and service answer each other `contractMismatch` instead of misreading.
///
/// **What is permanent, at every version:** the native surface — the two NSXPC protocols (`DictionaryServiceXPC`,
/// `ServiceEventsXPC`), their selectors, the classes their interfaces admit (`XPCInterfaces`), and the event protocol —
/// and an envelope's `contract` (`UInt32`) and `id` (`UInt64`) at the top level of its JSON, which are how two versions
/// tell that they differ, so they are read before anything else (`Header`). **`Contract.version` versions the JSON
/// only**: NSXPC checks the native surface before any JSON is read, so a mismatch there would be an interrupted
/// connection, never a typed `contractMismatch` (Codex objection 15). A change to the native surface therefore ships as
/// a new service under a new bundle name, never under `ai.xdict.app.DictionaryService`, which ADR-0001 fixes for this
/// one; and since a service's sandbox container holds the registry (ADR-0009), that new service carries the registry's
/// migration with it.
///
/// **What may change without a bump:** the client's deadlines (`Deadlines`, never on the wire), documentation, and helpers
/// that change neither what is encoded nor what is accepted.
///
/// **Not here, on purpose: generations.** The client tags each request with a generation and drops superseded work
/// before sending it, or discards a late reply after (plan-macos-v1 choice 5). The service never needs to see one: work
/// it has started finishes either way, since the core's `lookup` cannot be cancelled. (`LookupOptions.generation` is
/// another thing: the core's page generation, ADR-0007 decision 9.)
public enum Contract {
    /// The contract's version: raised by any change this notice calls frozen; never lowered, never reused.
    /// 2 (2026-10-14): `Missing` gained the raw values `edition` and `lineage`, which the core's lineage operations
    /// report (ADR-0002 decision 3, as amended that day).
    /// 3 (2026-10-16): the operation `health` and its answer, the core's health check of an open dictionary (WI-12).
    /// 4 (2026-10-17): the operation `readingStyle` and its answer, the core's report of what the reading style does to
    /// an open dictionary (ADR-0010, owner's decision of 2026-10-17), shown in the Library's details pane.
    /// 5 (2026-10-17): `ReadingStyle.skipped` became typed (`SkippedSheet`, a path and a `SkipReason`), so the shell
    /// words why a sheet was not read in the reader's language instead of showing the core's English.
    /// 6 (2026-10-18): the operations `convertApple` and `cancelConversion`, the answer `converted` and the error
    /// `appleImport`: an Apple dictionary snapshot converted in the service (ADR-0011, plan WI-4).
    /// 7 (2026-10-18): the operation `displayOptions` and its answer, the display options an open dictionary's edition
    /// declares, with its defaults and the core's CSS (ADR-0013 decisions 2, 4 and 6), for Settings and the entry view.
    /// 8 (2026-10-20): the operation `entryText` and its answer, an entry as whole plain text with spans and a cut
    /// report, for the AI pane (ADR-0021 d.5, plan-ai-meaning WI-1/WI-5).
    /// 9 (2026-10-21): the operations `ledgerRecord` and `ledgerHistory` and their answers, the local reading history
    /// the drawer shows (ADR-0023, ADR-0024, plan-history-and-learning WI-2).
    /// 10 (2026-10-21): the study operations — a note, the notes, the review queue, a grade, an undo, the summary, a
    /// definition's hash and a re-anchor — with their answers (plan-history-and-learning WI-5).
    /// 13 (2026-10-22): `EntryText` gained `senses` and `style`, and `TextSpan` gained `sense`: the senses the markup
    /// names, their canonical ranges, and the rendering revision the ordinals belong to (ADR-0029 d.2, d.3); and the
    /// operation `words` with its answer, a page of one dictionary's public keys for Core Spotlight (plan-setup-v2
    /// WI-6, ADR-0028: headwords only).
    /// 14 (2026-10-24): the operations `examples` and `examplesBuild` and their answers, the reverse-example query
    /// and the per-edition store's background build (ADR-0031, plan-reverse-examples WI-3–WI-5).
    /// 15 (2026-10-25): the operations `phrases` and `phrasesBuild` and their answers, the phrase covering a captured
    /// term and the per-edition inventory's background build (plan-phrase-recognition WI-7); `PhraseAnswer.total`
    /// counts the matches before the cap, so a capped list says what it left out.
    public static let version: UInt32 = 15
}

// MARK: - The request

/// What the app asks. Sent as JSON through `DictionaryServiceXPC.call`, or `callWithFiles` when its operation carries a
/// package, whose handles travel beside it in the order of the package's files.
public struct Request: Codable, Hashable, Sendable {
    public let contract: UInt32
    /// The client's id for this request, echoed by the reply. Unique per connection.
    public let id: UInt64
    /// The app's latest identity token for **every** file this request may read (`IdentityRule`), exactly one per file
    /// (`refusal(handles:filesOf:)` requires both).
    public let tokens: [FileToken]
    public let operation: ServiceOperation

    public init(contract: UInt32 = Contract.version, id: UInt64, tokens: [FileToken], operation: ServiceOperation) {
        self.contract = contract
        self.id = id
        self.tokens = tokens
        self.operation = operation
    }

    public func encoded() throws -> Data {
        try Wire.encode(self)
    }

    /// **What the service refuses before it reaches the core.** `handles` is what the service learned of each descriptor
    /// that came with the request, in the order received (`HandleFacts`); `filesOf` is what each dictionary it has open
    /// is made of, by the files' ids, as it recorded at `openPackage`. The client may ask the same before sending, so
    /// its own mistake costs no round trip. In order:
    /// - handles against the operation: a package travels with one handle per file and never without (there is no path
    ///   anywhere in this contract, and the service opens nothing by name); nothing else travels with any;
    /// - the package's rules, the render ceiling and the suggestion limit (`Limits`);
    /// - at most one token per file, and **a token for every file the operation may read** (Codex objection 4: without
    ///   one, the identity check falls back to `fstat`, which a swapped folder leaves untouched). A dictionary absent from
    ///   `filesOf` is not refused here: the core answers `staleHandle` for it;
    /// - each handle **a regular file opened read-only** (objection 7) and **the very file its token names**, by device
    ///   and inode (objection 1): otherwise an import would hash one file and register it under another's identity.
    public func refusal(handles: [HandleFacts], filesOf: [DictId: [UUID]], editions: [Edition: DictId] = [:]) -> Refusal? {
        let spec = operation.packageSpec
        if let spec {
            if handles.isEmpty { return .missingHandle }
            if handles.count != spec.files.count {
                return .handleCountMismatch(files: spec.files.count, handles: handles.count)
            }
            if let problem = spec.problem { return .invalidPackage(problem) }
        } else if !handles.isEmpty {
            return .unexpectedHandles(count: handles.count)
        }
        if let render = operation.render, !(1...Limits.maxBodyBytes).contains(render.maxBodyBytes) {
            return .renderLimitOutOfRange(requested: render.maxBodyBytes, ceiling: Limits.maxBodyBytes)
        }
        if let text = operation.textRender {
            if !(1...Limits.maxBodyBytes).contains(text.maxBodyBytes) {
                return .renderLimitOutOfRange(requested: text.maxBodyBytes, ceiling: Limits.maxBodyBytes)
            }
            if !(1...Limits.maxTextBytes).contains(text.maxTextBytes) {
                return .textLimitOutOfRange(requested: text.maxTextBytes, ceiling: Limits.maxTextBytes)
            }
        }
        if case .suggest(_, _, let limit) = operation, limit > Limits.maxSuggestions {
            return .suggestLimitOutOfRange(requested: limit, ceiling: Limits.maxSuggestions)
        }
        var byFile: [UUID: FileToken] = [:]
        for token in tokens {
            if byFile.updateValue(token, forKey: token.file) != nil { return .duplicateToken(file: token.file) }
        }
        for file in operation.filesRead(filesOf: filesOf, editions: editions) where byFile[file] == nil {
            return .missingToken(file: file)
        }
        for (file, facts) in zip(spec?.files ?? [], handles) {
            guard facts.isRegularReadOnly else { return .notARegularReadOnlyFile(file: file.id) }
            guard case .present(let atPath) = byFile[file.id]?.state, let held = facts.identity,
                  held.device == atPath.device, held.inode == atPath.inode
            else { return .handleIsNotThePathsFile(file: file.id) }
        }
        return nil
    }

    /// **The service's reading of a request**: its size first (`Limits.maxEnvelopeBytes`), before any decoding; the
    /// header next, so a request of another version is answered `contractMismatch` without its operation being decoded
    /// (that version's operations may be unknown here); then the whole request; then `refusal(handles:filesOf:)`.
    /// Whatever is wrong is answered at once, never thrown, never a crash.
    public static func receive(_ envelope: Data, handles: [HandleFacts], filesOf: [DictId: [UUID]],
                               editions: [Edition: DictId] = [:], serviceContract: UInt32 = Contract.version) -> Admission {
        if let refusal = Limits.envelopeRefusal(envelope) {
            return .answered(Response(contract: serviceContract, id: nil, outcome: .failure(.refused(refusal))))
        }
        let header: Header
        do {
            header = try Wire.decode(Header.self, from: envelope)
        } catch {
            return .answered(Response(contract: serviceContract, id: nil,
                                      outcome: .failure(.undecodable(detail: "no envelope header: \(error)"))))
        }
        guard header.contract == serviceContract else {
            return .answered(Response(contract: serviceContract, id: header.id, outcome: .failure(
                .contractMismatch(service: serviceContract, client: header.contract))))
        }
        let request: Request
        do {
            request = try Wire.decode(Request.self, from: envelope)
        } catch {
            return .answered(Response(contract: serviceContract, id: header.id,
                                      outcome: .failure(.undecodable(detail: "\(error)"))))
        }
        if let refusal = request.refusal(handles: handles, filesOf: filesOf, editions: editions) {
            return .answered(Response(contract: serviceContract, id: request.id, outcome: .failure(.refused(refusal))))
        }
        return .admitted(request)
    }
}

/// The service's verdict on a request's bytes.
public enum Admission: Hashable, Sendable {
    /// Well formed, of this version, and not refused: the service may run it.
    case admitted(Request)
    /// Answer this at once; the core is never asked.
    case answered(Response)
}

/// What a request asks for. The core's operations (ADR-0007), with the core's parameters in the contract's types,
/// plus `cancel`, which the service implements, and the reader's lineage operations.
public enum ServiceOperation: Codable, Hashable, Sendable {
    /// The core's versions (ADR-0007 decision 11).
    case versions
    /// Hash, index and register a package (ADR-0007 decision 3): the slow call, reported through `ServiceEvent`s and
    /// cancelled by `cancel`. No deadline: bounded by `Deadlines.importSilence`. Sent with handles.
    case importPackage(spec: PackageSpec)
    /// Stop the import or health check `request` names, at its next progress report; it then answers `cancelled`.
    case cancel(request: UInt64)
    /// Open an imported package: headers only, never hashing (ADR-0007 decision 3). Sent with handles.
    case openPackage(spec: PackageSpec)
    /// Close a handle; idempotent in the core.
    case close(dict: DictId)
    case lookup(query: String, dicts: [DictId], options: LookupOptions)
    case suggest(prefix: String, dicts: [DictId], limit: UInt32)
    /// **A page of one dictionary's words** (plan-setup-v2 WI-6, ADR-0028): the public keys from key position
    /// `from`, for Core Spotlight. No body is read; the words come from the edition's index.
    case words(dict: DictId, from: UInt64, limit: UInt32)
    /// **The reverse-example query** (ADR-0031 d.4, d.9): the pairs whose Chinese contains `query`, from the
    /// dictionaries with a store, in their order. One without a store is answered in `notReady`, never as an error.
    case examples(query: String, dicts: [DictId], limit: UInt32)
    /// **Builds one dictionary's example store** (ADR-0031 d.3, d.6), in the background: like `health` it reports
    /// progress, has no deadline and stops by `cancel`; the reader's calls never wait for it.
    case examplesBuild(dict: DictId)
    /// **The phrases covering the captured term** (plan-phrase-recognition WI-7, contract 15): every ready dictionary's
    /// phrase that covers the word holding `term` in `sentence`, best first, with the state of each dictionary that
    /// could not answer. The sentence is untrusted text and the inventory is dictionary data: both stay in the service,
    /// and a store not built yet answers `building` rather than making the call wait.
    case phrases(sentence: String, term: PhraseTerm, dicts: [DictId])
    /// **Builds one dictionary's phrase inventory** (plan-phrase-recognition WI-4, WI-7): like `examplesBuild` it runs
    /// in the background, reports progress, has no deadline and stops by `cancel`.
    case phrasesBuild(dict: DictId)
    /// An entry rendered for `render`; its HTML is the reply's payload.
    case entry(dict: DictId, entry: EntryRef, render: RenderContext)
    case link(dict: DictId, url: String, origin: LinkOrigin, render: RenderContext)
    /// A resource by its path **inside the package** (encoded once, ADR-0007 decision 8), never a place on disk; its
    /// bytes, when found, are the reply's payload.
    case resource(dict: DictId, path: String, render: RenderContext)
    /// A lineage join, made only by the reader and reversibly (ADR-0002), as are the two below: the service calls the
    /// core's `join_lineage`, `split_lineage` and `lineage_of` (since 2026-10-14, WI-3; the app's side is WI-5's).
    /// **Idempotent**: joining an edition to the lineage it already has changes nothing and answers that lineage, so a
    /// retry after a lost reply is safe.
    case joinLineage(edition: Edition, lineage: LineageId)
    /// Undo a join: the edition takes `newLineage`, **minted by the client**, so a retried split is the same split and
    /// not a second one (Codex objection 14), or the lineage the edition had before the join, which the client kept,
    /// and which returns it exactly where it was. Never another dictionary's lineage: the core refuses that as
    /// `malformed`, since it would be a join (ADR-0002 decision 3, as amended 2026-10-14).
    case splitLineage(edition: Edition, newLineage: LineageId)
    /// The edition's lineage as the registry holds it: how a client whose join or split lost its reply (the service
    /// died after committing) learns what happened, without repeating it.
    case lineageOf(edition: Edition)
    /// The health check of an open dictionary's edition (plan-macos-v1 WI-12): every record read once, then kept beside
    /// its index, so asking again answers at once. Like an import it has no deadline, reports progress as events, and
    /// `cancel` stops it; the service runs it below the reader's calls.
    case health(dict: DictId)
    /// What the reading style does to an open dictionary (ADR-0010): its base size, the fonts it keeps, the sheets read
    /// and skipped, and what normalizing them changed. Computed in the service, which reads the sheets; a short call.
    case readingStyle(dict: DictId)
    /// Convert the Apple dictionary snapshot the app staged at `AppleImports/staging/<staging>/` of the app-group
    /// container, and publish it into a folder of its own (ADR-0011 decisions 4 and 9). No handle travels, no path: the
    /// service resolves the UUID in the container it shares with the app. One conversion runs at a time across the
    /// service, others waiting their turn; like an import it has no deadline and reports progress; a client that
    /// disconnects cancels its conversions. Refused as `WireError.appleImport`; cancelled as `CoreFailure.cancelled`.
    /// Either way the staging folder and any output are removed.
    case convertApple(staging: UUID)
    /// Stop this connection's conversion, running or waiting, at its next step; it then answers `cancelled`.
    case cancelConversion
    /// The display options an open dictionary's edition declares (ADR-0013): which apply, their values and defaults,
    /// and the CSS that keys on them. Read by the core from the edition's markup, in the service; a short call.
    case displayOptions(dict: DictId)
    /// **An entry as whole plain text** for a consumer that reads it (ADR-0021 d.5): the text, each run's span and
    /// roles, and the cut report when the text budget trimmed it. The core projects it from the same render an `entry`
    /// call gets (same guards, same roles); a cut is data, never an error. A bulk call, like `entry`.
    case entryText(dict: DictId, entry: EntryRef, text: TextRenderContext)
    /// **Record a reading in the local history** (ADR-0023, ADR-0024): the language filter runs before anything is
    /// written, and `operation` is the client's stable id for this record — a retry reuses it and is one event. The
    /// sentence travels here because the history stores it (D1); the core never sends it anywhere.
    case ledgerRecord(reading: LedgerReading, operation: String, targetLanguages: [String])
    /// The days the drawer shows, in the reader's own zone: `now` is the client's clock (whole epoch seconds) and
    /// `utcOffsetSeconds` its offset east of UTC. The core groups, collapses repeats and labels; the shell draws.
    case ledgerHistory(now: Double, utcOffsetSeconds: Int32)

    /// **Saves the reader's note on an entry** (plan §5.1): the core computes the definition's hash and resolves the
    /// lineage, so the note carries evidence and never the definition.
    case studyNote(dict: DictId, entry: EntryRef, text: String, name: String, stamp: StudyStamp, operation: String)
    /// The reader's notes, latest per target.
    case studyNotes
    /// **The review queue**: due cards, soonest first, a new card at once.
    case reviewQueue(now: Double, limit: UInt32)
    /// **One grade** (plan §5.3): the revision the reader saw and the configuration it is scheduled under.
    case reviewGrade(target: String, revision: String, grade: StudyGrade, policy: StudyPolicy, stamp: StudyStamp,
                     operation: String)
    /// **Voids the card's latest grade** while the card is still in the state it produced.
    case reviewUndo(target: String, gradeEvent: String, stamp: StudyStamp, operation: String)
    /// How many cards are due, and when the next falls due while none is.
    case reviewSummary(now: Double)
    /// The hash a note records for an entry's definition; never the definition itself.
    case definitionHash(dict: DictId, entry: EntryRef)
    /// **Re-anchors notes of one edition to another** under the same lineage (plan §5.1).
    case studyReanchor(oldEdition: Edition, newEdition: Edition, stamp: StudyStamp, operationPrefix: String)
    /// **Saves a note named by the history card's facts** — an entry reference, not a handle — resolved to the open
    /// dictionary of its edition.
    case studyNoteAt(entry: EntryRef, text: String, name: String, stamp: StudyStamp, operation: String)
    /// **The reader's export** (ADR-0023): one versioned JSON document of the log's events, no dictionary content.
    case exportData
    /// **Erase is a rewrite** (ADR-0024): readings, notes and grades leave the log; the receipt reports what it cleared.
    case eraseData(stamp: StudyStamp, operation: String)
    /// **The cards two devices' answers left in two states** (ADR-0027); they are not in the queue.
    case studyConflicts
    /// **Keeps one branch of a conflict**: `keep` names one of its candidates, and the others are voided with what came
    /// after them.
    case reviewResolve(target: String, keep: String, stamp: StudyStamp, operation: String)
    /// **Hides the readings a history card is made of** (ADR-0024), behind a tombstone that carries no content.
    case ledgerRemove(removal: Removal, operation: String)
    /// Shows them again: the same tombstone's shape, applied in reverse.
    case ledgerRestore(removal: Removal, operation: String)
    /// **One sync pass** (plan §2.6): every peer log in `input` merges, then this device's log is written to `output`.
    /// The two are the app group's — the service's sandbox cannot read the reader's folder. The artifact carries no
    /// dictionary text.
    case ledgerSync(input: String, output: String, device: String)

    /// The package this operation opens or imports, whose files' handles travel with it.
    public var packageSpec: PackageSpec? {
        switch self {
        case .importPackage(let spec), .openPackage(let spec): spec
        case .versions, .cancel, .close, .lookup, .suggest, .words, .entry, .link, .resource, .joinLineage,
             .splitLineage, .lineageOf, .health, .readingStyle, .convertApple, .cancelConversion, .displayOptions,
             .entryText, .examples, .examplesBuild, .phrases, .phrasesBuild,
             .ledgerRecord, .ledgerHistory, .studyNote, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo,
             .reviewSummary, .definitionHash, .studyReanchor, .studyNoteAt, .exportData, .eraseData, .studyConflicts,
             .reviewResolve, .ledgerSync, .ledgerRemove, .ledgerRestore: nil
        }
    }

    /// The render context of an operation that produces something a view shows.
    public var render: RenderContext? {
        switch self {
        case .entry(_, _, let render), .link(_, _, _, let render), .resource(_, _, let render): render
        case .versions, .importPackage, .cancel, .openPackage, .close, .lookup, .suggest, .words, .joinLineage,
             .splitLineage, .lineageOf, .health, .readingStyle, .convertApple, .cancelConversion, .displayOptions,
             .entryText, .examples, .examplesBuild, .phrases, .phrasesBuild,
             .ledgerRecord, .ledgerHistory, .studyNote, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo,
             .reviewSummary, .definitionHash, .studyReanchor, .studyNoteAt, .exportData, .eraseData, .studyConflicts,
             .reviewResolve, .ledgerSync, .ledgerRemove, .ledgerRestore: nil
        }
    }

    /// The text context of `entryText`: its body ceiling and its text budget.
    public var textRender: TextRenderContext? {
        switch self {
        case .entryText(_, _, let text): text
        default: nil
        }
    }

    /// An entry, a resource or an entry's text: the calls whose reply is the heaviest, of which
    /// `Limits.bulkCallsInFlight` run at once.
    public var isBulk: Bool {
        // **One classification, not two lists that drift** (audit round 1, 2026-10-26): the credit class already says
        // which calls are bulk, and every bulk call is exactly one that holds a bulk credit.
        creditClass == .bulk
    }

    /// Which of a connection's credits this operation holds while it runs (`Credits`): bulk for an entry or a resource,
    /// lookup for the calls that search an index or open a package; none for the rest.
    public var creditClass: CreditClass? {
        switch self {
        case .entry, .resource, .entryText, .studyNote, .studyNoteAt, .definitionHash, .studyReanchor: .bulk
        case .openPackage, .lookup, .suggest, .words, .link, .examples, .phrases: .lookup
        case .versions, .importPackage, .cancel, .close, .joinLineage, .splitLineage, .lineageOf, .health,
             .readingStyle, .convertApple, .cancelConversion, .displayOptions, .examplesBuild, .phrasesBuild, .ledgerRecord,
             .ledgerHistory, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo, .reviewSummary,
             .exportData, .eraseData, .studyConflicts, .reviewResolve, .ledgerSync, .ledgerRemove, .ledgerRestore: nil
        }
    }

    /// **The editions this operation reads through, when it names an edition rather than a handle** (audit rounds 1–4,
    /// 2026-10-26): `studyNoteAt` resolves its entry's edition and `studyReanchor` the edition it moves to, and both read
    /// entries — admission has to know which dictionary's files that is.
    public var editionsRead: [Edition] {
        switch self {
        case .studyNoteAt(let entry, _, _, _, _): [entry.edition]
        case .studyReanchor(_, let newEdition, _, _): [newEdition]
        default: []
        }
    }

    /// Every file this operation may read: its package's, or those of each dictionary it names, as `filesOf` records
    /// them, and the files of the dictionaries its editions name. `close` reads nothing.
    func filesRead(filesOf: [DictId: [UUID]], editions: [Edition: DictId] = [:]) -> [UUID] {
        let direct: [UUID] = switch self {
        case .importPackage(let spec), .openPackage(let spec): spec.files.map(\.id)
        case .entry(let dict, _, _), .link(let dict, _, _, _), .resource(let dict, _, _), .health(let dict),
             .readingStyle(let dict), .displayOptions(let dict), .entryText(let dict, _, _),
             .examplesBuild(let dict), .phrasesBuild(let dict), .studyNote(let dict, _, _, _, _, _),
             .definitionHash(let dict, _):
            filesOf[dict] ?? []
        case .lookup(_, let dicts, _), .suggest(_, let dicts, _), .examples(_, let dicts, _),
             .phrases(_, _, let dicts):
            dicts.flatMap { filesOf[$0] ?? [] }
        case .words(let dict, _, _): filesOf[dict] ?? []
        // **These read through an edition, not a handle** (`editionsRead` adds those files), or read nothing at all.
        case .versions, .cancel, .close, .joinLineage, .splitLineage, .lineageOf, .convertApple, .cancelConversion,
             .ledgerRecord, .ledgerHistory, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo, .reviewSummary,
             .studyNoteAt, .studyReanchor, .exportData, .eraseData, .studyConflicts, .reviewResolve, .ledgerSync,
             .ledgerRemove, .ledgerRestore: []
        }
        return direct + editionsRead.flatMap { edition in editions[edition].map { filesOf[$0] ?? [] } ?? [] }
    }

    var answerKind: AnswerKind {
        switch self {
        case .versions: .versions
        case .importPackage: .imported
        case .cancel, .cancelConversion: .cancellation
        case .openPackage: .opened
        case .close: .closed
        case .lookup: .page
        case .suggest: .suggestions
        case .words: .words
        case .entry: .entry
        case .link: .link
        case .resource: .resource
        case .joinLineage, .splitLineage, .lineageOf: .lineage
        case .health: .health
        case .readingStyle: .readingStyle
        case .convertApple: .converted
        case .displayOptions: .displayOptions
        case .entryText: .entryText
        case .examples: .examples
        case .examplesBuild: .examplesBuilt
        case .phrases: .phrases
        case .phrasesBuild: .phrasesBuilt
        case .ledgerRecord, .ledgerRemove, .ledgerRestore: .ledgerRecord
        case .ledgerHistory: .ledgerHistory
        case .studyNote, .studyNoteAt: .studyNote
        case .studyNotes: .studyNotes
        case .reviewQueue: .reviewQueue
        case .reviewGrade, .reviewUndo: .reviewOutcome
        case .reviewSummary: .reviewSummary
        case .definitionHash: .definitionHash
        case .studyReanchor: .reanchored
        case .exportData: .exported
        case .eraseData: .erased
        case .studyConflicts: .conflicts
        case .reviewResolve: .reviewOutcome
        case .ledgerSync: .synced
        }
    }

    /// An import, a health check or a conversion: the long calls, bounded by silence between their progress events rather than by a
    /// deadline (`Deadlines.importSilence`), and stopped by `cancel`.
    public var reportsProgress: Bool {
        switch self {
        case .importPackage, .health, .convertApple, .examplesBuild, .phrasesBuild: true
        case .versions, .cancel, .openPackage, .close, .lookup, .suggest, .words, .entry, .link, .resource,
             .joinLineage, .splitLineage, .lineageOf, .readingStyle, .cancelConversion, .displayOptions, .entryText,
             .examples, .phrases, .ledgerRecord,
             .ledgerHistory, .studyNote, .studyNotes, .reviewQueue, .reviewGrade, .reviewUndo, .reviewSummary,
             .definitionHash, .studyReanchor, .studyNoteAt, .exportData, .eraseData, .studyConflicts, .reviewResolve,
             .ledgerSync, .ledgerRemove, .ledgerRestore: false
        }
    }
}

// MARK: - The reply

/// What the service answers: one per request, through the request's own reply block, the envelope as the first `Data`
/// and the payload, if the answer carries one, as the second.
public struct Response: Codable, Hashable, Sendable {
    public let contract: UInt32
    /// The request's id; absent only when the service could not read one.
    public let id: UInt64?
    public let outcome: Outcome

    public init(contract: UInt32 = Contract.version, id: UInt64?, outcome: Outcome) {
        self.contract = contract
        self.id = id
        self.outcome = outcome
    }

    /// The envelope's bytes. Encoding cannot fail for these types (no floating point, nothing custom); were it to, the
    /// service sends an empty envelope, which `read` reports as `undecodable`.
    public func encoded() throws -> Data {
        try Wire.encode(self)
    }

    /// **The reply as it is sent: envelope and payload, held to the envelope ceiling on the way out as the client holds
    /// it on the way in** (verification finding, 2026-10-20): a field the input can grow — an entry's key is echoed
    /// whole — must not make a reply the receiver refuses. Over the ceiling the reply becomes a typed `envelopeTooLarge`
    /// refusal, **and the payload the answer carried goes with the answer** (audit round 4, 2026-10-26): `Response.read`
    /// refuses a failure with a payload, so keeping it would have made the refusal itself undeliverable.
    public func bounded(payload: Data?) throws -> (envelope: Data, payload: Data?) {
        let data = try encoded()
        guard let refusal = Limits.envelopeRefusal(data) else { return (data, payload) }
        return (try Response(contract: contract, id: id, outcome: .failure(.refused(refusal))).encoded(), nil)
    }

    /// **The client's reading of a reply to `request`**: its size first (`Limits.maxEnvelopeBytes`), then the header
    /// (another version is `contractMismatch`, whatever follows it), then the whole response, then what must hold of it
    /// — the request's id, an answer of the kind the operation has, a payload exactly where that kind carries one, and
    /// under the ceiling the client holds for it (`Limits.payloadCeiling`: the view's for an entry and for a resource
    /// the view renders, Codex objection 9), checked before anything sees the bytes.
    public static func read(_ envelope: Data, payload: Data?, answering request: Request,
                            clientContract: UInt32 = Contract.version) -> Result<Delivered, WireError> {
        if let refusal = Limits.envelopeRefusal(envelope) { return .failure(.refused(refusal)) }
        let header: Header
        do {
            header = try Wire.decode(Header.self, from: envelope)
        } catch {
            return .failure(.undecodable(detail: "no envelope header: \(error)"))
        }
        guard header.contract == clientContract else {
            return .failure(.contractMismatch(service: header.contract, client: clientContract))
        }
        let response: Response
        do {
            response = try Wire.decode(Response.self, from: envelope)
        } catch {
            return .failure(.undecodable(detail: "\(error)"))
        }
        switch response.outcome {
        case .failure(let error):
            // A failure may carry no id: the service could not read the request's.
            if let id = response.id, id != request.id {
                return .failure(.undecodable(detail: "a reply to request \(id) arrived for request \(request.id)"))
            }
            guard payload == nil else { return .failure(.undecodable(detail: "a failure arrived with a payload")) }
            return .failure(error)
        case .answer(let answer):
            guard response.id == request.id else {
                return .failure(.undecodable(detail: "a reply to request \(response.id.map(String.init) ?? "none") "
                                             + "arrived for request \(request.id)"))
            }
            guard answer.answers(request.operation) else {
                return .failure(.undecodable(detail: "a \(answer.kind) answer arrived for a "
                                             + "\(request.operation.answerKind) request"))
            }
            guard answer.carriesPayload == (payload != nil) else {
                return .failure(.undecodable(detail: answer.carriesPayload
                    ? "a \(answer.kind) answer arrived without its payload" : "a \(answer.kind) answer arrived with a payload"))
            }
            if let payload, let ceiling = Limits.payloadCeiling(for: request.operation, answer: answer),
               UInt64(payload.count) > ceiling {
                return .failure(.refused(.payloadTooLarge(bytes: UInt64(payload.count), limit: ceiling)))
            }
            return .success(Delivered(answer: answer, payload: payload))
        }
    }
}

/// An answer, or why there is none.
public enum Outcome: Codable, Hashable, Sendable {
    case answer(Answer)
    case failure(WireError)
}

/// A reply the client has read and checked: the answer, and its payload where its kind carries one.
public struct Delivered: Hashable, Sendable {
    public let answer: Answer
    public let payload: Data?

    public init(answer: Answer, payload: Data?) {
        self.answer = answer
        self.payload = payload
    }
}

/// One answer per operation (`ServiceOperation.answerKind`), each the core's record in the contract's types.
public enum Answer: Codable, Hashable, Sendable {
    case versions(Versions)
    case imported(Imported)
    case cancellation(Cancellation)
    case opened(Opened)
    case closed
    case page(Page)
    case suggestions([String])
    /// A page of one dictionary's words (contract 13).
    case words(Words)
    /// The entry's reference, policy and lossy count; **its HTML is the payload**, as UTF-8.
    case entry(Entry)
    case link(Link)
    /// **A found resource's bytes are the payload**; a missing one has none.
    case resource(Resource)
    /// The edition's lineage: after a join or a split, the one it now has; for `lineageOf`, none when the registry does
    /// not know the edition.
    case lineage(LineageId?)
    /// What the health check found.
    case health(Health)
    /// What the reading style does to the dictionary.
    case readingStyle(ReadingStyle)
    /// What a conversion published (contract 6).
    case converted(Converted)
    /// The display options the dictionary's edition declares (contract 7).
    case displayOptions(DisplayOptions)
    /// An entry as plain text, its spans and its cut report (contract 8).
    case entryText(EntryText)
    /// The reverse-example query's hits (contract 14).
    case examples(Examples)
    /// What building one dictionary's example store did (contract 14).
    case examplesBuilt(ExamplesBuilt)
    /// What the phrase question found (contract 15).
    case phrases(PhraseAnswer)
    /// What building one dictionary's phrase inventory did (contract 15).
    case phrasesBuilt(PhrasesBuilt)
    /// What recording one reading did (contract 9).
    case ledgerRecord(LedgerRecordOutcome)
    /// The days the drawer shows (contract 9).
    case ledgerHistory(LedgerHistory)
    /// The saved note, and the notes as the log holds them (contract 10).
    case studyNote(StudyNote)
    case studyNotes([StudyNote])
    /// The review queue (contract 10).
    case reviewQueue([StudyCard])
    /// What a grade or an undo did (contract 10).
    case reviewOutcome(StudyOutcome)
    case reviewSummary(ReviewSummary)
    /// An entry's definition hash, as a note records it (contract 10).
    case definitionHash(String)
    /// What a re-anchor found for each note (contract 10).
    case reanchored(ReanchorReport)
    /// The log's events as the reader's export (contract 10).
    case exported(String)
    /// What an erase cleared (contract 10).
    case erased(StudyEraseReport)
    /// The cards two devices left conflicted, with their candidates (contract 11).
    case conflicts([CardConflict])
    /// What one sync pass did with the reader's folder (contract 11).
    case synced(SyncReport)

    /// Whether a payload travels beside this answer: an entry, or a found resource.
    public var carriesPayload: Bool {
        switch self {
        case .entry, .resource(.found): true
        case .versions, .imported, .cancellation, .opened, .closed, .page, .suggestions, .words, .link,
             .resource(.missing), .lineage, .health, .readingStyle, .converted, .displayOptions, .entryText,
             .examples, .examplesBuilt, .phrases, .phrasesBuilt, .ledgerRecord,
             .ledgerHistory, .studyNote, .studyNotes, .reviewQueue, .reviewOutcome, .reviewSummary, .definitionHash,
             .reanchored, .exported, .erased, .conflicts, .synced: false
        }
    }

    /// Whether this is the kind of answer `operation` has. A join or a split always leaves the edition a lineage.
    public func answers(_ operation: ServiceOperation) -> Bool {
        guard kind == operation.answerKind else { return false }
        switch (self, operation) {
        case (.lineage(.none), .joinLineage), (.lineage(.none), .splitLineage): return false
        default: return true
        }
    }

    var kind: AnswerKind {
        switch self {
        case .versions: .versions
        case .imported: .imported
        case .cancellation: .cancellation
        case .opened: .opened
        case .closed: .closed
        case .page: .page
        case .suggestions: .suggestions
        case .words: .words
        case .entry: .entry
        case .link: .link
        case .resource: .resource
        case .lineage: .lineage
        case .health: .health
        case .readingStyle: .readingStyle
        case .converted: .converted
        case .displayOptions: .displayOptions
        case .entryText: .entryText
        case .examples: .examples
        case .examplesBuilt: .examplesBuilt
        case .phrases: .phrases
        case .phrasesBuilt: .phrasesBuilt
        case .ledgerRecord: .ledgerRecord
        case .ledgerHistory: .ledgerHistory
        case .studyNote: .studyNote
        case .studyNotes: .studyNotes
        case .reviewQueue: .reviewQueue
        case .reviewOutcome: .reviewOutcome
        case .reviewSummary: .reviewSummary
        case .definitionHash: .definitionHash
        case .reanchored: .reanchored
        case .exported: .exported
        case .erased: .erased
        case .conflicts: .conflicts
        case .synced: .synced
        }
    }
}

/// What `cancel` or `cancelConversion` found.
public enum Cancellation: String, Codable, Hashable, Sendable {
    /// The import, health check or conversion was running or waiting; it stops at its next progress report and answers
    /// `cancelled`.
    case stopping
    /// No import or health check of that id is running, or no conversion of this connection: it never ran here, or it
    /// has already answered.
    case notRunning
}

/// Which answer an operation has: the pairing `Response.read` checks.
enum AnswerKind: String, Sendable {
    case versions, imported, cancellation, opened, closed, page, suggestions, words, entry, link, resource, lineage, health
    case readingStyle, converted, displayOptions, entryText, examples, examplesBuilt, phrases, phrasesBuilt, ledgerRecord,
         ledgerHistory
    case studyNote, studyNotes, reviewQueue, reviewOutcome, reviewSummary, definitionHash, reanchored
    case exported, erased, conflicts, synced
}

// MARK: - Events

/// What the service tells the app unasked, through the `ServiceEventsXPC` object the app exports on its connection:
/// an import's progress, so the client can tell a long import from a stuck one (`Deadlines.importSilence`).
public struct ServiceEvent: Codable, Hashable, Sendable {
    public let contract: UInt32
    /// The id of the request the event reports on.
    public let request: UInt64
    public let kind: Kind

    public enum Kind: Codable, Hashable, Sendable {
        /// Bytes read of all the package's files: the core's own report, per 4 MiB chunk while it hashes.
        case progress(done: UInt64, total: UInt64)
    }

    public init(contract: UInt32 = Contract.version, request: UInt64, kind: Kind) {
        self.contract = contract
        self.request = request
        self.kind = kind
    }

    public func encoded() throws -> Data {
        try Wire.encode(self)
    }

    /// The client's reading of an event: its size, then the header, as for a reply.
    public static func read(_ data: Data, clientContract: UInt32 = Contract.version) -> Result<ServiceEvent, WireError> {
        if let refusal = Limits.envelopeRefusal(data) { return .failure(.refused(refusal)) }
        let header: Header
        do {
            header = try Wire.decode(Header.self, from: data)
        } catch {
            return .failure(.undecodable(detail: "no event header: \(error)"))
        }
        guard header.contract == clientContract else {
            return .failure(.contractMismatch(service: header.contract, client: clientContract))
        }
        do {
            return .success(try Wire.decode(ServiceEvent.self, from: data))
        } catch {
            return .failure(.undecodable(detail: "\(error)"))
        }
    }
}

// MARK: - The wire

/// The part of every envelope that never changes: `contract`, and `id` where the envelope has one. Read leniently — an
/// `id` that is absent or not a number is no id — because it is read from messages of any version.
struct Header: Decodable {
    let contract: UInt32
    let id: UInt64?

    enum CodingKeys: String, CodingKey {
        case contract, id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contract = try container.decode(UInt32.self, forKey: .contract)
        id = try? container.decodeIfPresent(UInt64.self, forKey: .id)
    }
}

/// JSON, keys sorted so one value always encodes to the same bytes.
enum Wire {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
