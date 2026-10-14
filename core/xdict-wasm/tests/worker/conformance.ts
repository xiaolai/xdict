// The conformance scenario (conformance/README.md) through xdict-wasm and its TypeScript wrapper, inside a
// Worker. Posts the list of mismatches to the parent.
import { parentPort, workerData } from 'node:worker_threads';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { XDict, XDictError, type ByteSource, type FileIdentity, type Location, type Package, type View } from '../../ts/xdict.ts';

const { pkg, fixtures, expected, matrix, matrixExpected } =
  workerData as { pkg: string; fixtures: string; expected: string; matrix: string; matrixExpected: string };
const x = JSON.parse(readFileSync(expected, 'utf8'));
const failures: string[] = [];

function subset(e: unknown, a: unknown, at: string): string | null {
  if (e !== null && typeof e === 'object' && !Array.isArray(e)) {
    if (a === null || typeof a !== 'object' || Array.isArray(a)) return `${at}: expected an object, found ${JSON.stringify(a)}`;
    for (const [k, v] of Object.entries(e)) {
      if (k === 'comment') continue;
      if (!(k in (a as object))) return `${at}.${k}: missing in ${JSON.stringify(a)}`;
      const f = subset(v, (a as Record<string, unknown>)[k], `${at}.${k}`);
      if (f) return f;
    }
    return null;
  }
  if (Array.isArray(e)) {
    if (!Array.isArray(a) || a.length !== e.length) return `${at}: expected ${JSON.stringify(e)}, found ${JSON.stringify(a)}`;
    for (let i = 0; i < e.length; i++) {
      const f = subset(e[i], a[i], `${at}[${i}]`);
      if (f) return f;
    }
    return null;
  }
  return e === a ? null : `${at}: expected ${JSON.stringify(e)}, found ${JSON.stringify(a)}`;
}
const check = (name: string, e: unknown, a: unknown) => {
  const f = subset(e, a, name);
  if (f) failures.push(f);
};
/** A call's outcome as the suites compare it; a resource's bytes as text. */
function outcome(call: () => unknown): unknown {
  try {
    const v = call() as Record<string, unknown> | undefined;
    if (v && v.type === 'found' && v.bytes instanceof Uint8Array) return { ...v, text: new TextDecoder().decode(v.bytes) };
    return v === undefined ? 'ok' : v;
  } catch (e) {
    if (e instanceof XDictError) return { error: e.error };
    throw e;
  }
}

class Bytes implements ByteSource {
  readonly bytes: Uint8Array;
  readonly ident: FileIdentity | null;
  readonly short: boolean;
  constructor(bytes: Uint8Array, ident: FileIdentity | null, short = false) {
    this.bytes = bytes;
    this.ident = ident;
    this.short = short;
  }
  size() { return this.bytes.length; }
  readAt(offset: number, len: number) {
    return this.bytes.slice(offset, Math.min(offset + len, this.bytes.length) - (this.short ? 1 : 0));
  }
  identity() { return this.ident; }
}

// The Web has no paths: the package is read through sources, each with the identity its file has here.
const file = (name: string, dir = fixtures): Location => {
  const s = statSync(join(dir, name), { bigint: true });
  const ident = { device: s.dev, inode: s.ino, size: s.size, mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs };
  return { type: 'source', name, source: new Bytes(readFileSync(join(dir, name)), ident) };
};
/** An identity written in expected.json (numbers, as JSON has no bigint), as the wrapper takes it. */
const big = (i: { device: number; inode: number; size: number; mtimeNs: number; ctimeNs: number }): FileIdentity => ({
  device: BigInt(i.device), inode: BigInt(i.inode), size: BigInt(i.size), mtimeNs: BigInt(i.mtimeNs), ctimeNs: BigInt(i.ctimeNs),
});
const glueUrl = pathToFileURL(join(pkg, 'xdict_wasm.js')).href;
const wasm = readFileSync(join(pkg, 'xdict_wasm_bg.wasm'));
const xd = XDict.load(await import(glueUrl), wasm);
const view = (max?: number): View => ({ baseUrl: x.view.baseUrl, maxBodyBytes: max ?? x.view.maxBodyBytes });
const config = (clientProtocol: number) => ({ dataDir: null, cacheDir: null, clientProtocol });

