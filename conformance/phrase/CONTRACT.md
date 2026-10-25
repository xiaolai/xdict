# The phrase contract

`vectors.jsonl` is the behaviour every binding must give for phrase recognition
(`dev-docs/plan-phrase-recognition.md` WI-6): the same sentences, the same dictionary, the same answers, through
Swift, Kotlin, the Web's Worker and the core itself. It is a **value** suite: the templates, sentences and expected
answers are our own text — no dictionary content enters this folder.

The fixture is `../fixtures/phrase/dictionary.json`, written by `conformance-fixtures` like every other. Its keys are
the templates the vectors need (contiguous, slotted, trailing-slot, inflected, irregular, inferred), and 65 keys
sharing one word so the answer's cap is crossed.

## The scenario

Against a fresh `Core`, the suite:

1. imports and opens `phrase/phrase.mdx` (`open` answers a handle, called `dict` below);
2. reads `vectors.jsonl`, top to bottom, one JSON object per line, and runs each case in the order written.

A case's `kind` is one of:

| `kind` | Call | Expected |
|---|---|---|
| `vector` | `phrases(sentence, location, length, [dict])` | the answer, or `error` |
| `build` | `phrases_build(dict, nil)` | `phrases` counted, and `cached` |

`build` appears twice: the first answers `cached: false`, the second, after the store exists, `cached: true`. The
`before-build` vector comes before both, so every binding sees the `building` state rather than a store.

## The answer

The answer's JSON is the core's own serde shape (camel-case fields, a `type` tag), which every binding reproduces in
its comparison:

```json
{"state":"found",
 "matches":[{"dict":"phrase","phrase":"purple passage","location":23,"length":14,
             "separation":{"type":"none"},"gap":0}],
 "coverage":[{"dict":"phrase","state":"ready"}],
 "capped":false}
```

- **`state`** is one of `notAsked`, `building`, `unavailable`, `none`, `found`. `none` only when every dictionary
  asked answered and none matched; `building` while one store is not built; `unavailable` when none could answer and
  none is still building.
- **`coverage`** is one entry per dictionary asked, in the order asked: `ready`, `building` or `unavailable`.
- **`location` and `length`** count **UTF-16 units** of the sentence, as the capture contract does; an emoji before the
  phrase moves them by two, and the `utf16` and `combining` vectors hold that.
- **`separation`** is `{"type":"none"}`, `{"type":"marked","words":n}` (the publisher wrote a slot) or
  `{"type":"inferred","words":n}` (the matcher broke a bare two-word phrasal verb). `gap` is the same number, written
  plainly.
- **`capped`** says the match list stopped at the answer's cap; a vector may write `matchCount` instead of listing
  every match, and the suite checks the count and removes the key before comparing.

## The dictionary's label

A handle is the shell's, not the core's: it differs from core to core and from binding to binding. The suite replaces
every `dict` in `matches` and `coverage` with the label `phrase`, the one dictionary this suite asks, before comparing.

## Failure

`error` is a `CoreError` as JSON, compared by subset (the vectors name `type` and, where it matters, `limit`): a
sentence over 1,000 UTF-16 units is `{"type":"tooLarge","limit":"sentence"}`; a term range outside the sentence is
`{"type":"malformed"}`. A state is never an error: an empty sentence is `notAsked`.

`unavailable` needs a store that **could not be built**, which a binding cannot make its fixture do without a fault
the contract does not inject. The core's own tests hold that state and its partial-search rule
(`a_failed_build_says_unavailable_and_a_later_build_clears_it`, `a_partial_search_names_each_dictionary_and_is_never_none`
in `core/xdict-core/tests/phrases_api.rs`): `none` only when every dictionary asked answered.

## The suites

| Binding | Runner | Where the vectors run |
|---|---|---|
| Rust, the Linux shell's | `core/xdict-conformance/tests/phrase.rs` | `cd core && cargo test -p xdict-conformance --test phrase` |
| Swift | `core/xdict-ffi/tests/swift/main.swift` | `core/xdict-ffi/test-swift.sh` |
| Kotlin on the JVM | `core/xdict-ffi/tests/kotlin/Conformance.kt` | `core/xdict-ffi/test-kotlin.sh` |
| TypeScript in a Worker | `core/xdict-wasm/tests/worker/conformance.ts` | `core/xdict-wasm/test-worker.sh` |

Each takes `XDICT_CONFORMANCE_PHRASE=<file>` in place of `vectors.jsonl`, so a deliberately wrong expectation can be
shown to fail: 2026-10-25, `contiguous`'s match location changed from 23 to 22 and the cap's `matchCount` changed from
64 to 63, in one file, failed all four suites with both named —
`contiguous.matches[0].location: expected 22, found 23` and `cap.matchCount: expected 63, found 64`.
