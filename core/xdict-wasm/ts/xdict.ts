// The typed wrapper a Web shell calls, in a Worker, around the wasm-bindgen output of xdict-wasm
// (`--target web`). Requests and answers are the serde shape of xdict-core's types (ADR-0007).
//
// A failure is thrown as an XDictError carrying a CoreError. A panic in the core is a trap on the Web
// (ADR-0007 decision 12): it is reported as `internal`, and this instance refuses every later call, since
// its memory may be inconsistent. Load a fresh copy of the glue module (a new URL) for a new instance.

export type CoreError = { type: string; detail?: string; [field: string]: unknown };
export type FileIdentity = { device: number; inode: number; size: number; mtimeNs: number; ctimeNs: number };
export type Config = { dataDir: string | null; cacheDir: string | null; clientProtocol: number; entropy: number[] };
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
  | { type: 'redirectLoop'; chain: string[] };
export type Hit = { dict: string; entry: EntryRef; headword: string; how: How; problems: HitProblem[] };
export type Page = { hits: Hit[]; total: number; generation: number; problems: HitProblem[] };
export type View = { baseUrl: string; skin: string | null; maxBodyBytes: number };
export type Entry = { entry: EntryRef; html: string; csp: string; lossyBytes: number };
export type LinkOrigin = { type: 'entry'; entry: EntryRef } | { type: 'resource'; path: string };
export type BlockReason = { type: 'remote'; url: string } | { type: 'script' } | { type: 'unknownScheme'; scheme: string };
export type Link =
  | { type: 'lookup'; query: string; anchor: string | null }
  | { type: 'resource'; path: string }
  | { type: 'sound'; path: string }
  | { type: 'speak'; text: string }
  | { type: 'anchor'; name: string }
  | { type: 'blocked'; why: BlockReason };
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

export type Location = { type: 'path'; path: string } | { type: 'source'; name: string; source: ByteSource };
export type Package = { mdx: Location; mdd: Location[]; sidecars: Location[] };

/** What wasm-bindgen generates for xdict-wasm with `--target web`. */
export interface Glue {
  initSync(options: { module: BufferSource | WebAssembly.Module }): unknown;
  Core: new (config: string) => GlueCore;
  registerSource(source: ByteSource): number;
  releaseSource(id: number): void;
  versions(): string;
  protocolVersion(): number;
  selfTestTrap(): void;
}

interface GlueCore {
  import(pkg: string, progress?: { progress(done: number, total: number): boolean }): string;
  open(location: string): string;
  close(dict: string): string;
  lookup(query: string, dicts: string, options: string): string;
  suggest(prefix: string, dicts: string, limit: number): string;
  entry(dict: string, entry: string, view: string): string;
  link(dict: string, url: string, origin: string, view: string): string;
  resource(dict: string, path: string, view: string): { json: string; bytes: Uint8Array };
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
  private readonly sources = new Map<ByteSource, number>();
  private poisoned = false;

  private constructor(glue: Glue) {
    this.glue = glue;
  }

  static load(glue: Glue, module: BufferSource | WebAssembly.Module): XDict {
    glue.initSync({ module });
    return new XDict(glue);
  }

  versions(): Versions {
    return this.guard(() => JSON.parse(this.glue.versions()));
  }

  protocolVersion(): number {
    return this.guard(() => this.glue.protocolVersion());
  }

  /** A core. `config.entropy` is filled from `crypto.getRandomValues` when empty. */
  core(config: Omit<Config, 'entropy'> & { entropy?: number[] }): XDictCore {
    const entropy = config.entropy?.length ? config.entropy : Array.from(crypto.getRandomValues(new Uint8Array(16)));
    const inner = this.guard(() => new this.glue.Core(JSON.stringify({ ...config, entropy })));
    return new XDictCore(this, inner);
  }

  /** Panics outside the core's guard: shows the trap path. */
  selfTestTrap(): void {
    this.guard(() => this.glue.selfTestTrap());
  }

  /** @internal */
  location(location: Location): unknown {
    if (location.type === 'path') return location;
    let id = this.sources.get(location.source);
    if (id === undefined) {
      id = this.glue.registerSource(location.source);
      this.sources.set(location.source, id);
    }
    return { type: 'source', name: location.name, sourceId: id };
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
    const wire = { mdx: this.x.location(pkg.mdx), mdd: pkg.mdd.map((l) => this.x.location(l)), sidecars: pkg.sidecars.map((l) => this.x.location(l)) };
    const watcher = progress ? { progress } : undefined;
    return this.call(() => this.inner.import(JSON.stringify(wire), watcher));
  }

  open(location: Location): Opened {
    return this.call(() => this.inner.open(JSON.stringify(this.x.location(location))));
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

  link(dict: string, url: string, origin: LinkOrigin, view: View): Link {
    return this.call(() => this.inner.link(dict, url, JSON.stringify(origin), JSON.stringify(view)));
  }

  resource(dict: string, path: string, view: View): Resource {
    return this.x.guard(() => {
      const reply = this.inner.resource(dict, path, JSON.stringify(view));
      const head = JSON.parse(reply.json);
      return head.type === 'found' ? { ...head, bytes: reply.bytes } : head;
    });
  }

  selfTestPanic(): void {
    this.call(() => this.inner.selfTestPanic());
  }

  private call<T>(call: () => string): T {
    return this.x.guard(() => JSON.parse(call()));
  }
}