check('versions', x.versions, xd.versions());
check('newWrongProtocol', x.newWrongProtocol.error, (outcome(() => { xd.core(config(x.newWrongProtocol.client)); return { made: true }; }) as { error?: unknown }).error);

// Indexes kept by the shell, as the origin-private file system would keep them, and read back piece by piece.
const kept = new Map<string, Uint8Array>();
const calls = { get: 0, put: 0, reads: 0 };
const storage = {
  get(name: string) {
    calls.get++;
    const bytes = kept.get(name);
    if (!bytes) return null;
    return { size: () => bytes.length, readAt: (o: number, l: number) => { calls.reads++; return bytes.slice(o, o + l); }, identity: () => null };
  },
  put(name: string, bytes: Uint8Array) {
    calls.put++;
    kept.set(name, bytes.slice());
  },
};
const core = xd.core(config(xd.protocolVersion()), storage);
const tiny = { mdx: file('tiny.mdx'), mdd: [file('tiny.mdd')], sidecars: [file('tiny.css')] };
check('openBeforeImport', x.openBeforeImport, outcome(() => core.open(tiny)));
const imported = core.import(tiny);
check('import', x.import, imported);
const opened = core.open(tiny);
check('open', x.open, opened);
if (opened.type !== 'ready') throw new Error('not open');
const dict = opened.dict;

// The generation each lookup returned, for the cases that continue it (`{ "of": n }`).
const generations: (number | null)[] = [];
x.lookups.forEach((c: any, i: number) => {
  const mode: 'reader' | 'link' = c.mode === 'link' ? 'link' : 'reader';
  const generation = c.generation ? generations[c.generation.of] ?? null : null;
  if (c.generation && generation === null) throw new Error(`lookups[${i}] continues a page that gave no generation`);
  const options = { limit: c.limit, offset: c.offset, mode, generation };
  const got = outcome(() => core.lookup(c.query, [dict], options)) as any;
  generations.push(typeof got?.generation === 'number' ? got.generation : null);
  check(`lookups[${i}]`, c.error ? { error: c.error } : c.page, got);
});
x.suggestions.forEach((c: any, i: number) => check(`suggestions[${i}]`, c.error ? { error: c.error } : c.keys, outcome(() => core.suggest(c.prefix, [dict], c.limit))));
x.entries.forEach((c: any, i: number) => {
  const ref = { edition: c.edition ?? imported.edition, key: c.entry.key, occurrence: c.entry.occurrence };
  const got = outcome(() => core.entry(dict, ref, view(c.maxBodyBytes))) as any;
  if (c.cspContains && typeof got?.csp === 'string') check(`entries[${i}].csp contains ${c.cspContains}`, true, got.csp.includes(c.cspContains));
  check(`entries[${i}]`, c.error ? { error: c.error } : c.result, got);
});
const origin = { type: 'entry' as const, entry: { edition: imported.edition, key: 'run', occurrence: 0 } };
x.links.forEach((c: any, i: number) => check(`links[${i}]`, c.link, outcome(() => core.link(dict, c.url, origin, view()))));
x.resources.forEach((c: any, i: number) => check(`resources[${i}]`, c.resource, outcome(() => core.resource(dict, c.path, view()))));

const b = x.byteSource;
const bytes = readFileSync(join(fixtures, 'tiny.mdx'));
const copy: Location = { type: 'source', name: b.name, source: new Bytes(bytes, big(b.identity)) };
const sidecar: Location = { type: 'source', name: b.sidecar.name, source: new Bytes(new TextEncoder().encode(b.sidecar.text), null) };
const copyPkg = { mdx: copy, mdd: [], sidecars: [sidecar] };
check('byteSource.import', b.import, outcome(() => core.import(copyPkg)));
const second = core.open(copyPkg);
check('byteSource.open', b.open, second);
if (second.type !== 'ready') throw new Error('not open');
check('byteSource.resourceFromPath', b.resourceFromPath, outcome(() => core.resource(dict, 'tiny.css', view())));
check('byteSource.resourceFromSource', b.resourceFromSource, outcome(() => core.resource(second.dict, 'tiny.css', view())));
const short: Location = { type: 'source', name: 'short.mdx', source: new Bytes(bytes, null, true) };
check('byteSource.shortRead', b.shortRead, outcome(() => core.import({ mdx: short, mdd: [], sidecars: [] })));

