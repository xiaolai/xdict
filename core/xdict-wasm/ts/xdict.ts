// The typed wrapper a Web shell calls, in a Worker, around the wasm-bindgen output of xdict-wasm
// (`--target web`). Requests and answers are the serde shape of xdict-core's types (ADR-0007).
//
// A failure is thrown as an XDictError carrying a CoreError. A panic in the core is a trap on the Web
// (ADR-0007 decision 12): it is reported as `internal`, and this instance refuses every later call, since
// its memory may be inconsistent. Load a fresh copy of the glue module (a new URL) for a new instance.

export type CoreError = { type: string; detail?: string; [field: string]: unknown };
/** A file's identity. Bigints, because nanosecond times pass 2^53, where a number would round them. */
export type FileIdentity = { device: bigint; inode: bigint; size: bigint; mtimeNs: bigint; ctimeNs: bigint };
export type Config = {
  dataDir: string | null;
  cacheDir: string | null;
  clientProtocol: number;
  entropy: number[];
  /** Test-only (the hostile battery's lab): keep every script. Absent: false. */
  stripOffForTests?: boolean;
};
export type Versions = { protocol: number; core: string; indexFormat: number; normalization: number };
export type DictInfo = { title: string; description: string; formatVersion: string; keys: number };
export type Problem = { type: 'volumeUnreadable'; name: string; error: CoreError };
export type Imported = { edition: string; lineage: string; info: DictInfo; problems: Problem[] };
export type ImportReason = 'new' | 'changed' | 'indexMissing' | 'indexOutdated' | 'noIdentity';
export type Opened =
  | { type: 'ready'; dict: string; edition: string; info: DictInfo }
  | { type: 'needsImport'; reason: ImportReason };
export type EntryRef = { edition: string; key: string; occurrence: number };
export type MatchMode = 'reader' | 'link';
export type LookupOptions = { limit: number; offset: number; mode: MatchMode; generation: number | null };
export type How = { type: 'exact' } | { type: 'folded' } | { type: 'unmarked' } | { type: 'redirect'; chain: string[] };
export type HitProblem =
  | { type: 'danglingRedirect'; from: string; target: string }
  | { type: 'redirectLoop'; chain: string[] }
  | { type: 'redirectLimit'; chain: string[] };
