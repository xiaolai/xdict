# conformance

Language-neutral fixtures that prove every platform agrees. Owned by the core; every platform runs them
through its own binding (ADR-0003 decision 5). No dictionary content from anywhere else ever enters this
folder.

## Fixtures

Each folder of `fixtures/` is one dictionary, as **descriptions, not files**:

- `dictionary.json`: the MDX's entries, its MDD volumes' entries and its sidecar files, in our own words.
  `cargo run -p xdict-conformance --bin conformance-fixtures -- <dir>` writes them with the core's test writer
  (`xdict-mdx-writer`) into `<dir>/<fixture>/`. The writer is deterministic, so an edition hash can be expected.
- `expected.json`: what every binding must answer. Compared **by subset**: every field written there must be
  present and equal; fields left out (handles, lineage ids, the version string) are not compared; lists must
  have equal lengths; a resource's bytes are compared as UTF-8 text in `text`.

## The scenario (`tiny/`)

Every suite runs these steps in this order, against a fresh `Core`, and compares each result with the key of
`expected.json` named in brackets:

1. `versions()` [`versions`]; `Core::new` with client protocol 999 fails [`newWrongProtocol`].
2. `open` of the package before any import [`openBeforeImport`]. The package: `tiny.mdx`, volumes
   `[tiny.mdd]`, sidecars `[tiny.css]`.
3. `import` of the package [`import`]; `open` of it [`open`].
4. Each of [`lookups`] (in `reader` mode unless the case says `"mode": "link"`), [`suggestions`], [`entries`]
   (edition defaults to the imported one; `cspContains` is a
   substring of the returned policy), [`links`] (origin: the entry `run`/0), [`resources`], in the view
   [`view`].
5. [`byteSource`]: the same MDX bytes through a `ByteSource` the suite implements, under the name and identity
   given, with its own sidecar (also a source): `import`, `open`, then `tiny.css` from the first handle and from
   this one (`open` takes the copy's package). Then an import through a source that returns one byte too few.
6. [`lifecycle`]: close the second handle, then look up with it; close it again; look up with the first handle
   on a second `Core`; `self_test_panic`.

The Web has no paths, so its suite reads every file of step 3 through sources too, each with its file's identity.

## Suites

| Binding | Command | Runs on |
|---|---|---|
| Rust (the Linux shell's) | `cd core && cargo test -p xdict-conformance` | everywhere |
| Swift (UniFFI) | `core/xdict-ffi/test-swift.sh` | macOS |
| Kotlin on the JVM (UniFFI) | `core/xdict-ffi/test-kotlin.sh` (needs `kotlinc`, a JDK, `JNA_JAR`) | macOS, Linux |
| TypeScript in a Worker (`wasm-bindgen`) | `core/xdict-wasm/test-worker.sh` (needs `wasm-bindgen` 0.2.129, `tsc`, Node 24) | everywhere |

Every one takes `XDICT_CONFORMANCE_EXPECTED=<file>` in place of `expected.json`, so a deliberately wrong
expectation can be shown to fail (2026-10-13: the first lookup's total changed from 3 to 4 failed all four,
each naming `lookups[0].total`).