const errs = x.errors;
for (const name of ['unsupported', 'malformed']) {
  check(`errors.${name}`, { error: errs[name].error }, outcome(() => core.import({ mdx: file(errs[name].file), mdd: [], sidecars: [] })));
}
check('errors.cancelled', { error: errs.cancelled.error }, outcome(() => core.import({ mdx: file('tiny.mdx'), mdd: [], sidecars: [] }, () => false)));
// A sidecar whose identity changes after it is opened, as a moved or rewritten file's would.
const moving = new Bytes(new TextEncoder().encode(b.sidecar.text), big(b.identity));
const watchedPkg = { mdx: copy, mdd: [], sidecars: [{ type: 'source' as const, name: 'tiny.css', source: moving }] };
core.import(watchedPkg);
const watched = core.open(watchedPkg);
if (watched.type !== 'ready') throw new Error('not open');
moving.ident!.inode += 1n;
check('errors.sourceChanged', { error: errs.sourceChanged.error }, outcome(() => core.resource(watched.dict, 'tiny.css', view())));

// The reader's joins and splits; each lineage answered is compared as a label, since ids are minted at random.
const n = x.lineages;
const rebuilt = core.import({ mdx: file(n.file), mdd: [], sidecars: [] });
const label = (v: unknown) => (v === imported.lineage ? 'tiny' : v === rebuilt.lineage ? 'rebuilt' : v);
check('lineages.import', n.import, { ...rebuilt, lineage: label(rebuilt.lineage) });
const lineageOf = (e: string) => label(outcome(() => core.lineageOf(e)));
const joined = (e: string, l: string) => label(outcome(() => core.joinLineage(e, l)));
const splitTo = (e: string, l: string) => label(outcome(() => core.splitLineage(e, l)));
check('lineages.before', n.before, lineageOf(rebuilt.edition));
check('lineages.join', n.join, joined(rebuilt.edition, imported.lineage));
check('lineages.afterJoin', n.afterJoin, lineageOf(rebuilt.edition));
check('lineages.joinAgain', n.joinAgain, joined(rebuilt.edition, imported.lineage));
check('lineages.split', n.split, splitTo(rebuilt.edition, rebuilt.lineage));
check('lineages.afterSplit', n.afterSplit, lineageOf(rebuilt.edition));
check('lineages.splitToNew', n.splitToNew, splitTo(rebuilt.edition, n.newLineage));
check('lineages.splitToNewAgain', n.splitToNewAgain, splitTo(rebuilt.edition, n.newLineage));
check('lineages.joinUnknownEdition', n.joinUnknownEdition, joined(n.unknownEdition, imported.lineage));
check('lineages.lineageOfUnknownEdition', n.lineageOfUnknownEdition, lineageOf(n.unknownEdition));
check('lineages.joinUnknownLineage', n.joinUnknownLineage, joined(rebuilt.edition, n.unknownLineage));
check('lineages.splitNotALineage', n.splitNotALineage, splitTo(rebuilt.edition, n.notALineage));
check('lineages.splitIntoAnother', n.splitIntoAnother, splitTo(imported.edition, rebuilt.lineage));

const l = x.lifecycle;
const page = { limit: 10, offset: 0, mode: 'reader' as const, generation: null };
core.close(second.dict);
check('lifecycle.afterClose', l.afterClose, outcome(() => core.lookup('run', [second.dict], page)));
check('lifecycle.closeTwice', l.closeTwice, outcome(() => core.close(second.dict)));
const other = xd.core(config(xd.protocolVersion()));
check('lifecycle.foreignHandle', l.foreignHandle, outcome(() => other.lookup('run', [dict], page)));
// Two imports stored three indexes (the MDX, its volume, the copy's MDX under the same edition); opening read them
// in pieces, not whole.
check('web.indexStorage', true, calls.put >= 2 && calls.get >= 2 && calls.reads > 2);
// The core's guard does not catch a panic on the Web: it traps, and the wrapper reports `internal`.
check('lifecycle.panic', l.panic, outcome(() => core.selfTestPanic()));
// The trapped instance refuses further calls; a freshly loaded one works (ADR-0007 decision 12).
check('web.afterTrap', { error: { type: 'internal' } }, outcome(() => core.lookup('run', [dict], page)));
// Loading the same glue again reuses its trapped instance, so it is refused too (audit-fix round 2, row 36).
const again = XDict.load(await import(glueUrl), wasm);
check('web.reloadAfterTrap', { error: { type: 'internal' } }, outcome(() => again.versions()));
const fresh = XDict.load(await import(`${glueUrl}?instance=2`), wasm);
check('web.freshInstance', x.versions, fresh.versions());

