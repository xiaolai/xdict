// ADR-0007 refutation 24 through the Web binding: one step on the dictionary memory-fixture writes, and what it
// costs: the process's peak resident memory and the WebAssembly memory, which never shrinks once grown.
// Usage: node memory.ts <wasm-bindgen --target web output dir> <fixture dir> <import|entry|refused|resource>
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { XDict, XDictError, type Location } from '../../ts/xdict.ts';

const [pkg, dir, step] = process.argv.slice(2);
if (!step) {
  console.log('usage: node memory.ts <pkg dir> <fixture dir> <import|entry|refused|resource>');
  process.exit(2);
}
const mib = (bytes: number) => (bytes / 1048576).toFixed(0);
const file = (name: string): Location => {
  const bytes = readFileSync(join(dir, name));
  const s = statSync(join(dir, name), { bigint: true });
  const ident = { device: Number(s.dev), inode: Number(s.ino), size: Number(s.size), mtimeNs: Number(s.mtimeNs), ctimeNs: Number(s.ctimeNs) };
  const source = { size: () => bytes.length, readAt: (o: number, l: number) => bytes.subarray(o, o + l), identity: () => ident };
  return { type: 'source', name, source };
};
const glue = await import(pathToFileURL(join(pkg, 'xdict_wasm.js')).href);
const wasm = readFileSync(join(pkg, 'xdict_wasm_bg.wasm'));
const xd = XDict.load(glue, wasm);
const memory = (glue.initSync({ module: wasm }) as { memory: WebAssembly.Memory }).memory;
// Indexes kept as the origin-private file system would keep them.
const kept = new Map<string, Uint8Array>();
const storage = {
  get(name: string) {
    const b = kept.get(name);
    return b ? { size: () => b.length, readAt: (o: number, l: number) => b.slice(o, o + l), identity: () => null } : null;
  },
  put(name: string, bytes: Uint8Array) {
    kept.set(name, bytes.slice());
  },
};
const core = xd.core({ dataDir: null, cacheDir: null, clientProtocol: xd.protocolVersion() }, storage);
const pack = { mdx: file('big.mdx'), mdd: [file('big.mdd')], sidecars: [] };
const imported = core.import(pack);
const opened = core.open(pack);
if (opened.type !== 'ready') throw new Error('not open');
const big = { edition: imported.edition, key: 'big', occurrence: 0 };
const view = (max: number) => ({ baseUrl: 'xdict://d/', skin: null, maxBodyBytes: max });
const before = { rss: process.resourceUsage().maxRSS * 1024, wasm: memory.buffer.byteLength };
let size = 0;
if (step === 'entry') size = core.entry(opened.dict, big, view(128 << 20)).html.length;
if (step === 'refused') {
  try {
    core.entry(opened.dict, big, view(64 << 20));
    console.log('not refused');
    process.exit(1);
  } catch (e) {
    if (!(e instanceof XDictError) || e.error.type !== 'tooLarge') throw e;
  }
}
if (step === 'resource') {
  const r = core.resource(opened.dict, 'big.css', view(128 << 20));
  if (r.type !== 'found') throw new Error('missing');
  size = r.bytes.length;
}
const after = { rss: process.resourceUsage().maxRSS * 1024, wasm: memory.buffer.byteLength };
console.log(`worker ${step}: peak ${mib(before.rss)} MiB before, ${mib(after.rss)} MiB after; wasm memory ${mib(before.wasm)} → ${mib(after.wasm)} MiB; result ${mib(size)} MiB`);
