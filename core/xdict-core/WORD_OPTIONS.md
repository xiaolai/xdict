# Word exploration

`xdict_core::words` is an additive Rust API for exploring the public headwords of the reader's dictionaries.
It does not change ordinary lookup. UI, XPC/FFI and other transport integration are deferred.

```rust,ignore
use std::{io::BufReader, sync::Arc};
use xdict_core::{Core, NoProgress};
use xdict_core::words::{WordLexicon, WordMode, WordQuery};

// `dicts` are handles returned by this Core's open().
let catalog = core.word_explorer(dicts, &NoProgress)?;
let lexicon = WordLexicon::from_jsonl(BufReader::new(file))?;
let explorer = catalog.with_lexicon(Some(Arc::new(lexicon)))?;
let page = explorer.search(WordQuery {
    text: "possible".into(),
    mode: WordMode::Derivations,
    limit: 50,
    offset: 0,
})?;
```

The catalog is an immutable snapshot, cheap to clone and share across threads. Construction and search read keys
and linguistic metadata, not entry bodies. Each hit retains the exact headword spelling and all dictionary sources,
including duplicate-key occurrence numbers. Open it through the existing Core entry API. Source handles can become
stale after construction: rebuild when dictionaries change; entry opening still enforces the existing handle and
edition checks. A snapshot never redirects an old reference to a replacement dictionary.

| Mode | Meaning | External data |
|---|---|---|
| `EndsWith` | Canonically normalized, lowercase suffix comparison; accents retained | None |
| `Fuzzy { max_distance }` | Optimal string alignment distance, including adjacent transposition | None |
| `Rhyme` | Pronunciation match from the last stressed vowel to the end | Stressed ARPAbet |
| `Inflections` | Members of a lemma's paradigm, queried from either lemma or form | Sourced forms and grammatical tags |
| `Derivations` | Explicit modern family edges, including POS conversion and affixation | Sourced family relations |
| `Roots { max_depth }` | Shared historical ancestor, with paths from both words | Language-qualified etymology graph |

Optimal string alignment is restricted Damerau–Levenshtein distance: a substring is not edited twice. Thus
`recieve` → `receive` costs one transposition, while `ca` → `abc` costs three. Lowercase matching is not full Unicode
case folding; it does not equate `ß` with `ss`. Display spelling is preserved.
Fuzzy scans prioritize lengths closest to the query after finding exact hits. A cut answer still does not guarantee
that every better edit-distance match was reached.

Results always belong to the supplied catalog. The lexicon can explain a query absent from the dictionaries, but
cannot manufacture an entry. `WordPage.status` distinguishes answered queries, missing kinds of metadata (`NoData`),
and a word unknown to the available metadata (`QueryUnknown`). A work, graph-visit or evidence limit is explicit in `exhausted`;
`total` is present only for an exhaustive answer. Pages and query lengths have public bounds. An exhausted search
is a partial answer, not proof that no other matches exist.
`Roots.max_depth` defines the requested ancestry radius; a complete answer is complete within that radius.
`total` counts matching headwords, not every possible explanation. Each hit keeps at most 64 distinct reasons;
that evidence list is bounded even when the headword result is exhaustive.

The default work budget is 50 million estimated work units and 200,000 graph visits. Work includes the bytes of
evidence copied, stored, hashed or compared, so large metadata cannot hide behind a one-record charge. Rich result evidence has a
16 MiB accounting budget across the answer; crossing it returns `TotalBytes` exhaustion with no total. These
budgets describe retained evidence and work, not the entire process's peak RAM. A pack giving one normalized word
more than 256 pronunciation variants is refused when the explorer is built. Catalog input is capped at ten million
entries/sources and 1 GiB of text. The lexical loader defaults to four million records and 512 MiB of JSONL input.

`WordReason` preserves the evidence: edit distance, matching pronunciation variants, lemma and form roles, family
steps, or historical nodes and paths. Multiple possible lemmas and etymologies remain distinct evidence. A shared
prefix or suffix is not a historical lexical root. Antonyms and synonyms alone do not form a derivational family.
Explicitly different POS in a family path require a conversion step; an unspecified POS remains ambiguous. For
`FamilyKind::Other` and `Conversion`, `base` and `derived` can name unoriented endpoints: OEWN does not identify
a productive or historical direction for either kind. `toward_base` describes traversal between stored endpoints.
An ancestry path may be empty when that word is itself the shared ancestor; direct ancestors and descendants
remain valid historical-root results.
Historical providers can also leave homographs unresolved; separate etymologies are retained when supplied, and
source paths remain candidates with their provider's coverage limits.

Pronunciations retain source, dialect and any source-provided POS. CMUdict variants have no POS and are never
assigned one by ordering. IPA is retained as source transcription; the core does not pretend to have segmented
it into ARPAbet phonemes. Primary/secondary stress marks remain available. `StemStress` is classified only where a
pack supplies an explicit vowel alignment; otherwise it is `Unknown`. Adding `im-` can move a vowel's index without
moving the stem's stress. Unaligned pronunciation contrasts are useful evidence, not a certified stress-shift label.
None of the current provider adapters supplies stem alignments, so their generated families return
`StemStress::Unknown`. The optional pack field supports alignments supplied by a source that actually provides them.

The morphology builder uses a conservative spelling model. Exclusions can be legitimate unmodelled allomorphy,
such as `possible → possibility` or `conclude → conclusion`; they are not all source defects. Other providers may
still supply those pairs. The outside-Git build report counts these exclusions and retains bounded samples.

See [tools/WORD_LEXICON.md](tools/WORD_LEXICON.md) for pack construction and source obligations. Packs contain words,
forms, POS, pronunciations and relations only, with pinned source versions/hashes and attribution. Downloaded data
and generated packs stay outside Git. Their resource licences and full notices travel separately from the ISC code.
Loading is bounded and atomic: invalid packs return typed errors and are never partially accepted. No runtime
network or model call is required.

Focused tests are `word_explorer` and `word_catalog`. `word_options_corpus` is an opt-in real-data acceptance run;
it reports “not measured” unless both `XDICT_MDX_CORPUS` and `XDICT_WORD_PACK` are supplied. Run these only on the
configured build host under its lock. They require no GUI, renders or E2E.
