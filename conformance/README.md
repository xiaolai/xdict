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
4. Each of [`lookups`] (in `reader` mode unless the case says `"mode": "link"`; a `generation` of `{ "of": n }` is
   the one `lookups[n]` returned, since a generation is a digest of the lookup and differs from core to core),
   [`suggestions`], [`entries`]
   (edition defaults to the imported one; `cspContains` is a
   substring of the returned policy), [`links`] (origin: the entry `run`/0), [`resources`], in the view
   [`view`].
5. [`byteSource`]: the same MDX bytes through a `ByteSource` the suite implements, under the name and identity
   given, with its own sidecar (also a source): `import`, `open`, then `tiny.css` from the first handle and from
   this one (`open` takes the copy's package). Then an import through a source that returns one byte too few.
6. [`errors`], each against the same `Core`: `import` of the faulty `file`s, `tiny-v4.mdx` [`unsupported`] and
   `tiny-badheader.mdx` [`malformed`] and `tiny-absent.mdx`, which is not written [`notFound`; not on the Web,
   which has no paths] (each the package's MDX alone); `import` of `tiny.mdx` alone with a progress
   that answers `false` [`cancelled`]; then the byte source's MDX with a sidecar `tiny.css` that is a source
   with the byte source's `identity`: `import`, `open`, the sidecar's inode raised by one, then `resource` of
   `tiny.css` [`sourceChanged`].
7. [`lineages`] (ADR-0002 decision 3, as amended 2026-10-14): `import` of `tiny-rebuilt.mdx` alone, the same entries
   under another title, so another edition with a lineage of its own [`import`]. Each lineage a call answers is
   compared as a label: `tiny` for the lineage step 3's import answered, `rebuilt` for the one this import answered,
   the id itself otherwise. Then, on the rebuilt edition: `lineage_of` [`before`]; `join_lineage` to tiny's lineage
   [`join`], `lineage_of` [`afterJoin`], the join again [`joinAgain`]; `split_lineage` back to its own lineage
   [`split`], `lineage_of` [`afterSplit`]; `split_lineage` to `newLineage`, a shell's UUID in capitals
   [`splitToNew`], and again [`splitToNewAgain`]. Refused or empty: `join_lineage` of `unknownEdition` to tiny's
   lineage [`joinUnknownEdition`], `lineage_of` it [`lineageOfUnknownEdition`]; `join_lineage` of the rebuilt
   edition to `unknownLineage` [`joinUnknownLineage`]; its `split_lineage` to `notALineage` [`splitNotALineage`];
   `split_lineage` of tiny's edition to the rebuilt one's lineage, another dictionary's [`splitIntoAnother`].
8. [`lifecycle`]: close the second handle, then look up with it; close it again; look up with the first handle
   on a second `Core`; `self_test_panic`.

The Web has no paths, so its suite reads every file of steps 3 and 7 through sources too, each with its file's identity.

## The matrix (`matrix/`)

One small dictionary written in every version, compression and encoding the reader reads: 1.2 and 2.0 ×
none/zlib/LZO × UTF-8/UTF-16/GBK/Big5/Latin-1, and 3.0 × none/zlib × UTF-8 (MdxBuilder writes 3.0 only in
UTF-8, and never LZO): 32 variants. Each variant has its own non-ASCII word and gloss, one its encoding can
hold, so every encoding is exercised by text it alone stores differently.

`dictionary.json` lists the variants; the generator writes `<variant>.mdx` for each and `variants.json` (each
variant's `name`, `word`, `gloss`, `version`). For each variant, every suite replaces `$word`, `$gloss` and
`$version` in the text of `matrix/expected.json`, then, against a fresh `Core`: `import` of the package
(`<variant>.mdx`, no volumes, no sidecars) [`import`], `open` [`open`], each of [`lookups`] in `reader` mode,
each of [`entries`] (edition the imported one) in the view `xdict://d/`, 1 MiB.

## The shells' own fixtures (`hostile/`, `twin-a/`, `twin-b/`)

Written by the same writer, run by a shell's end-to-end suite rather than by every binding, so they hold no
`expected.json`:

- `hostile/`: the hostile-input battery (ADR-0007 decision 14). One egress attempt per entry, each payload at byte zero
  and again behind each context the core's rewriter cannot see into, every target on the measuring Mac's loopback or
  under `.invalid`. Generated, never edited: `apps/apple/Tools/hostile/battery.py` writes `dictionary.json` and
  `cases.json` (the runs and each layer's probes), and `--check` fails when either is stale. The macOS run is
  `apps/apple/Tools/e2e.sh`'s `hostile` and `reader` stages.
- `twin-a/`, `twin-b/`: two dictionaries with the same key and resource paths and different markers, for "one web view
  per open dictionary" (ADR-0009, refutation item 13).

## Suites

| Binding | Command | Runs on |
|---|---|---|
| Rust (the Linux shell's) | `cd core && cargo test -p xdict-conformance` | everywhere |
| Swift (UniFFI) | `core/xdict-ffi/test-swift.sh` | macOS |
| Kotlin on the JVM (UniFFI) | `core/xdict-ffi/test-kotlin.sh` (needs `kotlinc`, a JDK, `JNA_JAR`) | macOS, Linux |
| TypeScript in a Worker (`wasm-bindgen`) | `core/xdict-wasm/test-worker.sh` (needs `wasm-bindgen` 0.2.129, `tsc`, Node 24) | everywhere |

CI runs all four, with the core's gate, on every push (`.github/workflows/conformance.yml`): Swift on macOS,
the others on Linux. The three binding scripts share `core/binding-env.sh`, and find their build output where Cargo
put it (`CARGO_TARGET_DIR` or a configured `build.target-dir` included).

Every one takes `XDICT_CONFORMANCE_EXPECTED=<file>` in place of `tiny/expected.json` and
`XDICT_CONFORMANCE_MATRIX_EXPECTED=<file>` in place of `matrix/expected.json` (a relative path is read from where
the script is started), so a deliberately wrong expectation can be shown to fail. 2026-10-13: the first lookup's total changed from 3 to 4 failed all four, each
naming `lookups[0].total`. 2026-10-14: the matrix's `formatVersion` and both entries' `lossyBytes` altered failed
all four, 96 failures each (32 variants × 3). 2026-10-14: the 14 `lineages` expectations altered (the labels swapped, the
split's lineage in capitals, the null a label, each refusal's `what` or `type` changed) failed all four, 14 failures
each, each named.