export type Hit = { dict: string; entry: EntryRef; headword: string; how: How; problems: HitProblem[] };
export type Page = { hits: Hit[]; total: number; generation: number; problems: HitProblem[] };
/** `originalStyle`: the reader's "Original style" for the dictionary (ADR-0010 Q3); absent is false. */
export type View = { baseUrl: string; maxBodyBytes: number; originalStyle?: boolean };
export type Entry = { entry: EntryRef; html: string; csp: string; lossyBytes: number };
export type TextView = { baseUrl: string; maxBodyBytes: number; maxTextBytes: number; originalStyle?: boolean };
export type TextSpan = {
  start: number; len: number; role: string | null; label: string | null; section: string | null;
  /** The innermost sense containing this run (ADR-0029 d.2). */
  sense?: number | null;
};
/** One sense the entry's markup names (ADR-0029 d.2). */
export type Sense = {
  id: number; start: number; len: number; label: string | null; section: string | null;
  parent: number | null; whole: boolean;
};
export type EntryText = {
  entry: EntryRef; text: string; spans: TextSpan[]; senses: Sense[]; style: number;
  complete: boolean; omittedBytes: number; cutAt: number; spansDropped: number;
};
export type ReadingSpan = { start: number; len: number };
/** One reading as the history stores it (ADR-0023): the word, its sentence, and the edition's content hash. */
export type Reading = {
  surface: string; lemma: string; sentence: string; span: ReadingSpan | null; cut: number; quality: string;
  edition: string; entryKey: string; occurrence: number; dictionaryName: string; language: string; at: number;
  device: string;
};
export type RecordOutcome = 'recorded' | 'duplicate' | 'uncertain' | 'skippedLanguage' | 'ineligible';
export type Card = { reading: Reading; times: number; events: string[] };
export type DayLabel = 'today' | 'yesterday' | 'weekday' | 'date';
export type Day = { id: string; start: number; label: DayLabel; cards: Card[] };
export type History = { days: Day[] };
export type StudyTarget = {
  lineage: string; entryKey: string; occurrence: number; kind: 'entry'; edition: string; definitionHash: string;
};
export type Stamp = { at: number; device: string };
export type ReviewPolicy = { retention: number; maximumDays: number };
export type StudyGrade = 'again' | 'hard' | 'good' | 'easy';
export type StudyPhase = 'new' | 'learning' | 'review' | 'relearning';
export type CardState = {
  stability: number | null; difficulty: number | null; phase: StudyPhase; lastReview: number | null; due: number | null;
};
export type StudyNote = { target: StudyTarget; text: string; at: number; device: string };
export type StudyCard = {
  target: StudyTarget; note: StudyNote; state: CardState; head: string; noteHead: string; grades: number;
};
export type ReviewSummary = { due: number; nextDue: number | null };
export type ReviewOutcome = { outcome: RecordOutcome; card: StudyCard };
export type ReanchorResult = 'reanchored' | 'reordered' | 'changed' | 'missing';
export type ReanchorOutcome = { target: StudyTarget; result: ReanchorResult };
export type ReanchorReport = { outcomes: ReanchorOutcome[] };
/** A grade a device made from a revision another device also graded (ADR-0027). */
export type ConflictCandidate = { id: string; grade: StudyGrade; at: number; device: string; after: CardState };
/** A card two devices left in two states: the reader keeps one candidate. */
export type CardConflict = { target: StudyTarget; note: StudyNote; candidates: ConflictCandidate[] };
/** What one sync pass did with the reader's folder; sync itself is a native shell's (plan §2.6). */
export type SyncReport = { exported: number; peers: number; added: number; skipped: number };
export type Recoverability = 'freeBlocks';
export type EraseReport = { clearedReadings: number; clearedNotes: number; clearedGrades: number; recoverable: Recoverability };
export type Removal = { eventIds: string[]; at: number; device: string };
export type LinkOrigin = { type: 'entry'; entry: EntryRef } | { type: 'resource'; path: string };
export type BlockReason = { type: 'remote'; url: string } | { type: 'script' } | { type: 'unknownScheme'; scheme: string };
export type Link =
  | { type: 'lookup'; query: string; anchor: string | null }
  | { type: 'resource'; path: string }
  | { type: 'sound'; path: string }
  | { type: 'speak'; text: string }
  | { type: 'anchor'; name: string }
  | { type: 'blocked'; why: BlockReason };
export type FindingKind =
  | 'missingFile' | 'missingSounds' | 'missingImages' | 'missingWords' | 'codeAsText' | 'commentMarks' | 'styleAsText'
  | 'brokenRedirects' | 'doubleEncoded' | 'undecodable' | 'emptyEntries' | 'hugeEntries' | 'repeatedEntries'
  | 'oddHeadwords' | 'repaired';
export type HealthFinding = {
  kind: FindingKind;
  count: number;
  name: string | null;
  examples: { key: string; text: string }[];
};
export type Health = { version: number; entries: number; findings: HealthFinding[]; classes: { name: string; count: number }[] };
export type DisplayOption = { id: string; attribute: string; values: string[]; defaultValue: string };
export type DisplayOptions = { version: number; options: DisplayOption[]; css: string };
export type Coverage = 'ready' | 'building' | 'unavailable';
export type PhraseState = 'notAsked' | 'building' | 'unavailable' | 'none' | 'found';
export type Separation = { type: 'none' } | { type: 'marked'; words: number } | { type: 'inferred'; words: number };
export type PhraseMatch = {
  dict: string; phrase: string; location: number; length: number; separation: Separation; gap: number;
};
export type CoverageEntry = { dict: string; state: Coverage };
export type PhraseAnswer = {
  state: PhraseState; matches: PhraseMatch[]; coverage: CoverageEntry[]; total: number; capped: boolean;
};
export type PhraseBuilt = { edition: string; phrases: number; cached: boolean };
export type Resource =
  | { type: 'found'; path: string; mime: string; bytes: Uint8Array }
  | { type: 'missing'; path: string };