// Identities are carried exactly: two times a nanosecond apart, past 2^53, are two identities.
{
  const tinyMdx = readFileSync(join(fixtures, 'tiny.mdx'));
  const at = (t: bigint): Package => {
    const ident = { device: 9n, inode: 9n, size: BigInt(tinyMdx.length), mtimeNs: t, ctimeNs: t };
    return { mdx: { type: 'source', name: 'tiny.mdx', source: new Bytes(tinyMdx, ident) }, mdd: [], sidecars: [] };
  };
  const exact = fresh.core(config(fresh.protocolVersion()));
  const t = 1_760_000_000_000_000_001n;
  exact.import(at(t));
  check('web.exactIdentity.same', 'ready', exact.open(at(t)).type);
  check('web.exactIdentity.oneNanosecondLater', { type: 'needsImport', reason: 'changed' }, exact.open(at(t + 1n)));
}

// The matrix, on the fresh instance: every variant imported, opened and asked the same questions.
const template = readFileSync(matrixExpected, 'utf8');
const variants = JSON.parse(readFileSync(join(matrix, 'variants.json'), 'utf8'));
check('matrix.variants', 32, variants.length);
const matrixView: View = { baseUrl: 'xdict://d/', maxBodyBytes: 1 << 20 };
for (const v of variants) {
  const m = JSON.parse(template.replaceAll('$word', v.word).replaceAll('$gloss', v.gloss).replaceAll('$version', v.version));
  const c = fresh.core(config(fresh.protocolVersion()));
  const p = { mdx: file(`${v.name}.mdx`, matrix), mdd: [], sidecars: [] };
  const imp = outcome(() => c.import(p)) as any;
  check(`${v.name}.import`, m.import, imp);
  if (typeof imp?.edition !== 'string') continue;
  const opn = outcome(() => c.open(p)) as any;
  check(`${v.name}.open`, m.open, opn);
  if (opn?.type !== 'ready') continue;
  m.lookups.forEach((q: any, i: number) => {
    const options = { limit: q.limit, offset: q.offset, mode: 'reader' as const, generation: null };
    check(`${v.name}.lookups[${i}]`, q.page, outcome(() => c.lookup(q.query, [opn.dict], options)));
  });
  m.entries.forEach((e: any, i: number) => {
    const ref = { edition: imp.edition, key: e.entry.key, occurrence: e.entry.occurrence };
    check(`${v.name}.entries[${i}]`, e.result, outcome(() => c.entry(opn.dict, ref, matrixView)));
  });
}

// The binding's own contract, on a third instance (audit-fix 2026-10-14): a throwing callback is a typed error
// and leaves the instance working; callbacks may re-enter the binding; nothing a call registers outlives its use;
// identities are carried exactly.
const g3 = await import(`${glueUrl}?instance=3`);
const third = XDict.load(g3, wasm);
const tables = () => JSON.parse(g3.selfTestTables()) as { sources: number; storage: number; progress: number; replies: number };
const attempt = (name: string, call: () => void) => {
  try {
    call();
  } catch (e) {
    failures.push(`${name}: threw ${String(e)}`);
  }
};
const tinyBytes = readFileSync(join(fixtures, 'tiny.mdx'));
const at = (mtimeNs: bigint): FileIdentity => ({ device: 9n, inode: 9n, size: BigInt(tinyBytes.length), mtimeNs, ctimeNs: mtimeNs });
const src = (ident: FileIdentity | null, overrides: Partial<ByteSource> = {}): ByteSource =>
  Object.assign(new Bytes(tinyBytes, ident), overrides);
