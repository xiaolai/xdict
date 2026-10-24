import Foundation
import XDictContract
import XDictCore

// **The service's half of the frozen contract: the core's types into the contract's, and back for parameters**
// (ADR-0007 decision 10: every `CoreError` variant crosses as its own kind). Every switch over a core enum is
// exhaustive, so a variant the core adds stops the service compiling instead of crossing as something else. The two
// modules share many names (`Entry`, `Link`, `Page`…), so every type here is written with its module.

// MARK: - Errors

extension CoreFailure {
    init(_ error: CoreError) {
        switch error {
        case .Unsupported(let feature, let detail): self = .unsupported(feature: XDictContract.Feature(feature), detail: detail)
        case .Malformed(let detail): self = .malformed(detail: detail)
        case .TooLarge(let limit, let detail): self = .tooLarge(limit: XDictContract.Limit(limit), detail: detail)
        case .NotFound(let what, let detail): self = .notFound(what: XDictContract.Missing(what), detail: detail)
        case .Io(let kind, let detail): self = .io(kind: XDictContract.IoKind(kind), detail: detail)
        case .StaleHandle(let detail): self = .staleHandle(detail: detail)
        case .EditionMismatch(let detail): self = .editionMismatch(detail: detail)
        case .SourceChanged(let detail): self = .sourceChanged(detail: detail)
        case .Cancelled(let detail): self = .cancelled(detail: detail)
        case .Incompatible(let core, let client, let detail): self = .incompatible(core: core, client: client, detail: detail)
        case .Internal(let detail): self = .internalFault(detail: detail)
        }
    }
}

extension WireError {
    init(core error: CoreError) {
        self = .core(CoreFailure(error))
    }
}

extension XDictContract.Feature {
    init(_ feature: XDictCore.Feature) {
        switch feature {
        case .formatVersion(let version): self = .formatVersion(version: version)
        case .resourceLibraryV3: self = .resourceLibraryV3
        case .registrationCode: self = .registrationCode
        case .encryptionFlags(let flags): self = .encryptionFlags(flags: flags)
        case .lzoInV3: self = .lzoInV3
        case .compressionType(let code): self = .compressionType(code: code)
        case .blockEncryption(let code): self = .blockEncryption(code: code)
        case .encoding(let name): self = .encoding(name: name)
        }
    }
}

extension XDictContract.Limit {
    init(_ limit: XDictCore.Limit) {
        switch limit {
        case .file: self = .file
        case .page: self = .page
        case .body: self = .body
        }
    }
}

extension XDictContract.Missing {
    init(_ missing: XDictCore.Missing) {
        switch missing {
        case .file: self = .file
        case .entry: self = .entry
        case .edition: self = .edition
        case .lineage: self = .lineage
        }
    }
}

extension XDictContract.IoKind {
    init(_ kind: XDictCore.IoKind) {
        switch kind {
        case .notFound: self = .notFound
        case .permissionDenied: self = .permissionDenied
        case .shortRead: self = .shortRead
        case .outOfMemory: self = .outOfMemory
        case .other: self = .other
        }
    }
}

// MARK: - Answers

extension XDictContract.Versions {
    init(_ versions: XDictCore.Versions) {
        self.init(protocolVersion: versions.protocol, core: versions.core, indexFormat: versions.indexFormat,
                  normalization: versions.normalization)
    }
}

extension XDictContract.DictInfo {
    init(_ info: XDictCore.DictInfo) {
        self.init(title: info.title, description: info.description, formatVersion: info.formatVersion, keys: info.keys)
    }
}

extension XDictContract.Problem {
    init(_ problem: XDictCore.Problem) {
        switch problem {
        case .volumeUnreadable(let name, let error): self = .volumeUnreadable(name: name, error: CoreFailure(error))
        }
    }
}

extension XDictContract.Imported {
    init(_ imported: XDictCore.Imported) {
        self.init(edition: Edition(rawValue: imported.edition), lineage: LineageId(rawValue: imported.lineage),
                  info: XDictContract.DictInfo(imported.info), problems: imported.problems.map(XDictContract.Problem.init))
    }
}

extension XDictContract.ImportReason {
    init(_ reason: XDictCore.ImportReason) {
        switch reason {
        case .new: self = .new
        case .changed: self = .changed
        case .indexMissing: self = .indexMissing
        case .indexOutdated: self = .indexOutdated
        case .noIdentity: self = .noIdentity
        }
    }
}