/** A file the shell holds: read synchronously, as a Worker can (FileReaderSync, FileSystemSyncAccessHandle). */
export interface ByteSource {
  size(): number;
  /** Exactly `len` bytes from `offset`; fewer is reported as a short read. */
  readAt(offset: number, len: number): Uint8Array;
  identity(): FileIdentity | null;
}

/** Where indexes are kept: the origin-private file system, read through `FileSystemSyncAccessHandle`. */
export interface IndexStorage {
  get(name: string): ByteSource | null;
  put(name: string, bytes: Uint8Array): void;
}

export type Location = { type: 'path'; path: string } | { type: 'source'; name: string; source: ByteSource };
export type Package = { mdx: Location; mdd: Location[]; sidecars: Location[] };

/** An identity as it crosses into the core: decimal strings, exact at any size. */
type WireIdentity = { device: string; inode: string; size: string; mtimeNs: string; ctimeNs: string };

/** A source as the core reads it: the shell's own, its identity in wire form. */
interface WireSource {
  size(): number;
  readAt(offset: number, len: number): Uint8Array;
  identity(): WireIdentity | null;
}

/** What wasm-bindgen generates for xdict-wasm with `--target web`. */
export interface Glue {
  initSync(options: { module: BufferSource | WebAssembly.Module }): unknown;
  Core: new (config: string, storage?: IndexStorage) => GlueCore;
  registerSource(source: WireSource): number;
  releaseSource(id: number): void;
  versions(): string;
  protocolVersion(): number;
  selfTestTrap(): void;
  selfTestTables(): string;
}

interface ResourceReply {
  readonly json: string;
  takeBytes(): Uint8Array;
  free(): void;
}

interface GlueCore {
  free(): void;
  import(pkg: string, progress?: { progress(done: number, total: number): boolean }): string;
  open(pkg: string): string;
  close(dict: string): string;
  lookup(query: string, dicts: string, options: string): string;
  suggest(prefix: string, dicts: string, limit: number): string;
  entry(dict: string, entry: string, view: string): string;
  entry_text(dict: string, entry: string, view: string): string;
  ledger_record(reading: string, operation: string, targetLanguages: string): string;
  ledger_history(now: number, utcOffsetSeconds: number): string;
  ledger_remove(removal: string, operation: string): string;
  ledger_restore(removal: string, operation: string): string;
  study_note(dict: string, entry: string, text: string, name: string, stamp: string, operation: string): string;
  study_notes(): string;
  study_note_at(entry: string, text: string, name: string, stamp: string, operation: string): string;
  ledger_export_json(): string;
  ledger_erase(operation: string, at: number, device: string): string;
  review_queue(now: number, limit: number): string;
  review_grade(targetKey: string, revision: string, grade: number, policy: string, stamp: string, operation: string): string;
  review_undo(targetKey: string, gradeEvent: string, stamp: string, operation: string): string;
  review_summary(now: number): string;
  review_conflicts(): string;
  review_resolve(targetKey: string, keep: string, stamp: string, operation: string): string;
  definition_hash_of(dict: string, entry: string): string;
  study_reanchor(oldEdition: string, newEdition: string, stamp: string, operationPrefix: string): string;
  link(dict: string, url: string, origin: string, view: string): string;
  resource(dict: string, path: string, view: string): ResourceReply;
  displayOptions(dict: string): string;
  joinLineage(edition: string, lineage: string): string;
  splitLineage(edition: string, newLineage: string): string;
  lineageOf(edition: string): string;
  health(dict: string, progress?: { progress(done: number, total: number): boolean }): string;
  phrases(sentence: string, termLocation: number, termLength: number, dicts: string): string;
  phrases_build(dict: string, progress?: { progress(done: number, total: number): boolean }): string;
  selfTestPanic(): string;
}

export class XDictError extends Error {
  readonly error: CoreError;
  constructor(error: CoreError) {
    super(`${error.type}: ${error.detail ?? ''}`);
    this.error = error;
  }
}

