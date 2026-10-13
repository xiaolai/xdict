// The conformance scenario (conformance/README.md) through xdict-wasm and its TypeScript wrapper, inside a
// Worker. Posts the list of mismatches to the parent.
import { parentPort, workerData } from 'node:worker_threads';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { XDict, XDictError, type ByteSource, type FileIdentity, type Location, type View } from '../../ts/xdict.ts';

const { pkg, fixtures, expected } = workerData as { pkg: string; fixtures: string; expected: string };
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
const file = (name: string): Location => {
  const s = statSync(join(fixtures, name), { bigint: true });
  const ident = { device: Number(s.dev), inode: Number(s.ino), size: Number(s.size), mtimeNs: Number(s.mtimeNs), ctimeNs: Number(s.ctimeNs) };
  return { type: 'source', name, source: new Bytes(readFileSync(join(fixtures, name)), ident) };
};
const glueUrl = pathToFileURL(join(pkg, 'xdict_wasm.js')).href;
const wasm = readFileSync(join(pkg, 'xdict_wasm_bg.wasm'));
const xd = XDict.load(await import(glueUrl), wasm);
const view = (max?: number): View => ({ baseUrl: x.view.baseUrl, skin: null, maxBodyBytes: max ?? x.view.maxBodyBytes });
const config = (clientProtocol: number) => ({ dataDir: null, cacheDir: null, clientProtocol });

check('versions', x.versions, xd.versions());
check('newWrongProtocol', x.newWrongProtocol.error, (outcome(() => { xd.core(config(x.newWrongProtocol.client)); return { made: true }; }) as { error?: unknown }).error);

const core = xd.core(config(xd.protocolVersion()));
const mdx = file('tiny.mdx');
check('openBeforeImport', x.openBeforeImport, outcome(() => core.open(mdx)));
const imported = core.import({ mdx, mdd: [file('tiny.mdd')], sidecars: [file('tiny.css')] });
check('import', x.import, imported);
const opened = core.open(mdx);
check('open', x.open, opened);
if (opened.type !== 'ready') throw new Error('not open');
const dict = opened.dict;

x.lookups.forEach((c: any, i: number) => {
  const options = { limit: c.limit, offset: c.offset, mode: 'reader' as const, generation: c.generation ?? null };
  check(`lookups[${i}]`, c.error ? { error: c.error } : c.page, outcome(() => core.lookup(c.query, [dict], options)));
});
x.suggestions.forEach((c: any, i: number) => check(`suggestions[${i}]`, c.keys, outcome(() => core.suggest(c.prefix, [dict], c.limit))));
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
const copy: Location = { type: 'source', name: b.name, source: new Bytes(bytes, b.identity) };
const sidecar: Location = { type: 'source', name: b.sidecar.name, source: new Bytes(new TextEncoder().encode(b.sidecar.text), null) };
check('byteSource.import', b.import, outcome(() => core.import({ mdx: copy, mdd: [], sidecars: [sidecar] })));
const second = core.open(copy);
check('byteSource.open', b.open, second);
if (second.type !== 'ready') throw new Error('not open');
check('byteSource.resourceFromPath', b.resourceFromPath, outcome(() => core.resource(dict, 'tiny.css', view())));
check('byteSource.resourceFromSource', b.resourceFromSource, outcome(() => core.resource(second.dict, 'tiny.css', view())));
const short: Location = { type: 'source', name: 'short.mdx', source: new Bytes(bytes, null, true) };
check('byteSource.shortRead', b.shortRead, outcome(() => core.import({ mdx: short, mdd: [], sidecars: [] })));

const l = x.lifecycle;
const page = { limit: 10, offset: 0, mode: 'reader' as const, generation: null };
core.close(second.dict);
check('lifecycle.afterClose', l.afterClose, outcome(() => core.lookup('run', [second.dict], page)));
check('lifecycle.closeTwice', l.closeTwice, outcome(() => core.close(second.dict)));
const other = xd.core(config(xd.protocolVersion()));
check('lifecycle.foreignHandle', l.foreignHandle, outcome(() => other.lookup('run', [dict], page)));
// The core's guard does not catch a panic on the Web: it traps, and the wrapper reports `internal`.
check('lifecycle.panic', l.panic, outcome(() => core.selfTestPanic()));
// The trapped instance refuses further calls; a freshly loaded one works (ADR-0007 decision 12).
check('web.afterTrap', { error: { type: 'internal' } }, outcome(() => core.lookup('run', [dict], page)));
const fresh = XDict.load(await import(`${glueUrl}?instance=2`), wasm);
check('web.freshInstance', x.versions, fresh.versions());

parentPort!.postMessage(failures);
