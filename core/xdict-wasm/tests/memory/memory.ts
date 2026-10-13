// ADR-0007 refutation 24 through the Web binding: one step on the dictionary memory-fixture writes, and what it
// costs: the process's peak resident memory and the WebAssembly memory, which never shrinks once grown. The step
// runs in a Worker, as the Web shell runs the core; the main thread only starts it and prints its line.
// Usage: node memory.ts <wasm-bindgen --target web output dir> <fixture dir> <import|entry|refused|resource>
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { XDict, XDictError, type Location } from '../../ts/xdict.ts';

if (isMainThread) {
  const args = process.argv.slice(2);
  if (args.length !== 3) {
    console.log('usage: node memory.ts <pkg dir> <fixture dir> <import|entry|refused|resource>');
    process.exit(2);
  }
  const worker = new Worker(new URL(import.meta.url), { workerData: args });
  let reported = false;
  worker.on('message', (line: string) => {
    reported = true;
    console.log(line);
  });
  worker.on('error', (e) => {
    console.log('the worker failed:', e);
    process.exitCode = 1;
  });
  worker.on('exit', (code) => {
    if (code !== 0 || !reported) process.exitCode = 1;
  });
} else {
  const [pkg, dir, step] = workerData as string[];
  const mib = (bytes: number) => (bytes / 1048576).toFixed(0);
  const file = (name: string): Location => {
    const bytes = readFileSync(join(dir, name));
    const s = statSync(join(dir, name), { bigint: true });
    const ident = { device: s.dev, inode: s.ino, size: s.size, mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs };
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
  else if (step === 'refused') {
    let refused = false;
    try {
      core.entry(opened.dict, big, view(64 << 20));
    } catch (e) {
      if (!(e instanceof XDictError) || e.error.type !== 'tooLarge') throw e;
      refused = true;
    }
    if (!refused) throw new Error('not refused');
  } else if (step === 'resource') {
    const r = core.resource(opened.dict, 'big.css', view(128 << 20));
    if (r.type !== 'found') throw new Error('missing');
    size = r.bytes.length;
  } else if (step !== 'import') throw new Error(`no step ${step}`);
  const after = { rss: process.resourceUsage().maxRSS * 1024, wasm: memory.buffer.byteLength };
  parentPort!.postMessage(`worker ${step}: peak ${mib(before.rss)} MiB before, ${mib(after.rss)} MiB after; wasm memory ${mib(before.wasm)} → ${mib(after.wasm)} MiB; result ${mib(size)} MiB`);
}