const only = (source: ByteSource): Package => ({ mdx: { type: 'source', name: 'tiny.mdx', source }, mdd: [], sidecars: [] });
const c3 = third.core(config(third.protocolVersion()));
const baseline = tables();

attempt('web.throwingSize', () => {
  const thrower = src(at(1n), { size: () => { throw new Error('size failed'); } });
  check('web.throwingSize', { error: { type: 'io' } }, outcome(() => c3.import(only(thrower))));
});
attempt('web.throwingIdentity', () => {
  const thrower = src(null, { identity: () => { throw new Error('identity failed'); } });
  check('web.throwingIdentity', { error: { type: 'io' } }, outcome(() => c3.import(only(thrower))));
});
attempt('web.malformedIdentity', () => {
  // Not an identity a file can have: a failure to report, not a file without one (audit-fix round 2, row 37).
  const bad = { ...at(1n), inode: 'not a number' } as unknown as FileIdentity;
  check('web.malformedIdentity', { error: { type: 'io' } }, outcome(() => c3.import(only(src(bad)))));
});
attempt('web.throwingProgress', () => {
  const got = outcome(() => c3.import(only(src(at(2n))), () => { throw new Error('progress failed'); }));
  check('web.throwingProgress', { error: { type: 'cancelled' } }, got);
});
attempt('web.afterThrows', () => check('web.afterThrows', 'string', typeof c3.import(only(src(at(3n)))).edition));

attempt('web.reentrantRead', () => {
  let inner: unknown = null;
  const reader = src(at(4n), {
    readAt(offset: number, len: number) {
      if (inner === null) inner = outcome(() => c3.open(only(src(at(3n)))));
      return tinyBytes.subarray(offset, Math.min(offset + len, tinyBytes.length));
    },
  });
  check('web.reentrantRead', 'string', typeof (outcome(() => c3.import(only(reader))) as any)?.edition);
  check('web.reentrantRead.inner', 'ready', (inner as any)?.type);
});
attempt('web.reentrantProgress', () => {
  let nested: unknown = null;
  let after = 0;
  // With a volume, which reports before the MDX on the Web, so the outer import reports again after the nested one.
  const withVolume = { ...only(src(at(6n))), mdd: [file('tiny.mdd')] };
  const outer = outcome(() =>
    c3.import(withVolume, () => {
      if (nested === null) nested = outcome(() => c3.import(only(src(at(7n))), () => true));
      else after++;
      return true;
    }),
  );
  check('web.reentrantProgress', 'string', typeof (outer as any)?.edition);
  check('web.reentrantProgress.nested', 'string', typeof (nested as any)?.edition);
  check('web.reentrantProgress.outerStillWatched', true, after > 0);
});

// A callback that throws fails the call it threw in, whichever call that is: `size()` and `identity()` cannot
// return an error to the core, so the binding checks after every call. (After the re-entrant checks: importing
// another tiny.mdx moves the name on, and those open the one imported before them.)
const cssBytes = readFileSync(join(fixtures, 'tiny.css'));
const cssAt = (n: bigint): FileIdentity => ({ device: 9n, inode: 90n + n, size: BigInt(cssBytes.length), mtimeNs: n, ctimeNs: n });
/** A package of tiny.mdx and a tiny.css sidecar whose `size()` or `identity()` throws once `broken` is set. */
const withSidecar = (n: bigint, breaks: 'size' | 'identity') => {
  const state = { broken: false };
  const sidecar = Object.assign(new Bytes(cssBytes, cssAt(n)), {
    size: () => { if (state.broken && breaks === 'size') throw new Error('size failed'); return cssBytes.length; },
    identity: () => { if (state.broken && breaks === 'identity') throw new Error('identity failed'); return cssAt(n); },
  });
  const pkg: Package = { ...only(src(at(n))), sidecars: [{ type: 'source', name: 'tiny.css', source: sidecar }] };
  return { pkg, state };
};
attempt('web.throwingSidecarSize', () => {
  const { pkg, state } = withSidecar(11n, 'size');
  c3.import(pkg);
  const o = c3.open(pkg);
  if (o.type !== 'ready') throw new Error(`not open: ${JSON.stringify(o)}`);
  state.broken = true;
  check('web.throwingSidecarSize', { error: { type: 'io' } }, outcome(() => c3.resource(o.dict, 'tiny.css', view())));
  c3.close(o.dict);
});
attempt('web.throwingIdentityOnOpen', () => {
  const { pkg, state } = withSidecar(12n, 'identity');
  c3.import(pkg);
  const before = tables().sources;
  state.broken = true;
  check('web.throwingIdentityOnOpen', { error: { type: 'io' } }, outcome(() => c3.open(pkg)));
  check('web.throwingIdentityOnOpen.nothingKept', before, tables().sources);
});

