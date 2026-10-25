// Runs conformance.ts inside a Worker, as the Web shell runs the core, and exits with its verdict.
// Usage: node run.ts <wasm-bindgen --target web output dir> <tiny dir> <tiny expected.json> <matrix dir>
//   <matrix expected.json> <ledger cases.json> <phrase vectors.jsonl>
import { Worker } from 'node:worker_threads';

const [pkg, fixtures, expected, matrix, matrixExpected, ledger, phrase] = process.argv.slice(2);
if (!phrase) {
  console.log('usage: node run.ts <pkg dir> <tiny dir> <tiny expected.json> <matrix dir> <matrix expected.json> <ledger cases.json> <phrase vectors.jsonl>');
  process.exit(2);
}
const worker = new Worker(new URL('./conformance.ts', import.meta.url), { workerData: { pkg, fixtures, expected, matrix, matrixExpected, ledger, phrase } });
worker.on('message', (failures: string[]) => {
  if (failures.length === 0) {
    console.log('typescript (worker) conformance: all agree');
  } else {
    console.log(`typescript (worker) conformance: ${failures.length} failures`);
    for (const f of failures) console.log(`  ${f}`);
  }
  process.exitCode = failures.length === 0 ? 0 : 1;
  void worker.terminate();
});
worker.on('error', (e) => {
  console.log('the worker failed:', e);
  process.exitCode = 1;
});