extension XDictContract.Opened {
    init(_ opened: XDictCore.Opened) {
        switch opened {
        case .ready(let dict, let edition, let info):
            self = .ready(dict: DictId(rawValue: dict), edition: Edition(rawValue: edition), info: XDictContract.DictInfo(info))
        case .needsImport(let reason): self = .needsImport(reason: XDictContract.ImportReason(reason))
        }
    }
}

extension XDictContract.EntryRef {
    init(_ ref: XDictCore.EntryRef) {
        self.init(edition: Edition(rawValue: ref.edition), key: ref.key, occurrence: ref.occurrence)
    }
}

extension XDictContract.How {
    init(_ how: XDictCore.How) {
        switch how {
        case .exact: self = .exact
        case .folded: self = .folded
        case .unmarked: self = .unmarked
        case .redirect(let chain): self = .redirect(chain: chain)
        }
    }
}

extension XDictContract.HitProblem {
    init(_ problem: XDictCore.HitProblem) {
        switch problem {
        case .danglingRedirect(let from, let target): self = .danglingRedirect(from: from, target: target)
        case .redirectLoop(let chain): self = .redirectLoop(chain: chain)
        case .redirectLimit(let chain): self = .redirectLimit(chain: chain)
        }
    }
}

extension XDictContract.Hit {
    init(_ hit: XDictCore.Hit) {
        self.init(dict: DictId(rawValue: hit.dict), entry: XDictContract.EntryRef(hit.entry), headword: hit.headword,
                  how: XDictContract.How(hit.how), problems: hit.problems.map(XDictContract.HitProblem.init))
    }
}

extension XDictContract.Words {
    init(_ words: XDictCore.Words) {
        self.init(edition: XDictContract.Edition(rawValue: words.edition), words: words.words, total: words.total,
                  next: words.next)
    }
}

extension XDictContract.ExampleSource {
    init(_ source: XDictCore.ExampleSource) {
        self.init(dict: DictId(rawValue: source.dict), entry: XDictContract.EntryRef(source.entry),
                  headword: source.headword)
    }
}

extension XDictContract.ExampleHit {
    init(_ hit: XDictCore.ExampleHit) {
        self.init(english: hit.english, chinese: hit.chinese, start: hit.start, len: hit.len, sentence: hit.sentence,
                  sources: hit.sources.map(XDictContract.ExampleSource.init))
    }
}

extension XDictContract.Examples {
    init(_ examples: XDictCore.Examples) {
        self.init(hits: examples.hits.map(XDictContract.ExampleHit.init), total: examples.total,
                  notReady: examples.notReady.map { DictId(rawValue: $0) }, capped: examples.capped)
    }
}

extension XDictContract.ExamplesBuilt {
    init(_ built: XDictCore.ExamplesBuilt) {
        self.init(edition: Edition(rawValue: built.edition), pairs: built.pairs, roles: built.roles,
                  fallback: built.fallback, entries: built.entries, failed: built.failed, noChinese: built.noChinese,
                  cached: built.cached)
    }
}

extension XDictContract.Page {
    init(_ page: XDictCore.Page) {
        self.init(hits: page.hits.map(XDictContract.Hit.init), total: page.total, generation: page.generation,
                  problems: page.problems.map(XDictContract.HitProblem.init))
    }
}

extension XDictContract.BlockReason {
    init(_ reason: XDictCore.BlockReason) {
        switch reason {
        case .remote(let url): self = .remote(url: url)
        case .script: self = .script
        case .unknownScheme(let scheme): self = .unknownScheme(scheme: scheme)
        }
    }
}

extension XDictContract.Link {
    init(_ link: XDictCore.Link) {
        switch link {
        case .lookup(let query, let anchor): self = .lookup(query: query, anchor: anchor)
        case .resource(let path): self = .resource(path: path)
        case .sound(let path): self = .sound(path: path)
        case .speak(let text): self = .speak(text: text)
        case .anchor(let name): self = .anchor(name: name)
        case .blocked(let why): self = .blocked(why: XDictContract.BlockReason(why))
        }
    }
}

extension Answer {
    /// An entry's answer, and its HTML as the payload, UTF-8: never inside the JSON.
    static func of(_ entry: XDictCore.Entry) -> (Answer, Data) {
        (.entry(XDictContract.Entry(entry: XDictContract.EntryRef(entry.entry), csp: entry.csp, lossyBytes: entry.lossyBytes)),
         Data(entry.html.utf8))
    }

    /// A resource's answer, and its bytes as the payload when it was found.
    static func of(_ resource: XDictCore.Resource) -> (Answer, Data?) {
        switch resource {
        case .found(let path, let mime, let bytes): (.resource(.found(path: path, mime: mime)), bytes)
        case .missing(let path): (.resource(.missing(path: path)), nil)
        }
    }
}