attempt('web.throwingIdentityOnLookup', () => {
  // The core sees no identity, which alone would read as a changed file; the binding reports the throw instead.
  const state = { broken: false };
  const mdx = src(at(14n), { identity: () => { if (state.broken) throw new Error('identity failed'); return at(14n); } });
  c3.import(only(mdx));
  const o = c3.open(only(mdx));
  if (o.type !== 'ready') throw new Error(`not open: ${JSON.stringify(o)}`);
  state.broken = true;
  const options = { limit: 10, offset: 0, mode: 'reader' as const, generation: null };
  check('web.throwingIdentityOnLookup', { error: { type: 'io' } }, outcome(() => c3.lookup('run', [o.dict], options)));
  c3.close(o.dict);
});

// A source that throws during an import fails it before anything is registered: the record a valid import
// left stays, its volume readable (audit-fix round 2, row 35).
attempt('web.throwingImportKeepsRecord', () => {
  const mddBytes = readFileSync(join(fixtures, 'tiny.mdd'));
  const mddAt: FileIdentity = { device: 9n, inode: 130n, size: BigInt(mddBytes.length), mtimeNs: 13n, ctimeNs: 13n };
  const state = { broken: false };
  const volume = Object.assign(new Bytes(mddBytes, mddAt), {
    identity: () => { if (state.broken) throw new Error('identity failed'); return mddAt; },
  });
  const pkg: Package = { ...only(src(at(13n))), mdd: [{ type: 'source', name: 'tiny.mdd', source: volume }] };
  c3.import(pkg);
  state.broken = true;
  check('web.throwingImportKeepsRecord.fails', { error: { type: 'io' } }, outcome(() => c3.import(pkg)));
  state.broken = false;
  const o = outcome(() => c3.open(pkg)) as any;
  check('web.throwingImportKeepsRecord.open', 'ready', o?.type);
  if (o?.type !== 'ready') return;
  // The volume's record is the valid import's: its resources are served, not skipped as unreadable.
  check('web.throwingImportKeepsRecord', { type: 'found' }, outcome(() => c3.resource(o.dict, 'run.mp3', view())));
  c3.close(o.dict);
});