/** One loaded copy of the core's module. */
export class XDict {
  private readonly glue: Glue;
  private poisoned = false;

  private constructor(glue: Glue) {
    this.glue = glue;
  }

  /**
   * Loads the module into `glue`, once: loading the same glue again gives the same wrapper, since the glue keeps
   * its one instance, and a trap that poisoned it poisons every use. A fresh instance needs a fresh glue.
   */
  static load(glue: Glue, module: BufferSource | WebAssembly.Module): XDict {
    const loaded = XDict.loaded.get(glue);
    if (loaded) return loaded;
    glue.initSync({ module });
    const x = new XDict(glue);
    XDict.loaded.set(glue, x);
    return x;
  }

  /** The wrapper of each glue loaded. */
  private static readonly loaded = new WeakMap<Glue, XDict>();

  versions(): Versions {
    return this.guard(() => JSON.parse(this.glue.versions()));
  }

  protocolVersion(): number {
    return this.guard(() => this.glue.protocolVersion());
  }

  /** A core. `config.entropy` is filled from `crypto.getRandomValues` when empty; `storage` keeps its indexes. */
  core(config: Omit<Config, 'entropy'> & { entropy?: number[] }, storage?: IndexStorage): XDictCore {
    const entropy = config.entropy?.length ? config.entropy : Array.from(crypto.getRandomValues(new Uint8Array(16)));
    const inner = this.guard(() => new this.glue.Core(JSON.stringify({ ...config, entropy }), storage));
    return new XDictCore(this, inner);
  }

  /** Panics outside the core's guard: shows the trap path. */
  selfTestTrap(): void {
    this.guard(() => this.glue.selfTestTrap());
  }

  /**
   * @internal Registers a package's sources for one call: `registered` collects their numbers, which the caller
   * releases when the call returns. The core keeps what it still needs (an opened dictionary's files) until the
   * dictionary closes, so nothing is retained by the wrapper.
   */
  location(location: Location, registered: Map<ByteSource, number>): unknown {
    if (location.type === 'path') return location;
    let id = registered.get(location.source);
    if (id === undefined) {
      const source = location.source;
      const wire: WireSource = {
        size: () => source.size(),
        readAt: (offset, len) => source.readAt(offset, len),
        identity: () => {
          const i = source.identity();
          return i === null ? null : { device: `${i.device}`, inode: `${i.inode}`, size: `${i.size}`, mtimeNs: `${i.mtimeNs}`, ctimeNs: `${i.ctimeNs}` };
        },
      };
      id = this.glue.registerSource(wire);
      registered.set(source, id);
    }
    return { type: 'source', name: location.name, sourceId: id };
  }

  /** @internal */
  release(registered: Map<ByteSource, number>): void {
    for (const id of registered.values()) this.glue.releaseSource(id);
  }

  /** @internal Runs a call; a thrown string is a CoreError, a trap poisons this instance. */
  guard<T>(call: () => T): T {
    if (this.poisoned) throw new XDictError({ type: 'internal', detail: 'this instance trapped earlier; load a new one' });
    try {
      return call();
    } catch (thrown) {
      if (typeof thrown === 'string') throw new XDictError(JSON.parse(thrown));
      if (thrown instanceof WebAssembly.RuntimeError) {
        this.poisoned = true;
        throw new XDictError({ type: 'internal', detail: String(thrown) });
      }
      throw thrown;
    }
  }
}

export class XDictCore {
  private readonly x: XDict;
  private readonly inner: GlueCore;

  constructor(x: XDict, inner: GlueCore) {
    this.x = x;
    this.inner = inner;
  }

  import(pkg: Package, progress?: (done: number, total: number) => boolean): Imported {
    const watcher = progress ? { progress } : undefined;
    return this.withPackage(pkg, (wire) => this.inner.import(wire, watcher));
  }

  /** Opens a package imported before, passing every file of it again: the core checks each one's identity. */
  open(pkg: Package): Opened {
    return this.withPackage(pkg, (wire) => this.inner.open(wire));
  }

  /** Releases this core now rather than when JavaScript collects it, with the index storage it holds. */
  free(): void {
    this.inner.free();
  }