// MARK: - Parameters, the other way

extension XDictCore.EntryRef {
    init(_ ref: XDictContract.EntryRef) {
        self.init(edition: ref.edition.rawValue, key: ref.key, occurrence: ref.occurrence)
    }
}

extension XDictCore.MatchMode {
    init(_ mode: XDictContract.MatchMode) {
        switch mode {
        case .reader: self = .reader
        case .link: self = .link
        }
    }
}

extension XDictCore.LookupOptions {
    init(_ options: XDictContract.LookupOptions) {
        self.init(limit: options.limit, offset: options.offset, mode: XDictCore.MatchMode(options.mode),
                  generation: options.generation)
    }
}

extension XDictCore.LinkOrigin {
    init(_ origin: XDictContract.LinkOrigin) {
        switch origin {
        case .entry(let entry): self = .entry(entry: XDictCore.EntryRef(entry))
        case .resource(let path): self = .resource(path: path)
        }
    }
}

extension XDictCore.View {
    /// The core's view for a render context: the contract's one base, the request's ceiling and style.
    init(_ render: RenderContext) {
        self.init(baseUrl: RenderContext.baseURL, maxBodyBytes: render.maxBodyBytes, originalStyle: render.originalStyle)
    }
}

extension XDictCore.TextView {
    /// The core's text view for a text render context: the same base and ceiling as `entry`, plus the text budget.
    init(_ text: TextRenderContext) {
        self.init(baseUrl: TextRenderContext.baseURL, maxBodyBytes: text.maxBodyBytes, maxTextBytes: text.maxTextBytes,
                  originalStyle: text.originalStyle)
    }
}

extension XDictContract.EntryText {
    /// The core's projection in the contract's record: the same fields, one for one.
    init(_ projected: XDictCore.EntryText) {
        self.init(entry: XDictContract.EntryRef(projected.entry), text: projected.text,
                  spans: projected.spans.map {
                      XDictContract.TextSpan(start: $0.start, len: $0.len, role: $0.role, label: $0.label,
                                             section: $0.section, sense: $0.sense)
                  },
                  senses: projected.senses.map {
                      XDictContract.Sense(id: $0.id, start: $0.start, len: $0.len, label: $0.label,
                                          section: $0.section, parent: $0.parent, whole: $0.whole)
                  },
                  style: projected.style,
                  complete: projected.complete, omittedBytes: projected.omittedBytes, cutAt: projected.cutAt,
                  spansDropped: projected.spansDropped)
    }
}

extension XDictCore.FileIdentity {
    init(_ identity: XDictContract.FileIdentity) {
        self.init(device: identity.device, inode: identity.inode, size: identity.size, mtimeNs: identity.mtimeNs,
                  ctimeNs: identity.ctimeNs)
    }
}

// MARK: - Health (WI-12)

extension XDictContract.Health {
    init(_ health: XDictCore.Health) {
        self.init(version: health.version, entries: health.entries,
                  findings: health.findings.map {
                      XDictContract.HealthFinding(kind: XDictContract.FindingKind($0.kind), count: $0.count, name: $0.name,
                                                  examples: $0.examples.map { XDictContract.HealthExample(key: $0.key, text: $0.text) })
                  },
                  classes: health.classes.map { XDictContract.HealthClass(name: $0.name, count: $0.count) })
    }
}

extension XDictContract.FindingKind {
    init(_ kind: XDictCore.FindingKind) {
        switch kind {
        case .missingFile: self = .missingFile
        case .missingSounds: self = .missingSounds
        case .missingImages: self = .missingImages
        case .missingWords: self = .missingWords
        case .codeAsText: self = .codeAsText
        case .commentMarks: self = .commentMarks
        case .styleAsText: self = .styleAsText
        case .brokenRedirects: self = .brokenRedirects
        case .doubleEncoded: self = .doubleEncoded
        case .undecodable: self = .undecodable
        case .emptyEntries: self = .emptyEntries
        case .hugeEntries: self = .hugeEntries
        case .repeatedEntries: self = .repeatedEntries
        case .oddHeadwords: self = .oddHeadwords
        case .repaired: self = .repaired
        }
    }
}

// MARK: - Reading style (ADR-0010)

