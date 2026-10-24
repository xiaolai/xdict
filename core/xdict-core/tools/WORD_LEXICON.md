# The word pack

This is English linguistic metadata for `xdict_core::words`: pronunciations, inflected forms, derivational families and historical roots. `word_lexicon.py` builds it with standard-library Python, from the sources pinned in `word_lexicon_sources.json`.

**Raw downloads and built packs never enter Git.** The builder refuses an output path inside the repository.

**Records hold metadata only.** No definition, gloss, example, quotation or prose etymology is read into a record. The writer refuses any record that carries such a key.

## Build

```sh
python3 -I core/xdict-core/tools/word_lexicon.py verify --raw-dir RAW
python3 -I core/xdict-core/tools/word_lexicon.py build --raw-dir RAW \
    [--output OUT.jsonl] [--kaikki-input kaikki/receipt.json ...] [--notice-dir DIR]
```

The default output is `RAW/../pack/xdict-words-en.jsonl`. A build:

1. Checks every raw file against its pinned size and SHA-256.
2. Parses each provider.
3. Writes three files, each atomically (a temporary file, then a rename):
   - the pack;
   - `<stem>.notices.md`, which holds every source's complete notices and must travel with the pack;
   - `<stem>.report.json`, which lists record counts, records left out for a loader bound, and every skipped source row counted by reason (etymology rows skipped by shape, MorphyNet rows skipped by the rules below). Under `skippedSamples` it also keeps, for each reason, the first 50 skipped rows in source order as metadata only: the source line, the words, the POS codes, the morpheme and the type (`line`, `word`, `base`, `derived`, `basePos`, `derivedPos`, `affix`, `kind`), never a definition or a raw row. The counts cover every row; only the samples stop at 50. The report sits beside the pack, outside Git.

The same inputs give byte-identical outputs.

Tests: `python3 -I -m unittest discover -s core/xdict-core/tools -p 'test_word_lexicon.py' -v`.

## Pack format: `xdict-word-pack` v1

The pack is JSONL in UTF-8. Every string is NFC with no control characters. Each line is canonical JSON: keys sorted, no spaces, non-ASCII kept as is.

Line 1 is the header:

```json
{"type":"header","schema":"xdict-word-pack","version":1,"language":"en",
 "sources":[{"id","name","url","version","sha256","licence","attribution","coverage"?}]}
```

A source id is a lowercase manifest id (`cmu`, `morphynet-deri`), optionally followed by `:` and a per-file part of letters, digits, `.`, `_` and `-` (`kaikki:impossible`), or by `:sha256:` and 64 lowercase hex digits. Every id stays within the loader's charset (letters, digits and `- _ . :`), and the writer refuses any other.

After the header, records come in this order: pronunciation, form, derivation, origin, etymon. Within a type they are sorted by canonical line and de-duplicated. An absent optional field is omitted.