  /** A call given the package as JSON, its sources registered for the call alone. */
  private withPackage<T>(pkg: Package, call: (wire: string) => string): T {
    const x = this.x;
    const registered = new Map<ByteSource, number>();
    try {
      return this.call(() => {
        const at = (l: Location) => x.location(l, registered);
        return call(JSON.stringify({ mdx: at(pkg.mdx), mdd: pkg.mdd.map(at), sidecars: pkg.sidecars.map(at) }));
      });
    } finally {
      x.release(registered);
    }
  }

  close(dict: string): void {
    this.call(() => this.inner.close(dict));
  }

  lookup(query: string, dicts: string[], options: LookupOptions): Page {
    return this.call(() => this.inner.lookup(query, JSON.stringify(dicts), JSON.stringify(options)));
  }

  suggest(prefix: string, dicts: string[], limit: number): string[] {
    return this.call(() => this.inner.suggest(prefix, JSON.stringify(dicts), limit));
  }

  entry(dict: string, entry: EntryRef, view: View): Entry {
    return this.call(() => this.inner.entry(dict, JSON.stringify(entry), JSON.stringify(view)));
  }

  entryText(dict: string, entry: EntryRef, view: TextView): EntryText {
    return this.call(() => this.inner.entry_text(dict, JSON.stringify(entry), JSON.stringify(view)));
  }

  /** Records a reading in the local history: the language filter runs before anything is written. */
  ledgerRecord(reading: Reading, operation: string, targetLanguages: string[]): RecordOutcome {
    return this.call(() => this.inner.ledger_record(JSON.stringify(reading), operation, JSON.stringify(targetLanguages)));
  }

  /** Hides the readings a history card is made of (ADR-0024); `ledgerRestore` shows them again. */
  ledgerRemove(removal: Removal, operation: string): RecordOutcome {
    return this.call(() => this.inner.ledger_remove(JSON.stringify(removal), operation));
  }

  ledgerRestore(removal: Removal, operation: string): RecordOutcome {
    return this.call(() => this.inner.ledger_restore(JSON.stringify(removal), operation));
  }

  /** The days the drawer shows, in the reader's own zone: `utcOffsetSeconds` east of UTC while `now` is the clock. */
  ledgerHistory(now: number, utcOffsetSeconds: number): History {
    return this.call(() => this.inner.ledger_history(now, utcOffsetSeconds));
  }

  /** Saves the reader's note on an entry (plan §5.1) and enrols it for review. */
  studyNote(dict: string, entry: EntryRef, text: string, name: string, stamp: Stamp, operation: string): StudyNote {
    return this.call(() => this.inner.study_note(dict, JSON.stringify(entry), text, name, JSON.stringify(stamp), operation));
  }

  studyNotes(): StudyNote[] {
    return this.call(() => this.inner.study_notes());
  }

  /** A note named by the history card's facts, resolved to the open dictionary of its edition. */
  studyNoteAt(entry: EntryRef, text: string, name: string, stamp: Stamp, operation: string): StudyNote {
    return this.call(() => this.inner.study_note_at(JSON.stringify(entry), text, name, JSON.stringify(stamp), operation));
  }

  /** The log's events as the reader's export: one JSON document, no dictionary content. */
  exportLedgerJson(): string {
    return this.call(() => this.inner.ledger_export_json());
  }

  /** Erase is a rewrite; the receipt says what may remain recoverable. */
  eraseLedger(operation: string, at: number, device: string): EraseReport {
    return this.call(() => this.inner.ledger_erase(operation, at, device));
  }

  /** The review queue: due cards, soonest first, a new card at once. */
  reviewQueue(now: number, limit: number): StudyCard[] {
    return this.call(() => this.inner.review_queue(now, limit));
  }

  /** One grade under the reader's configuration. */
  reviewGrade(targetKey: string, revision: string, grade: StudyGrade, policy: ReviewPolicy, stamp: Stamp,
              operation: string): ReviewOutcome {
    const number = { again: 1, hard: 2, good: 3, easy: 4 }[grade];
    return this.call(() => this.inner.review_grade(targetKey, revision, number, JSON.stringify(policy),
                                                   JSON.stringify(stamp), operation));
  }