// A source whose identity moves during an import is a changed file (ADR-0007 decision 13): the binding passes the
// core what the source answers now, not what it answered first.
attempt('web.identityChangedDuringImport', () => {
  let asked = 0;
  const mdx = src(at(20n), { identity: () => at(asked++ === 0 ? 20n : 21n) });
  check('web.identityChangedDuringImport', { error: { type: 'sourceChanged' } }, outcome(() => c3.import(only(mdx))));
});
// A volume that throws only when asked again, late in the import, still fails it before anything is registered.
attempt('web.lateThrowKeepsRecord', () => {
  const mddBytes = readFileSync(join(fixtures, 'tiny.mdd'));
  const mddAt: FileIdentity = { device: 9n, inode: 150n, size: BigInt(mddBytes.length), mtimeNs: 15n, ctimeNs: 15n };
  const state = { broken: false, asked: 0 };
  const volume = Object.assign(new Bytes(mddBytes, mddAt), {
    identity: () => { if (state.broken && state.asked++ > 0) throw new Error('identity failed'); return mddAt; },
  });
  const pkg: Package = { ...only(src(at(15n))), mdd: [{ type: 'source', name: 'tiny.mdd', source: volume }] };
  c3.import(pkg);
  state.broken = true;
  check('web.lateThrowKeepsRecord.fails', { error: { type: 'io' } }, outcome(() => c3.import(pkg)));
  state.broken = false;
  const o = outcome(() => c3.open(pkg)) as any;
  check('web.lateThrowKeepsRecord.open', 'ready', o?.type);
  if (o?.type !== 'ready') return;
  check('web.lateThrowKeepsRecord', { type: 'found' }, outcome(() => c3.resource(o.dict, 'run.mp3', view())));
  c3.close(o.dict);
});
// A source that throws inside the import's last progress callback, here through a lookup the callback makes into
// the core, still stops the import before it registers: the veto is checked after the callback as well as before.
attempt('web.throwInLastProgressKeepsRecord', () => {
  const mddBytes = readFileSync(join(fixtures, 'tiny.mdd'));
  const mddAt: FileIdentity = { device: 9n, inode: 160n, size: BigInt(mddBytes.length), mtimeNs: 16n, ctimeNs: 16n };
  const mdx = src(at(16n));
  const withVolume: Package = { ...only(mdx), mdd: [{ type: 'source', name: 'tiny.mdd', source: new Bytes(mddBytes, mddAt) }] };
  c3.import(withVolume);
  // Another dictionary, under its own name, whose identity throws while `side.broken` is set.
  const side = { broken: false };
  const sideSource = src(at(17n), { identity: () => { if (side.broken) throw new Error('identity failed'); return at(17n); } });
  const sidePkg: Package = { mdx: { type: 'source', name: 'side.mdx', source: sideSource }, mdd: [], sidecars: [] };
  c3.import(sidePkg);
  const opened = outcome(() => c3.open(sidePkg)) as any;
  check('web.throwInLastProgressKeepsRecord.side', 'ready', opened?.type);
  if (opened?.type !== 'ready') return;
  // How many reports an import of these bytes makes, counted on a package of its own name.
  let reports = 0;
  c3.import({ mdx: { type: 'source', name: 'count.mdx', source: src(at(16n)) }, mdd: [], sidecars: [] }, () => {
    reports++;
    return true;
  });
  // Without the volume: registering this would replace the record the valid import left.
  let call = 0;
  const failed = outcome(() => c3.import(only(mdx), () => {
    if (++call === reports) {
      side.broken = true;
      outcome(() => c3.lookup('run', [opened.dict], page));
      side.broken = false;
    }
    return true;
  }));
  check('web.throwInLastProgressKeepsRecord.lastCall', reports, call);
  check('web.throwInLastProgressKeepsRecord.fails', { error: { type: 'io' } }, failed);
  const o = outcome(() => c3.open(withVolume)) as any;
  check('web.throwInLastProgressKeepsRecord.open', 'ready', o?.type);
  if (o?.type === 'ready') {
    check('web.throwInLastProgressKeepsRecord', { type: 'found' }, outcome(() => c3.resource(o.dict, 'run.mp3', view())));
    c3.close(o.dict);
  }
  c3.close(opened.dict);
});

// Counted from here: dictionaries the checks above left open hold their sources, as they should.
attempt('web.sourcesReleased', () => {
  const before = tables().sources;
  c3.import(only(src(at(8n))));
  check('web.sourcesReleasedAfterImport', before, tables().sources);
  const opened = c3.open(only(src(at(8n))));
  if (opened.type !== 'ready') throw new Error(`not open: ${JSON.stringify(opened)}`);
  check('web.sourcesHeldWhileOpen', before + 1, tables().sources);
  c3.close(opened.dict);
  check('web.sourcesReleased', before, tables().sources);
});
attempt('web.storageReleased', () => {
  const kept3 = { get: () => null, put: () => {} };
  const made = third.core(config(third.protocolVersion()), kept3);
  check('web.storageHeldWhileAlive', baseline.storage + 1, tables().storage);
  made.free();
  outcome(() => third.core(config(999), kept3));
  check('web.storageReleased', baseline.storage, tables().storage);
});
attempt('web.repliesFreed', () => {
  const p = { mdx: file('tiny.mdx'), mdd: [file('tiny.mdd')], sidecars: [file('tiny.css')] };
  c3.import(p);
  const o = c3.open(p);
  if (o.type !== 'ready') throw new Error('not open');
  for (let i = 0; i < 3; i++) c3.resource(o.dict, 'tiny.css', view());
  check('web.repliesFreed', 0, tables().replies);
  check('web.progressReleased', 0, tables().progress);
  c3.close(o.dict);
});

parentPort!.postMessage(failures);