extension XDictContract.ReadingStyle {
    init(_ style: XDictCore.ReadingStyle) {
        let base: XDictContract.BaseSource = switch style.baseFrom {
        case .page(let selector): .page(selector: selector)
        case .prose(let weight): .prose(weight: weight)
        case .text(let chars, let share): .text(chars: chars, share: share)
        case .browserDefault: .browserDefault
        }
        let c = style.changes
        self.init(version: style.version, basePx: style.basePx, baseFrom: base,
                  fonts: style.fonts.map {
                      let reason: XDictContract.FontReason = switch $0.reason {
                      case .privateUse: .privateUse
                      case .pseudoContent: .pseudoContent
                      case .phonetic: .phonetic
                      }
                      return XDictContract.KeptFont(family: $0.family, reason: reason, selector: $0.selector)
                  },
                  sheets: style.sheets,
                  skipped: style.skipped.map {
                      let reason: XDictContract.SkipReason = switch $0.reason {
                      case .tooMany(let limit): .tooMany(limit: limit)
                      case .tooLarge(let limit, let detail): .tooLarge(limit: limit, detail: detail)
                      case .notFound: .notFound
                      case .unreadable(let detail): .unreadable(detail: detail)
                      }
                      return XDictContract.SkippedSheet(path: $0.path, reason: reason)
                  },
                  changes: XDictContract.StyleChanges(important: c.important, page: c.page, family: c.family, size: c.size,
                                                      lineHeight: c.lineHeight, colour: c.colour, weight: c.weight,
                                                      space: c.space, dropped: c.dropped))
    }
}

// MARK: - Display options (ADR-0013)

extension XDictContract.DisplayOptions {
    init(_ options: XDictCore.DisplayOptions) {
        self.init(version: options.version,
                  options: options.options.map {
                      XDictContract.DisplayOption(id: $0.id, attribute: $0.attribute, values: $0.values,
                                                  defaultValue: $0.defaultValue)
                  },
                  css: options.css)
    }
}

// MARK: - The reading history (ADR-0023, ADR-0024)

extension XDictCore.Reading {
    /// The contract's reading as the core records it: the fields one for one.
    init(_ reading: XDictContract.LedgerReading) {
        self.init(surface: reading.surface, lemma: reading.lemma, sentence: reading.sentence,
                  span: reading.span.map { XDictCore.ReadingSpan(start: $0.start, len: $0.len) },
                  cut: reading.cut, quality: reading.quality, edition: reading.edition, entryKey: reading.entryKey,
                  occurrence: reading.occurrence, dictionaryName: reading.dictionaryName, language: reading.language,
                  at: reading.at, device: reading.device)
    }
}

extension XDictContract.LedgerReading {
    /// The core's reading in the contract's record: what a history reply carries.
    init(_ reading: XDictCore.Reading) {
        self.init(surface: reading.surface, lemma: reading.lemma, sentence: reading.sentence,
                  span: reading.span.map { XDictContract.LedgerSpan(start: $0.start, len: $0.len) },
                  cut: reading.cut, quality: reading.quality, edition: reading.edition, entryKey: reading.entryKey,
                  occurrence: reading.occurrence, dictionaryName: reading.dictionaryName, language: reading.language,
                  at: reading.at, device: reading.device)
    }
}

extension XDictContract.LedgerRecordOutcome {
    init(_ outcome: XDictCore.RecordOutcome) {
        switch outcome {
        case .recorded: self = .recorded
        case .duplicate: self = .duplicate
        case .uncertain: self = .uncertain
        case .skippedLanguage: self = .skippedLanguage
        case .ineligible: self = .ineligible
        }
    }
}

extension XDictContract.LedgerDayLabel {
    init(_ label: XDictCore.DayLabel) {
        switch label {
        case .today: self = .today
        case .yesterday: self = .yesterday
        case .weekday: self = .weekday
        case .date: self = .date
        }
    }
}

extension XDictContract.LedgerHistory {
    /// The core's days in the contract's record: grouping and ordering are the core's, the shell adds nothing.
    init(_ history: XDictCore.History) {
        self.init(days: history.days.map {
            XDictContract.LedgerDay(id: $0.id, start: $0.start, label: XDictContract.LedgerDayLabel($0.label),
                                    cards: $0.cards.map {
                                        XDictContract.LedgerCard(reading: XDictContract.LedgerReading($0.reading),
                                                                 times: $0.times, events: $0.events)
                                    })
        })
    }
}

// MARK: - Study (plan-history-and-learning §5)

extension XDictCore.Stamp {
    init(_ stamp: StudyStamp) {
        self.init(at: stamp.at, device: stamp.device)
    }
}

extension XDictCore.ReviewPolicy {
    init(_ policy: StudyPolicy) {
        self.init(retention: policy.retention, maximumDays: policy.maximumDays)
    }
}