  reviewUndo(targetKey: string, gradeEvent: string, stamp: Stamp, operation: string): ReviewOutcome {
    return this.call(() => this.inner.review_undo(targetKey, gradeEvent, JSON.stringify(stamp), operation));
  }

  reviewSummary(now: number): ReviewSummary {
    return this.call(() => this.inner.review_summary(now));
  }

  /** The hash a note records for an entry's definition; never the definition itself. */
  definitionHashOf(dict: string, entry: EntryRef): string {
    return this.call(() => this.inner.definition_hash_of(dict, JSON.stringify(entry)));
  }

  /** Re-anchors notes of one edition to another under the same lineage (plan §5.1). */
  studyReanchor(oldEdition: string, newEdition: string, stamp: Stamp, operationPrefix: string): ReanchorReport {
    return this.call(() => this.inner.study_reanchor(oldEdition, newEdition, JSON.stringify(stamp), operationPrefix));
  }

  /** **The cards two devices left conflicted** (ADR-0027): the reader chooses a branch. */
  reviewConflicts(): CardConflict[] {
    return this.call(() => this.inner.review_conflicts());
  }

  /** Keeps one branch of a conflict; the others are voided with what descended from them. */
  reviewResolve(target: string, keep: string, stamp: Stamp, operation: string): ReviewOutcome {
    return this.call(() => this.inner.review_resolve(target, keep, JSON.stringify(stamp), operation));
  }

  link(dict: string, url: string, origin: LinkOrigin, view: View): Link {
    return this.call(() => this.inner.link(dict, url, JSON.stringify(origin), JSON.stringify(view)));
  }

  resource(dict: string, path: string, view: View): Resource {
    return this.x.guard(() => {
      const reply = this.inner.resource(dict, path, JSON.stringify(view));
      try {
        const head = JSON.parse(reply.json);
        return head.type === 'found' ? { ...head, bytes: reply.takeBytes() } : head;
      } finally {
        reply.free();
      }
    });
  }

  /** The edition's health report (WI-12): checked once and kept with its indexes; `progress` as for an import. */
  health(dict: string, progress?: (done: number, total: number) => boolean): Health {
    const watcher = progress ? { progress } : undefined;
    return this.call(() => this.inner.health(dict, watcher));
  }

  /** **The phrases covering the term in a captured sentence** (`dev-docs/plan-phrase-recognition.md` WI-5). */
  phrases(sentence: string, termLocation: number, termLength: number, dicts: string[]): PhraseAnswer {
    return this.call(() => this.inner.phrases(sentence, termLocation, termLength, JSON.stringify(dicts)));
  }

  /** Builds one dictionary's phrase inventory in the background; `progress` as for an import. */
  phrasesBuild(dict: string, progress?: (done: number, total: number) => boolean): PhraseBuilt {
    const watcher = progress ? { progress } : undefined;
    return this.call(() => this.inner.phrases_build(dict, watcher));
  }

  /** The display options that apply to an open dictionary, with its defaults, and their CSS (ADR-0013). */
  displayOptions(dict: string): DisplayOptions {
    return this.call(() => this.inner.displayOptions(dict));
  }

  /** Joins an edition to a lineage the registry holds, as the reader asked; answers the lineage it now has. */
  joinLineage(edition: string, lineage: string): string {
    return this.call(() => this.inner.joinLineage(edition, lineage));
  }

  /** Moves an edition to `newLineage`: one the shell minted, or the one it had before a join, which undoes it. */
  splitLineage(edition: string, newLineage: string): string {
    return this.call(() => this.inner.splitLineage(edition, newLineage));
  }

  /** The edition's lineage now; `null` for an edition never imported. */
  lineageOf(edition: string): string | null {
    return this.call(() => this.inner.lineageOf(edition));
  }

  selfTestPanic(): void {
    this.call(() => this.inner.selfTestPanic());
  }

  private call<T>(call: () => string): T {
    return this.x.guard(() => JSON.parse(call()));
  }
}