| Type | Fields |
|---|---|
| `pronunciation` | `word`, `pos`?, `system` (`arpabet` or `ipa`), `phonemes`[], `dialect`?, `source` |
| `form` | `form`, `lemma`, `pos`, `tags`[] (at least one), `source` |
| `derivation` | `base`, `basePos`?, `derived`, `derivedPos`?, `kind` (`prefix`, `suffix`, `conversion`, `compound` or `other`), `affix`?, `stem`? (see below), `source` |
| `origin` | `id` (unique), `language`, `form`, `word`? (set on an English term's own node) |
| `etymon` | `child`, `parent` (origin ids), `relation` (`inherited`, `borrowed`, `learned`, `derived`, `calque`, `compound`, `affix`, `root` or `unknown`), `uncertain`, `source` |

**`stem` is never written by the current providers.** No source supplies a stem alignment, and the builder never infers one, so every family step's stem stress is unknown. The field exists because the loader reads it. The writer validates a record that carries one exactly as the loader does:

- it is an object with exactly `basePhonemes`, `baseStart`, `baseEnd`, `derivedPhonemes`, `derivedStart` and `derivedEnd`;
- each phonemes list is non-empty ARPAbet with valid stress, at most 64 items;
- each start and end is an integer, never a bool, with start < end ≤ that pronunciation's vowel count; the indices are half-open vowel indices;
- both ranges are the same length.

An absent or `null` stem means none.

The writer holds the pack to the Rust loader's bounds (`LexiconLimits::default()` in `src/words/lexicon.rs`):

| Bound | Value | Past it |
|---|---|---|
| one line | 64 KiB | the record is left out and counted |
| one string | 256 Unicode scalars | the record is left out and counted; in the header, the build fails |
| one list | 64 items | the record is left out and counted; for the header's sources, the build fails |
| records after the header | 4,000,000 | the build fails |
| the whole pack, newlines included | 512 MiB | the build fails |

A record is never truncated. A pack past a whole-pack bound is never written, and never cut down to fit. Other faults fail the build: an unknown field, a bad ARPAbet stress, an unknown enum value, or a source missing from the header.

Parts of speech are `noun`, `verb`, `adj` and `adv` wherever a source gives one, so that the engine's POS matching lines up across sources.

The exception is Kaikki: it keeps its own POS names verbatim, which are the same four words for those classes. Its other classes (`name`, `prep`, `pron`, `num`, `det`, `conj`, `intj`, `phrase` and the like) also stay verbatim. They are distinct from the four, so a Kaikki `name` never matches a `noun`.

## Sources and mapping rules

| id | Source | Gives |
|---|---|---|
| `cmu` | CMUdict, pinned commit | ARPAbet pronunciation, every variant (`word(2)`), no POS |
| `oewn` | Open English Wordnet 2025 JSON (`entries-*.json` only) | POS-tagged IPA, with `variety` (GB or US) as the dialect; sense-level derivation links |
| `ety` | etymology-db 2023-12 CSV | explicit ancestry (origin and etymon records); English `*_with_root` derivations |
| `morphynet-infl` | MorphyNet `eng.inflectional.v1.tsv` | forms with UniMorph tags, verbatim (`V\|PRS;3;SG` gives verb, tags `PRS`, `3`, `SG`) |
| `morphynet-deri` | MorphyNet `eng.derivational.v1.tsv` | prefix and suffix derivations with both parts of speech; the affix is hyphenated by type (`im-`, `-ly`) |
| `kaikki:<word>` | one verified Kaikki per-word JSONL each (optional) | POS-tagged IPA, tagged forms, linked `form_of` lemmas, morphology-template derivations |

Pronunciations are always one whole transcription, so a phoneme alignment is never guessed.

### OEWN

**Derivation links.** OEWN gives these links no direction. The kind is `conversion` when both words have the same spelling, as with record (noun) and record (verb), and `other` otherwise.

For every OEWN pair, of kind `other` or `conversion`, `base` and `derived` are **unoriented endpoints**. The pair is written in alphabetical order (by word, then part of speech) only so the output is deterministic. So possible and possibility come out with possibility in the `base` field, but that does not mean possible derives from possibility. Likewise, a conversion always has the alphabetically earlier POS as its `base` (`adj` before `adv` before `noun` before `verb`). Record comes out as noun → verb, which says nothing about which came first. A reader must treat such a pair as a two-way link. The source's `coverage` says so too.

**Numbered entries.** An entry key is a POS code (`n`, `v`, `a`, `s`, `r`), optionally numbered (`n-1`, `n-2`) for a further lexeme of the same POS, a homograph. A numbered entry maps to its base POS, and every one is read in full: its pronunciations, its senses and its derivation links all stay, beside those of the unnumbered entry.

**Other errors.** Any other entry key (`n-x`, `n-0`, `n1`) fails the build. So does a link to a sense that no entry declares.

**Not read.** Antonyms and the untagged `form` lists are not read. Synset files are never opened.

### etymology-db

Rows come grouped by `term_id`. A row's `parent_tag` must name a group within its own block. These rules apply:

- **Ancestry rows.** A top-level ancestry row is one edge, from the term to the related term:
  - `inherited_from` gives `inherited`;
  - the `*borrowing_from` and `borrowed_from` types give `borrowed`, except the learned and semi-learned ones, which give `learned`;
  - `derived_from` gives `derived`;
  - the calque and semantic-loan types give `calque`;
  - phono-semantic matching gives `unknown`.
- **`group_derived_root` is a chain.** Its ancestry children, in `parent_position` order, are successive steps. Each edge runs from the previous step's node or nodes, and the relation comes from the step's row.
  - A nested `group_related_root` is one step of alternatives.
  - Related, cognate and affix children are not steps. A derived group nested in a chain is skipped and counted.
  - **A step that gives no node breaks the chain.** This covers three cases: an ancestry row with no related id, language or form; a related group none of whose ancestry rows gives a node; and a nested derived group, which is not read. No edge joins the steps either side of the break, because that edge would be invented. The break is counted as `ety: ancestry chain broken at a skipped step`. The steps after the break still link to one another, as a tail. No English head reaches that tail through this chain, so it reaches the pack only if something else leads to it. Rows that are not steps (related, affix, `has_root`) never break a chain.
- **`has_root`.** A `has_root` row is an edge from the term to its root, with relation `root`. It is never a chain step. Glosses such as `*per- (fare)` are stripped, and a trailing hyphen stays.
- **Not ancestry.** Affix rows (`has_prefix`, `has_suffix`, `has_confix`, `has_affix`) are not ancestry. Neither are compound, blend, clipping, doublet, cognate or `etymologically_related_to` rows. A shared affix therefore never joins words as a root.
- **Present-day families.** These come only from explicit English-to-English `has_prefix_with_root` and `has_suffix_with_root` rows, written with the related term as the base and kind `other`.
- **Scope.** Only what English heads reach is kept: a breadth-first walk of up to 12 edges. The source records no uncertainty, so `uncertain` is false throughout.
- **Unknown types.** An unknown `reltype` fails the build after the whole file is read, listing every unknown type with its count.

### MorphyNet

Unknown POS codes or derivation types are collected and fail the build together.

Two kinds of inflection row give no record:

- a row whose form equals its lemma (the `-` segmentation rows);
- a row with no tags beyond its POS.

**Known malformed rows.** The pinned inflectional file holds exactly two rows broken by stray quotes: a quoted `"softly` / ` softly"` pair split across the tab, whose feature column (`"|` in one, `comparable` in the other) is no POS code. These two exact rows are skipped and counted in the report as `morphynet-infl: known malformed quoted row`. Any other row with an unknown code still fails the build.

**Derivations.** A derivation row is kept only when its morpheme attaches to its base. The rules are deliberately conservative: they test spelling only, with no guessed allomorphy. The comparison is case-folded, and the morpheme's own hyphens are stripped first:

- **prefix:** derived is morpheme + base, or morpheme + `-` + base (possibility → impossibility with `im`; record → re-record with `re`);
- **suffix:** derived is base + morpheme literally (record → recordable), or follows one of three spelling rules, and no others:
  - **silent-e drop:** a final `e` is dropped (connote + ation → connotation), and a final `le` merges with the `l` of `ly` (possible → possibly);
  - **y → i:** a final `y` after a consonant becomes `i`, unless the suffix starts with `i` (happy → happiness);
  - **doubling:** a final single consonant (not w, x or y) after a single vowel is doubled before a suffix that starts with a vowel or `y` (run → runner, runny, runnable).

Rows that give no derivation are skipped, never dropped silently. Each is counted in the report as `morphynet-deri: <reason>`. The reasons are:

| Reason | Example |
|---|---|
| `undocumented POS U` | the source uses `U` in about 2,100 rows; its README documents only N, V, J and R, so no POS is invented |
| `prefix spelling change not modelled` | in + legal → illegal (assimilation); also run → ember with `umb` |
| `suffix spelling change not modelled` | possible + ity → possibility, conclude + sion → conclusion, admit + ssion → admission; also moon → month with `th` |
| `empty morpheme` | nothing to check the attachment against |
| `derived word equals its base` | |

**The spelling-change reasons are not source defects.** They hold ordinary English derivations whose allomorphy the rules do not model, mixed with genuinely wrong rows, and the builder cannot tell the two apart. So the pack's Derivations miss those pairs unless OEWN or etymology-db also carry them. The report's `skippedSamples` keeps the first 50 rows of each reason, so the mix can be checked on the real file. The known malformed inflection rows and the `U` rows stay separate reasons: those are real defects in the source.

A code other than `U` that the README does not document still fails the build.

The attachment check tests spelling only. A row that passes is a real attachment, but it may be archaic: run → runneth (`eth`, by doubling) is kept.

### Kaikki

Only `lang_code: en` entries are read.

**Sounds.** Only the `ipa` value is taken. A sound tag `noun`, `verb`, `adjective` or `adverb` sets the part of speech. With none, the entry's POS applies. With several, no POS is set. The remaining tags form the dialect.

**Forms.** A form is skipped if it is the headword, or if it carries any of these tags:

- `canonical`, `table-tags` or `inflection-template`;
- `romanization` or `class`;
- `alternative` or `alt-of`.

**`form_of` lemmas.** A lemma counts only when the same sense links that exact word. This keeps out "ax and axe" while keeping axis.

**Morphology templates.** These are `af`, `affix`, `prefix`, `suffix`, `compound` and `confix`, in English only:

- one base plus one affix gives `prefix` or `suffix` (`af\|en\|im-\|possible` gives possible → impossible, `im-`);
- bases with no affix give `compound`;
- anything else gives `other`;
- a foreign part (`la:…`) skips the template.

**Ancestry templates.** These are not read, because etymology-db gives the chains.

**Receipts.** Each file is a separate source with its own URL, snapshot and SHA-256, all verified against the receipt. A small file never stands in for the full corpus.

- **Source id.** The id is `kaikki:<word>` when that is a valid source id (letters, digits, `.`, `_` and `-` after the colon). Today's plain words keep their readable ids.
- **Hashed id.** Any other word gets `kaikki:sha256:` followed by the SHA-256 of its NFC UTF-8 spelling. This covers a word with a space, an apostrophe or a non-ASCII letter, and a word starting with the reserved `sha256:`. The word is never percent-encoded, because `%` is outside the loader's charset. Because `sha256:` is reserved, a plain id and a hashed id never collide.
- **Name and file.** The source's name (`Kaikki: ice cream`), its URL and its file (`ice cream.jsonl`) keep the word as written.
- **Duplicates.** A receipt that lists a word twice, NFC-equal spellings included, fails before the second file is read.

## Licences and notices

| Source | Licence |
|---|---|
| CMUdict | BSD-2-Clause |
| OEWN | CC BY 4.0 plus the WordNet 3.0 licence; both notice files are copied verbatim |
| etymology-db | CC BY-SA 3.0 (data; its code is Apache-2.0) |
| MorphyNet | CC BY-SA 3.0 |
| Kaikki and Wiktionary | CC BY-SA 4.0 (Wikimedia Terms of Use, section 7) |

The header carries only short credits. The sidecar `<stem>.notices.md` carries, for every source, its fields and its complete notices. The text sits inside a fence longer than any run of backticks in it. Each notice file is listed with its SHA-256, and the sidecar names the pack's SHA-256.

**Notice files are pinned.** Each `notice_files` item in the manifest carries the `sha256` of the exact file. A build refuses a notice file whose hash differs (`hash`), or one that lacks its marker (`licence`). A changed or substituted licence text therefore cannot reach the sidecar unnoticed.

Because the pack adapts ShareAlike sources, it is distributed as a whole under CC BY-SA 4.0. CC BY-SA 3.0 section 4(b) allows a later version. The XDict code is licensed separately and does not cover the pack.