extension XDictContract.StudyTargetKind {
    init(_ kind: XDictCore.TargetKind) {
        switch kind {
        case .entry: self = .entry
        }
    }
}

extension XDictContract.StudyPhase {
    init(_ phase: XDictCore.StudyPhase) {
        switch phase {
        case .new: self = .new
        case .learning: self = .learning
        case .review: self = .review
        case .relearning: self = .relearning
        }
    }
}

extension XDictContract.StudyTarget {
    init(_ target: XDictCore.StudyTarget) {
        self.init(lineage: target.lineage, entryKey: target.entryKey, occurrence: target.occurrence,
                  kind: XDictContract.StudyTargetKind(target.kind), edition: target.edition,
                  definitionHash: target.definitionHash)
    }
}

extension XDictContract.StudyNote {
    init(_ note: XDictCore.Note) {
        self.init(target: XDictContract.StudyTarget(note.target), text: note.text, at: note.at, device: note.device)
    }
}

extension XDictContract.StudyCardState {
    init(_ state: XDictCore.CardState) {
        self.init(stability: state.stability, difficulty: state.difficulty,
                  phase: XDictContract.StudyPhase(state.phase), lastReview: state.lastReview, due: state.due)
    }
}

extension XDictContract.StudyCard {
    init(_ card: XDictCore.StudyCard) {
        self.init(target: XDictContract.StudyTarget(card.target), note: XDictContract.StudyNote(card.note),
                  state: XDictContract.StudyCardState(card.state), head: card.head, noteHead: card.noteHead,
                  grades: card.grades)
    }
}

extension XDictContract.ReviewSummary {
    init(_ summary: XDictCore.ReviewSummary) {
        self.init(due: summary.due, nextDue: summary.nextDue)
    }
}

extension XDictContract.StudyOutcome {
    init(_ outcome: XDictCore.ReviewOutcome) {
        self.init(outcome: XDictContract.LedgerRecordOutcome(outcome.outcome),
                  card: XDictContract.StudyCard(outcome.card))
    }
}

extension XDictContract.ReanchorResult {
    init(_ result: XDictCore.ReanchorResult) {
        switch result {
        case .reanchored: self = .reanchored
        case .reordered: self = .reordered
        case .changed: self = .changed
        case .missing: self = .missing
        }
    }
}

extension XDictContract.ReanchorOutcome {
    init(_ outcome: XDictCore.ReanchorOutcome) {
        self.init(target: XDictContract.StudyTarget(outcome.target),
                  result: XDictContract.ReanchorResult(outcome.result))
    }
}

extension XDictContract.ReanchorReport {
    init(_ report: XDictCore.ReanchorReport) {
        self.init(outcomes: report.outcomes.map { XDictContract.ReanchorOutcome($0) })
    }
}

extension XDictContract.Recoverability {
    init(_ recoverability: XDictCore.Recoverability) {
        switch recoverability {
        case .freeBlocks: self = .freeBlocks
        }
    }
}

extension XDictCore.Removal {
    init(_ removal: XDictContract.Removal) {
        self.init(eventIds: removal.eventIds, at: removal.at, device: removal.device)
    }
}

extension XDictContract.StudyEraseReport {
    init(_ report: XDictCore.EraseReport) {
        self.init(clearedReadings: report.clearedReadings, clearedNotes: report.clearedNotes,
                  clearedGrades: report.clearedGrades, recoverable: XDictContract.Recoverability(report.recoverable))
    }
}

extension XDictContract.StudyGrade {
    init(_ grade: XDictCore.StudyGrade) {
        switch grade {
        case .again: self = .again
        case .hard: self = .hard
        case .good: self = .good
        case .easy: self = .easy
        }
    }
}

extension XDictContract.ConflictCandidate {
    init(_ candidate: XDictCore.ConflictCandidate) {
        self.init(id: candidate.id, grade: XDictContract.StudyGrade(candidate.grade), at: candidate.at,
                  device: candidate.device, after: XDictContract.StudyCardState(candidate.after))
    }
}

extension XDictContract.CardConflict {
    init(_ conflict: XDictCore.CardConflict) {
        self.init(target: XDictContract.StudyTarget(conflict.target), note: XDictContract.StudyNote(conflict.note),
                  candidates: conflict.candidates.map(XDictContract.ConflictCandidate.init))
    }
}

extension XDictContract.SyncReport {
    init(_ report: XDictCore.SyncReport) {
        self.init(exported: report.exported, peers: report.peers, added: report.added, skipped: report.skipped)
    }
}
