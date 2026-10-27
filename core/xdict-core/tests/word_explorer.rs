//! Word exploration (2026-10-24; ADR-0032 and `core/xdict-core/WORD_OPTIONS.md`): the six modes over a synthetic
//! catalog and a synthetic lexical pack, both written here. The words are real English so a reader can check the
//! expectations, but every pronunciation, form, edge and origin below is the suite's own record, not a source's data:
//! these tests prove the engine's rules, not any pack's coverage.
//!
//! Every test pairs its negatives (false orthographic rhymes and roots, antonyms, shared spellings, guessed POS,
//! index-only stress shifts) with a positive control in the same fixture, so a stub that answers nothing fails it.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::Arc;

use serde_json::{Value, json};
use xdict_core::EntryRef;
use xdict_core::words::*;

// ---- fixtures -------------------------------------------------------------------------------------------------

fn source(dict: &str, edition: &str, key: &str, occurrence: u32) -> WordSource {
    WordSource { dict: dict.into(), entry: EntryRef { edition: edition.into(), key: key.into(), occurrence } }
}

/// One catalog entry per word, each from dictionary `d1`, edition `e1`, at its own key.
fn catalog(words: &[&str]) -> Vec<WordCatalogEntry> {
    words.iter().map(|w| WordCatalogEntry { headword: (*w).into(), sources: vec![source("d1", "e1", w, 0)] }).collect()
}

fn pack_source(id: &str) -> Value {
    json!({
        "id": id,
        "name": format!("Synthetic {id}"),
        "url": format!("https://example.invalid/{id}"),
        "version": "test-1",
        "sha256": "0".repeat(64),
        "licence": "CC0-1.0",
        "attribution": "Written by the xdict-core test suite",
        "coverage": null,
    })
}

fn header() -> Value {
    json!({
        "type": "header",
        "schema": WORD_PACK_SCHEMA,
        "version": WORD_PACK_VERSION,
        "language": "en",
        "sources": [pack_source("cmu"), pack_source("wikt"), pack_source("ety")],
    })
}

fn jsonl(lines: &[Value]) -> String {
    lines.iter().map(|l| format!("{l}\n")).collect()
}

fn with_header(records: &[Value]) -> String {
    let mut lines = vec![header()];
    lines.extend_from_slice(records);
    jsonl(&lines)
}

fn load(records: &[Value]) -> Arc<WordLexicon> {
    Arc::new(WordLexicon::from_jsonl(with_header(records).as_bytes()).unwrap())
}

fn pron(word: &str, pos: Option<&str>, phonemes: &str) -> Value {
    json!({
        "type": "pronunciation",
        "word": word,
        "pos": pos,
        "system": "arpabet",
        "phonemes": phonemes.split(' ').collect::<Vec<_>>(),
        "dialect": "en-US",
        "source": "cmu",
    })
}

fn form(form: &str, lemma: &str, pos: &str, tags: &[&str]) -> Value {
    json!({ "type": "form", "form": form, "lemma": lemma, "pos": pos, "tags": tags, "source": "wikt" })
}

fn derivation(base: &str, base_pos: &str, derived: &str, derived_pos: &str, kind: &str, affix: Option<&str>) -> Value {
    json!({
        "type": "derivation",
        "base": base,
        "basePos": base_pos,
        "derived": derived,
        "derivedPos": derived_pos,
        "kind": kind,
        "affix": affix,
        "stem": null,
        "source": "wikt",
    })
}

fn stem(base: &str, base_range: (u32, u32), derived: &str, derived_range: (u32, u32)) -> Value {
    json!({
        "basePhonemes": base.split(' ').collect::<Vec<_>>(),
        "baseStart": base_range.0,
        "baseEnd": base_range.1,
        "derivedPhonemes": derived.split(' ').collect::<Vec<_>>(),
        "derivedStart": derived_range.0,
        "derivedEnd": derived_range.1,
    })
}

fn aligned(mut edge: Value, alignment: Value) -> Value {
    edge["stem"] = alignment;
    edge
}

fn origin(id: &str, language: &str, form: &str, word: Option<&str>) -> Value {
    json!({ "type": "origin", "id": id, "language": language, "form": form, "word": word })
}

fn etymon(child: &str, parent: &str, relation: &str, uncertain: bool) -> Value {
    json!({
        "type": "etymon",
        "child": child,
        "parent": parent,
        "relation": relation,
        "uncertain": uncertain,
        "source": "ety",
    })
}

fn query(text: &str, mode: WordMode) -> WordQuery {
    WordQuery { text: text.into(), mode, limit: 100, offset: 0 }
}

fn search(explorer: &WordExplorer, text: &str, mode: WordMode) -> WordPage {
    let page = explorer.search(query(text, mode)).unwrap();
    assert_backed(&page);
    page
}

fn heads(page: &WordPage) -> Vec<&str> {
    page.hits.iter().map(|h| h.headword.as_str()).collect()
}

fn hit<'a>(page: &'a WordPage, headword: &str) -> &'a WordHit {
    let found = page.hits.iter().find(|h| h.headword == headword);
    found.unwrap_or_else(|| panic!("{headword} not in {:?}", heads(page)))
}

/// Every hit is a dictionary's word with at least one reason, and an exhaustive answer says how many.
fn assert_backed(page: &WordPage) {
    for h in &page.hits {
        assert!(!h.sources.is_empty(), "{} has no dictionary behind it", h.headword);
        assert!(!h.reasons.is_empty(), "{} has no reason", h.headword);
    }
    assert!(
        page.total.is_some() != page.exhausted.is_some() || page.status != WordStatus::Answered,
        "an answered page is either exhaustive with a total or exhausted without one: {page:?}"
    );
}

// ---- requests ---------------------------------------------------------------------------------------------------

#[test]
fn queries_out_of_bounds_are_refused_with_their_problem() {
    let explorer = WordExplorer::new(catalog(&["word"]), None).unwrap();
    let refused = |q: WordQuery, want: QueryProblem| match explorer.search(q.clone()) {
        Err(WordError::InvalidQuery { problem, .. }) => assert_eq!(problem, want, "{q:?}"),
        other => panic!("{q:?} should be refused as {want:?}, got {other:?}"),
    };
    refused(query("", WordMode::EndsWith), QueryProblem::Empty);
    refused(query("wo\u{7}rd", WordMode::EndsWith), QueryProblem::ControlCharacter);
    refused(query("wo\nrd", WordMode::EndsWith), QueryProblem::ControlCharacter);
    refused(query(&"a".repeat(MAX_QUERY_CHARS + 1), WordMode::EndsWith), QueryProblem::TooLong);
    refused(WordQuery { limit: 0, ..query("word", WordMode::EndsWith) }, QueryProblem::Limit);
    refused(WordQuery { limit: MAX_WORD_PAGE + 1, ..query("word", WordMode::EndsWith) }, QueryProblem::Limit);
    refused(query("word", WordMode::Fuzzy { max_distance: 0 }), QueryProblem::Distance);
    refused(query("word", WordMode::Fuzzy { max_distance: MAX_FUZZY_DISTANCE + 1 }), QueryProblem::Distance);
    refused(query("word", WordMode::Roots { max_depth: 0 }), QueryProblem::Depth);
    refused(query("word", WordMode::Roots { max_depth: MAX_ROOT_DEPTH + 1 }), QueryProblem::Depth);

    // The bounds themselves are accepted: 128 scalars (multi-byte ones), the largest page, distance and depth.
    let long = "é".repeat(MAX_QUERY_CHARS);
    assert!(explorer.search(query(&long, WordMode::EndsWith)).is_ok());
    assert!(explorer.search(WordQuery { limit: MAX_WORD_PAGE, ..query("word", WordMode::EndsWith) }).is_ok());
    let fuzzy = search(&explorer, "wrod", WordMode::Fuzzy { max_distance: MAX_FUZZY_DISTANCE });
    assert_eq!(heads(&fuzzy), ["word"]);
}

// ---- catalog ----------------------------------------------------------------------------------------------------

#[test]
fn one_spelling_is_one_hit_with_every_source_once_and_its_editions_are_listed() {
    let mut entries = vec![
        WordCatalogEntry { headword: "run".into(), sources: vec![source("d1", "e1", "run", 0)] },
        WordCatalogEntry { headword: "run".into(), sources: vec![source("d1", "e1", "run", 1)] },
        // The same dictionary handle and key again: no second source, no second hit.
        WordCatalogEntry { headword: "run".into(), sources: vec![source("d1", "e1", "run", 0)] },
        WordCatalogEntry { headword: "run".into(), sources: vec![source("d2", "e2", "run", 0)] },
        // Another spelling, caseless-equal: its own hit, shown as spelt.
        WordCatalogEntry { headword: "Run".into(), sources: vec![source("d2", "e2", "Run", 0)] },
        WordCatalogEntry { headword: "rerun".into(), sources: vec![source("d1", "e1", "rerun", 0)] },
    ];
    entries.push(WordCatalogEntry { headword: String::new(), sources: vec![source("d1", "e1", "", 0)] });
    let explorer = WordExplorer::new(entries, None).unwrap();

    let page = search(&explorer, "run", WordMode::EndsWith);
    assert_eq!(heads(&page), ["Run", "run", "rerun"], "exact first, then by normalized and catalog spelling");
    assert_eq!(
        hit(&page, "run").sources,
        [source("d1", "e1", "run", 0), source("d1", "e1", "run", 1), source("d2", "e2", "run", 0)]
    );
    assert_eq!(hit(&page, "run").reasons, [WordReason::Exact]);
    assert_eq!(hit(&page, "Run").reasons, [WordReason::Exact]);
    assert_eq!(hit(&page, "rerun").reasons, [WordReason::EndsWith]);
    assert_eq!(page.total, Some(3));

    let stats = explorer.stats();
    assert_eq!(stats.headwords, 3);
    assert_eq!(stats.skipped_headwords, 1, "an empty headword is counted, not silently dropped");
    assert_eq!(stats.editions, ["e1", "e2"]);
}

// ---- ends-with --------------------------------------------------------------------------------------------------

#[test]
fn ends_with_is_canonical_and_caseless_but_strips_no_mark() {
    let words = ["caf\u{e9}", "cafe", "fianc\u{e9}", "nai\u{308}ve", "olive"];
    let explorer = WordExplorer::new(catalog(&words), None).unwrap();

    // A decomposed capital É finds the composed é, and the catalog's spelling is what is shown.
    let page = search(&explorer, "E\u{301}", WordMode::EndsWith);
    assert_eq!(heads(&page), ["caf\u{e9}", "fianc\u{e9}"]);
    assert!(!heads(&page).contains(&"cafe"), "a mark is part of the spelling");

    // A composed ï finds a decomposed headword, shown decomposed.
    let page = search(&explorer, "\u{ef}ve", WordMode::EndsWith);
    assert_eq!(heads(&page), ["nai\u{308}ve"]);
    assert!(!heads(&page).contains(&"olive"));
}

#[test]
fn ends_with_pages_carry_a_total_and_the_next_offset() {
    let words = ["station", "onion", "ion", "nation", "lion", "Ion", "ionic"];
    let explorer = WordExplorer::new(catalog(&words), None).unwrap();
    let page = |offset, limit| {
        explorer.search(WordQuery { text: "ion".into(), mode: WordMode::EndsWith, limit, offset }).unwrap()
    };

    let first = page(0, 2);
    assert_eq!(heads(&first), ["Ion", "ion"]);
    assert_eq!(first.total, Some(6), "ionic does not end with ion");
    assert_eq!(first.next, Some(2));
    assert_eq!(first.exhausted, None);

    let last = page(4, 2);
    assert_eq!(heads(&last), ["onion", "station"]);
    assert_eq!(last.next, None);

    let past = page(6, 2);
    assert!(past.hits.is_empty());
    assert_eq!(past.total, Some(6));
    assert_eq!(past.next, None);

    // The same question answers the same page.
    assert_eq!(page(2, 2), page(2, 2));
    assert_eq!(heads(&page(2, 2)), ["lion", "nation"]);
}

// ---- fuzzy ------------------------------------------------------------------------------------------------------

#[test]
fn fuzzy_is_optimal_string_alignment_exact_first_then_distance() {
    let explorer =
        WordExplorer::new(catalog(&["from", "forms", "farm", "foam", "fro", "for", "form", "abc", "ca", "cart"]), None)
            .unwrap();

    let one = search(&explorer, "form", WordMode::Fuzzy { max_distance: 1 });
    assert_eq!(heads(&one), ["form", "farm", "foam", "for", "forms", "from"]);
    assert_eq!(hit(&one, "form").reasons, [WordReason::Exact]);
    let transposed = &hit(&one, "from").reasons;
    assert_eq!(transposed, &[WordReason::Spelling { distance: 1 }], "an adjacent transposition is one edit");
    assert_eq!(hit(&one, "forms").reasons, [WordReason::Spelling { distance: 1 }]);
    assert!(!heads(&one).contains(&"fro"), "form → fro is 2");

    let two = search(&explorer, "form", WordMode::Fuzzy { max_distance: 2 });
    assert_eq!(hit(&two, "fro").reasons, [WordReason::Spelling { distance: 2 }]);
    assert_eq!(heads(&two).last(), Some(&"fro"), "distance before spelling");

    // Optimal string alignment, not unrestricted Damerau: ca → abc is 3 (Damerau would say 2).
    let ca2 = search(&explorer, "ca", WordMode::Fuzzy { max_distance: 2 });
    assert!(heads(&ca2).contains(&"ca"));
    assert!(!heads(&ca2).contains(&"abc"));
    let ca3 = search(&explorer, "ca", WordMode::Fuzzy { max_distance: 3 });
    assert_eq!(hit(&ca3, "abc").reasons, [WordReason::Spelling { distance: 3 }]);
}

#[test]
fn a_search_past_its_budget_says_so_and_claims_no_total() {
    let words: Vec<String> = (0..2_000).map(|i| format!("w{i}")).collect();
    let words: Vec<&str> = words.iter().map(String::as_str).collect();

    let unlimited = WordExplorer::new(catalog(&words), None).unwrap();
    let full = search(&unlimited, "w1", WordMode::Fuzzy { max_distance: 1 });
    assert!(full.total.is_some() && full.exhausted.is_none(), "the default budget covers this: {full:?}");
    assert!(heads(&full).contains(&"w10"));

    let budget = WordBudget { max_comparisons: 10, max_graph_nodes: 1 };
    let tight = WordExplorer::with_budget(catalog(&words), None, budget).unwrap();
    let cut = search(&tight, "w1", WordMode::Fuzzy { max_distance: 1 });
    assert_eq!(cut.exhausted, Some(WordLimit::Work));
    assert_eq!(cut.total, None, "a cut answer is never presented as complete");
}

// ---- rhyme ------------------------------------------------------------------------------------------------------

fn sense(word: &str, other: &str, relation: &str, synset: &str) -> Value {
    json!({
        "type": "sense",
        "word": word,
        "other": other,
        "relation": relation,
        "synset": synset,
        "pos": "adjective",
        "source": "wikt",
    })
}

/// **Synonyms and antonyms come from the pack's synsets, and only for words the dictionaries hold**: a relation to a
/// word no dictionary has is not a result (ADR-0032 d.1), and a pack without them says so instead of answering none.
#[test]
fn a_synset_gives_synonyms_and_antonyms_of_the_words_the_dictionaries_hold() {
    let words = catalog(&["good", "fine", "bad", "elsewhere"]);
    let pack = load(&[
        sense("good", "fine", "synonym", "oewn-good-a"),
        sense("good", "bad", "antonym", "oewn-good-a"),
        sense("good", "unlisted", "synonym", "oewn-good-a"),
    ]);
    let explorer = WordExplorer::new(words, Some(pack.clone())).unwrap();
    let ask = |mode| explorer.search(WordQuery { text: "good".into(), mode, limit: 10, offset: 0 }).unwrap();

    let synonyms = ask(WordMode::Synonyms);
    assert_eq!(synonyms.status, WordStatus::Answered);
    assert_eq!(synonyms.hits.iter().map(|h| h.headword.as_str()).collect::<Vec<_>>(), ["fine"]);
    let antonyms = ask(WordMode::Antonyms);
    assert_eq!(antonyms.hits.iter().map(|h| h.headword.as_str()).collect::<Vec<_>>(), ["bad"]);

    // The word itself is not in the pack: nothing is claimed about it.
    assert_eq!(
        explorer
            .search(WordQuery { text: "elsewhere".into(), mode: WordMode::Synonyms, limit: 10, offset: 0 })
            .unwrap()
            .status,
        WordStatus::QueryUnknown { data: WordData::Senses }
    );
    // Without a pack, the mode says which data it would need.
    let bare = WordExplorer::new(catalog(&["good"]), None).unwrap();
    assert_eq!(
        bare.search(WordQuery { text: "good".into(), mode: WordMode::Antonyms, limit: 10, offset: 0 }).unwrap().status,
        WordStatus::NoData { data: WordData::Senses }
    );
}

fn rhyme_pack() -> Arc<WordLexicon> {
    load(&[
        pron("nation", None, "N EY1 SH AH0 N"),
        pron("station", None, "S T EY1 SH AH0 N"),
        pron("ration", None, "R EY1 SH AH0 N"),
        pron("ration", None, "R AE1 SH AH0 N"),
        pron("fashion", None, "F AE1 SH AH0 N"),
        pron("passion", None, "P AE1 SH AH0 N"),
        pron("tough", None, "T AH1 F"),
        pron("stuff", None, "S T AH1 F"),
        pron("rough", None, "R AH1 F"),
        pron("cough", None, "K AO1 F"),
        pron("though", None, "DH OW1"),
        pron("through", None, "TH R UW1"),
        pron("bough", None, "B AW1"),
        pron("understand", None, "AH2 N D ER0 S T AE1 N D"),
        pron("hand", None, "HH AE1 N D"),
        pron("monotone", None, "M AA1 N AH0 T OW2 N"),
        pron("tone", None, "T OW1 N"),
        pron("orange", None, "AO1 R AH0 N JH"),
    ])
}

fn rhyme_catalog() -> Vec<WordCatalogEntry> {
    // `rough` is in the pack but not the catalog; `gration` and `zzyzx` are in the catalog with no pronunciation.
    catalog(&[
        "nation",
        "Nation",
        "station",
        "ration",
        "fashion",
        "passion",
        "gration",
        "tough",
        "stuff",
        "cough",
        "though",
        "through",
        "bough",
        "understand",
        "hand",
        "monotone",
        "tone",
        "orange",
        "zzyzx",
    ])
}

#[test]
fn rhymes_come_from_pronunciation_not_spelling() {
    let explorer = WordExplorer::new(rhyme_catalog(), Some(rhyme_pack())).unwrap();

    let nation = search(&explorer, "nation", WordMode::Rhyme);
    assert_eq!(nation.status, WordStatus::Answered);
    assert_eq!(heads(&nation), ["ration", "station"], "the query's own spelling, in any case, is not its rhyme");
    assert!(!heads(&nation).contains(&"gration"), "no pronunciation is guessed from spelling");
    assert!(!heads(&nation).contains(&"passion"), "-tion and -ssion spell nothing about the rime");
    let WordReason::Rhyme { query, hit: rhymed, rime } = &hit(&nation, "station").reasons[0] else {
        panic!("not a rhyme reason")
    };
    assert_eq!(query.phonemes, ["N", "EY1", "SH", "AH0", "N"]);
    assert_eq!(rhymed.phonemes, ["S", "T", "EY1", "SH", "AH0", "N"]);
    assert_eq!(rime, &["EY1", "SH", "AH0", "N"]);

    let tough = search(&explorer, "tough", WordMode::Rhyme);
    assert_eq!(heads(&tough), ["stuff"], "-ough rhymes nothing by its letters; rough is not in any dictionary");

    // The last stressed vowel, secondary stress included and counted alike.
    assert_eq!(heads(&search(&explorer, "understand", WordMode::Rhyme)), ["hand"]);
    assert_eq!(heads(&search(&explorer, "tone", WordMode::Rhyme)), ["monotone"]);

    // A query need not be a headword: its pronunciation is enough.
    assert_eq!(heads(&search(&explorer, "rough", WordMode::Rhyme)), ["stuff", "tough"]);
}

#[test]
fn unknown_pronunciation_is_not_the_same_as_no_rhyme() {
    let explorer = WordExplorer::new(rhyme_catalog(), Some(rhyme_pack())).unwrap();

    let orange = search(&explorer, "orange", WordMode::Rhyme);
    assert_eq!(orange.status, WordStatus::Answered);
    assert!(orange.hits.is_empty());
    assert_eq!(orange.total, Some(0));

    let unknown = search(&explorer, "zzyzx", WordMode::Rhyme);
    assert_eq!(unknown.status, WordStatus::QueryUnknown { data: WordData::Pronunciation });
    assert!(unknown.hits.is_empty());

    let bare = WordExplorer::new(rhyme_catalog(), None).unwrap();
    assert_eq!(search(&bare, "nation", WordMode::Rhyme).status, WordStatus::NoData { data: WordData::Pronunciation });

    // Positive control on the same explorer.
    assert_eq!(heads(&search(&explorer, "nation", WordMode::Rhyme)), ["ration", "station"]);
}

#[test]
fn every_pronunciation_rhymes_and_keeps_its_provenance() {
    let explorer = WordExplorer::new(rhyme_catalog(), Some(rhyme_pack())).unwrap();

    let ration = search(&explorer, "ration", WordMode::Rhyme);
    let both = ["fashion", "nation", "passion", "station"];
    assert_eq!(heads(&ration), both, "each of ration's pronunciations rhymes");
    let WordReason::Rhyme { query, hit: rhymed, .. } = &hit(&ration, "fashion").reasons[0] else { panic!() };
    assert_eq!(query.phonemes, ["R", "AE1", "SH", "AH0", "N"], "the reason names which pronunciation rhymed");
    assert_eq!(rhymed.source, "cmu");
    assert_eq!(rhymed.dialect.as_deref(), Some("en-US"));
    assert_eq!(rhymed.system, PhoneSystem::Arpabet);
    assert_eq!(rhymed.pos, None);
    let WordReason::Rhyme { query, .. } = &hit(&ration, "nation").reasons[0] else { panic!() };
    assert_eq!(query.phonemes, ["R", "EY1", "SH", "AH0", "N"]);
}

// ---- inflections ------------------------------------------------------------------------------------------------

fn forms_pack() -> Arc<WordLexicon> {
    load(&[
        form("ran", "run", "verb", &["past"]),
        form("runs", "run", "verb", &["present", "third-person", "singular"]),
        form("running", "run", "verb", &["present", "participle"]),
        form("went", "go", "verb", &["past"]),
        form("goes", "go", "verb", &["present", "third-person", "singular"]),
        form("going", "go", "verb", &["present", "participle"]),
        form("gone", "go", "verb", &["past", "participle"]),
        form("saw", "see", "verb", &["past"]),
        form("sees", "see", "verb", &["present", "third-person", "singular"]),
        form("seen", "see", "verb", &["past", "participle"]),
        form("saws", "saw", "noun", &["plural"]),
        form("saws", "saw", "verb", &["present", "third-person", "singular"]),
        form("axes", "axe", "noun", &["plural"]),
        form("axes", "axis", "noun", &["plural"]),
        derivation("run", "verb", "runner", "noun", "suffix", Some("-er")),
    ])
}

fn forms_catalog() -> Vec<WordCatalogEntry> {
    catalog(&[
        "run", "ran", "runs", "running", "runner", "rune", "rain", "go", "went", "goes", "going", "gone", "see", "saw",
        "sees", "seen", "saws", "axe", "axis", "axes",
    ])
}

#[test]
fn inflections_reach_the_paradigm_from_a_form_or_its_lemma() {
    let explorer = WordExplorer::new(forms_catalog(), Some(forms_pack())).unwrap();

    let ran = search(&explorer, "ran", WordMode::Inflections);
    assert_eq!(heads(&ran), ["run", "running", "runs"]);
    assert_eq!(
        hit(&ran, "run").reasons,
        [WordReason::Inflection {
            lemma: "run".into(),
            pos: "verb".into(),
            query_role: FormRole::Form { tags: vec!["past".into()] },
            hit_role: FormRole::Lemma,
            source: "wikt".into(),
        }]
    );

    let run = search(&explorer, "run", WordMode::Inflections);
    assert_eq!(heads(&run), ["ran", "running", "runs"]);
    assert!(!heads(&run).contains(&"runner"), "a derivation is not an inflection");
    assert!(!heads(&run).contains(&"rune"), "nor is a shared spelling");

    // Irregular paradigms come from the records, not from rules.
    assert_eq!(heads(&search(&explorer, "went", WordMode::Inflections)), ["go", "goes", "going", "gone"]);
}

fn lemmas(h: &WordHit) -> Vec<(&str, &str)> {
    h.reasons
        .iter()
        .map(|r| match r {
            WordReason::Inflection { lemma, pos, .. } => (lemma.as_str(), pos.as_str()),
            other => panic!("{other:?}"),
        })
        .collect()
}

#[test]
fn an_ambiguous_form_reaches_every_paradigm_and_says_which() {
    let explorer = WordExplorer::new(forms_catalog(), Some(forms_pack())).unwrap();

    let saw = search(&explorer, "saw", WordMode::Inflections);
    assert_eq!(heads(&saw), ["saws", "see", "seen", "sees"]);
    let saws = lemmas(hit(&saw, "saws"));
    assert_eq!(saws, [("saw", "noun"), ("saw", "verb")], "reasons by lemma, then part of speech");
    assert_eq!(lemmas(hit(&saw, "see")), [("see", "verb")]);

    let axes = search(&explorer, "axes", WordMode::Inflections);
    assert_eq!(heads(&axes), ["axe", "axis"]);
    assert_eq!(lemmas(hit(&axes, "axis")), [("axis", "noun")]);

    let rune = search(&explorer, "rune", WordMode::Inflections);
    assert_eq!(rune.status, WordStatus::QueryUnknown { data: WordData::Forms });

    let bare = WordExplorer::new(forms_catalog(), Some(rhyme_pack())).unwrap();
    assert_eq!(search(&bare, "ran", WordMode::Inflections).status, WordStatus::NoData { data: WordData::Forms });
}

// ---- derivations ------------------------------------------------------------------------------------------------

const POSSIBLE: &str = "P AA1 S AH0 B AH0 L";
const IMPOSSIBLE: &str = "IH2 M P AA1 S AH0 B AH0 L";
const POSSIBILITY: &str = "P AA2 S AH0 B IH1 L AH0 T IY0";

fn family_records() -> Vec<Value> {
    vec![
        derivation("possible", "adj", "impossible", "adj", "prefix", Some("im-")),
        derivation("possible", "adj", "possibility", "noun", "suffix", Some("-ity")),
        derivation("possible", "adj", "possibly", "adv", "suffix", Some("-ly")),
        derivation("impossible", "adj", "impossibility", "noun", "suffix", Some("-ity")),
        derivation("hot", "adj", "hotly", "adv", "suffix", Some("-ly")),
        pron("possible", None, POSSIBLE),
        pron("impossible", None, IMPOSSIBLE),
        pron("possibility", None, POSSIBILITY),
    ]
}

fn family_catalog() -> Vec<WordCatalogEntry> {
    catalog(&[
        "possible",
        "impossible",
        "possibility",
        "possibly",
        "impossibility",
        "posse",
        "possum",
        "hot",
        "hotly",
        "cold",
        "car",
        "carpet",
        "record",
    ])
}

fn steps(h: &WordHit) -> &[FamilyStep] {
    match &h.reasons[0] {
        WordReason::Derivation { steps, .. } => steps,
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_family_is_its_sourced_edges_base_derived_and_siblings() {
    let explorer = WordExplorer::new(family_catalog(), Some(load(&family_records()))).unwrap();

    let possible = search(&explorer, "possible", WordMode::Derivations);
    let family = ["impossible", "possibility", "possibly", "impossibility"];
    assert_eq!(heads(&possible), family, "by steps, then spelling");
    assert_eq!(steps(hit(&possible, "possibility"))[0].kind, FamilyKind::Suffix);
    assert_eq!(steps(hit(&possible, "possibility"))[0].affix.as_deref(), Some("-ity"));
    assert_eq!(steps(hit(&possible, "possibility"))[0].derived_pos.as_deref(), Some("noun"));

    let impossible = search(&explorer, "impossible", WordMode::Derivations);
    assert_eq!(heads(&impossible), ["impossibility", "possible", "possibility", "possibly"]);
    let sibling = steps(hit(&impossible, "possibility"));
    assert_eq!(sibling.len(), 2);
    assert!(sibling[0].toward_base && sibling[0].base == "possible" && sibling[0].derived == "impossible");
    assert!(!sibling[1].toward_base && sibling[1].derived == "possibility");

    let possibility = search(&explorer, "possibility", WordMode::Derivations);
    assert_eq!(heads(&possibility), ["possible", "impossible", "possibly", "impossibility"]);
    assert!(!heads(&possibility).contains(&"posse") && !heads(&possibility).contains(&"possum"));
}

#[test]
fn antonyms_and_shared_spellings_are_no_family() {
    let explorer = WordExplorer::new(family_catalog(), Some(load(&family_records()))).unwrap();

    let hot = search(&explorer, "hot", WordMode::Derivations);
    assert_eq!(heads(&hot), ["hotly"], "positive control");
    assert!(!heads(&hot).contains(&"cold"), "an antonym is not a derivation");

    let cold = search(&explorer, "cold", WordMode::Derivations);
    assert_eq!(cold.status, WordStatus::QueryUnknown { data: WordData::Derivations });
    let car = search(&explorer, "car", WordMode::Derivations);
    assert_eq!(car.status, WordStatus::QueryUnknown { data: WordData::Derivations });
    assert!(car.hits.is_empty(), "carpet shares letters, not a family");
}

#[test]
fn a_moved_stress_index_after_a_prefix_is_not_a_stem_stress_shift() {
    let explorer = WordExplorer::new(family_catalog(), Some(load(&family_records()))).unwrap();
    let possible = search(&explorer, "possible", WordMode::Derivations);
    let impossible = &steps(hit(&possible, "impossible"))[0];
    assert_eq!(impossible.stem_stress, StemStress::Unknown { why: StressUnknown::NoAlignment });
    let WordReason::Derivation { query_pronunciations, hit_pronunciations, .. } =
        &hit(&possible, "impossible").reasons[0]
    else {
        panic!()
    };
    assert_eq!(query_pronunciations[0].phonemes.join(" "), POSSIBLE, "the patterns are reported as sourced");
    assert_eq!(hit_pronunciations[0].phonemes.join(" "), IMPOSSIBLE);

    // With the source's alignment: impossible's stem is vowels 1..4, the same stress as possible's 0..3.
    let mut records = family_records();
    records[0] = aligned(records[0].clone(), stem(POSSIBLE, (0, 3), IMPOSSIBLE, (1, 4)));
    records[1] = aligned(records[1].clone(), stem(POSSIBLE, (0, 3), POSSIBILITY, (0, 3)));
    let explorer = WordExplorer::new(family_catalog(), Some(load(&records))).unwrap();
    let possible = search(&explorer, "possible", WordMode::Derivations);
    assert_eq!(steps(hit(&possible, "impossible"))[0].stem_stress, StemStress::Same { stress: vec![1, 0, 0] });
    assert_eq!(
        steps(hit(&possible, "possibility"))[0].stem_stress,
        StemStress::Shifted { base: vec![1, 0, 0], derived: vec![2, 0, 1] },
        "-ity moves the stem's stress, by the alignment"
    );
}

#[test]
fn conversion_keeps_one_spelling_two_parts_of_speech_and_never_assigns_pos_by_order() {
    // CMUdict-style: two untagged variants. Their order says nothing about which is the noun.
    let untagged = load(&[
        pron("record", None, "R EH1 K ER0 D"),
        pron("record", None, "R IH0 K AO1 R D"),
        derivation("record", "noun", "record", "verb", "conversion", None),
        derivation("hot", "adj", "hotly", "adv", "suffix", Some("-ly")),
    ]);
    let explorer = WordExplorer::new(family_catalog(), Some(untagged)).unwrap();
    let record = search(&explorer, "record", WordMode::Derivations);
    assert_eq!(heads(&record), ["record"], "zero derivation relates a spelling to itself");
    let WordReason::Derivation { steps, query_pronunciations, hit_pronunciations } = &hit(&record, "record").reasons[0]
    else {
        panic!()
    };
    assert_eq!(steps.len(), 1);
    assert_eq!(steps[0].kind, FamilyKind::Conversion);
    assert_eq!((steps[0].base_pos.as_deref(), steps[0].derived_pos.as_deref()), (Some("noun"), Some("verb")));
    assert_eq!(steps[0].stem_stress, StemStress::Unknown { why: StressUnknown::NoAlignment });
    assert_eq!(query_pronunciations.len(), 2, "every variant is kept");
    assert!(query_pronunciations.iter().chain(hit_pronunciations).all(|p| p.pos.is_none()), "no POS by order");

    // Tagged by the source, with its alignment: the stress moves.
    let noun = "R EH1 K ER0 D";
    let verb = "R IH0 K AO1 R D";
    let tagged = load(&[
        pron("record", Some("noun"), noun),
        pron("record", Some("verb"), verb),
        aligned(derivation("record", "noun", "record", "verb", "conversion", None), stem(noun, (0, 2), verb, (0, 2))),
    ]);
    let explorer = WordExplorer::new(family_catalog(), Some(tagged)).unwrap();
    let record = search(&explorer, "record", WordMode::Derivations);
    let WordReason::Derivation { steps, query_pronunciations, hit_pronunciations } = &hit(&record, "record").reasons[0]
    else {
        panic!()
    };
    assert_eq!(steps[0].stem_stress, StemStress::Shifted { base: vec![1, 0], derived: vec![0, 1] });
    assert_eq!(query_pronunciations.iter().map(|p| p.pos.as_deref()).collect::<Vec<_>>(), [Some("noun")]);
    assert_eq!(hit_pronunciations.iter().map(|p| p.pos.as_deref()).collect::<Vec<_>>(), [Some("verb")]);
}

/// The edge with one end's part of speech left unstated by the source (`basePos` or `derivedPos`).
fn unstated(mut edge: Value, field: &str) -> Value {
    edge[field] = Value::Null;
    edge
}

fn kinds(steps: &[FamilyStep]) -> Vec<FamilyKind> {
    steps.iter().map(|s| s.kind).collect()
}

/// `pivot` is a verb on one edge and a noun on the other: two words that share a spelling.
fn pivot_records() -> Vec<Value> {
    vec![
        derivation("alpha", "verb", "pivot", "verb", "suffix", Some("-x")),
        derivation("pivot", "noun", "beta", "noun", "suffix", Some("-y")),
    ]
}

fn pivot_catalog() -> Vec<WordCatalogEntry> {
    catalog(&["alpha", "pivot", "beta", "gamma", "hub", "delta", "eta", "node", "theta", "kappa"])
}

#[test]
fn a_family_walk_does_not_cross_two_stated_parts_of_speech_through_a_shared_spelling() {
    let explorer = WordExplorer::new(pivot_catalog(), Some(load(&pivot_records()))).unwrap();

    let alpha = search(&explorer, "alpha", WordMode::Derivations);
    assert_eq!(alpha.status, WordStatus::Answered);
    assert_eq!(heads(&alpha), ["pivot"], "positive control: the verb edge itself");
    assert_eq!(steps(hit(&alpha, "pivot")).len(), 1);
    assert!(
        !heads(&alpha).contains(&"beta"),
        "pivot the verb is not pivot the noun: a shared spelling is no evidence, only a conversion edge is"
    );
    assert_eq!(alpha.total, Some(1));

    // From the shared spelling itself, with no part of speech asked, each of its own branches is walked.
    let pivot = search(&explorer, "pivot", WordMode::Derivations);
    assert_eq!(heads(&pivot), ["alpha", "beta"]);
    let to_alpha = steps(hit(&pivot, "alpha"));
    assert_eq!(to_alpha.len(), 1);
    assert!(to_alpha[0].toward_base);
    assert_eq!(to_alpha[0].derived_pos.as_deref(), Some("verb"));
    let to_beta = steps(hit(&pivot, "beta"));
    assert_eq!(to_beta.len(), 1);
    assert!(!to_beta[0].toward_base);
    assert_eq!(to_beta[0].base_pos.as_deref(), Some("noun"));

    // And the other way: beta reaches pivot the noun, not alpha through pivot the verb.
    let beta = search(&explorer, "beta", WordMode::Derivations);
    assert_eq!(heads(&beta), ["pivot"]);
    assert!(!heads(&beta).contains(&"alpha"));
}

#[test]
fn a_stated_conversion_is_the_step_that_joins_two_parts_of_speech() {
    let mut records = pivot_records();
    records.push(derivation("pivot", "verb", "pivot", "noun", "conversion", None));
    let explorer = WordExplorer::new(pivot_catalog(), Some(load(&records))).unwrap();

    let alpha = search(&explorer, "alpha", WordMode::Derivations);
    assert_eq!(heads(&alpha), ["pivot", "beta"], "by steps: pivot in one, beta in three");
    assert_eq!(steps(hit(&alpha, "pivot")).len(), 1);
    let path = steps(hit(&alpha, "beta"));
    assert_eq!(path.len(), 3, "alpha → pivot (verb) → pivot (noun) → beta: the conversion is a step of its own");
    assert_eq!(kinds(path), [FamilyKind::Suffix, FamilyKind::Conversion, FamilyKind::Suffix]);
    assert!(path.iter().all(|s| !s.toward_base));
    assert_eq!((path[1].base_pos.as_deref(), path[1].derived_pos.as_deref()), (Some("verb"), Some("noun")));

    let beta = search(&explorer, "beta", WordMode::Derivations);
    assert_eq!(heads(&beta), ["pivot", "alpha"]);
    let back = steps(hit(&beta, "alpha"));
    assert_eq!(kinds(back), [FamilyKind::Suffix, FamilyKind::Conversion, FamilyKind::Suffix]);
    assert!(back.iter().all(|s| s.toward_base));

    // From pivot: both branches in one step each, and the conversion relating the spelling to itself.
    let pivot = search(&explorer, "pivot", WordMode::Derivations);
    assert_eq!(heads(&pivot), ["alpha", "beta", "pivot"]);
    assert_eq!(steps(hit(&pivot, "alpha")).len(), 1);
    assert_eq!(steps(hit(&pivot, "beta")).len(), 1);
    assert_eq!(kinds(steps(hit(&pivot, "pivot"))), [FamilyKind::Conversion]);
}

#[test]
fn an_unstated_part_of_speech_joins_either_but_invents_no_label() {
    let records = vec![
        // hub's part of speech is unstated where gamma's edge arrives: it meets hub the noun.
        unstated(derivation("gamma", "verb", "hub", "noun", "suffix", Some("-x")), "derivedPos"),
        derivation("hub", "noun", "delta", "noun", "suffix", Some("-y")),
        // node's part of speech is unstated where theta's edge leaves: node the verb meets it.
        derivation("eta", "verb", "node", "verb", "suffix", Some("-x")),
        unstated(derivation("node", "noun", "theta", "noun", "suffix", Some("-y")), "basePos"),
        // Control: node the noun, stated, is still not node the verb.
        derivation("node", "noun", "kappa", "noun", "suffix", Some("-z")),
    ];
    let explorer = WordExplorer::new(pivot_catalog(), Some(load(&records))).unwrap();

    let gamma = search(&explorer, "gamma", WordMode::Derivations);
    assert_eq!(heads(&gamma), ["hub", "delta"]);
    let path = steps(hit(&gamma, "delta"));
    assert_eq!(path.len(), 2);
    assert_eq!(path[0].derived_pos, None, "the unstated end stays unstated, not filled in from its neighbour");

    let eta = search(&explorer, "eta", WordMode::Derivations);
    assert_eq!(heads(&eta), ["node", "theta"]);
    let path = steps(hit(&eta, "theta"));
    assert_eq!(path.len(), 2);
    assert_eq!(path[1].base_pos, None);
    assert!(!heads(&eta).contains(&"kappa"), "verb and noun, both stated, need a conversion");
}

#[test]
fn graph_modes_charge_every_edge_before_using_it() {
    let conversion = || load(&[derivation("record", "noun", "record", "verb", "conversion", None)]);
    let deep = WordMode::Roots { max_depth: MAX_ROOT_DEPTH };

    // Positive controls: the default budget answers both.
    let explorer = WordExplorer::new(family_catalog(), Some(conversion())).unwrap();
    assert_eq!(heads(&search(&explorer, "record", WordMode::Derivations)), ["record"]);
    let explorer = WordExplorer::new(roots_catalog(), Some(load(&roots_records()))).unwrap();
    assert_eq!(heads(&search(&explorer, "bank", deep)), ["bench"]);

    // No comparisons at all: not the query's own conversion, not one etymology edge, and the page says why.
    let none = WordBudget { max_comparisons: 0, ..WordBudget::default() };
    let explorer = WordExplorer::with_budget(family_catalog(), Some(conversion()), none).unwrap();
    let record = search(&explorer, "record", WordMode::Derivations);
    assert_eq!(record.exhausted, Some(WordLimit::Work));
    assert!(record.hits.is_empty() && record.total.is_none(), "{record:?}");
    let explorer = WordExplorer::with_budget(roots_catalog(), Some(load(&roots_records())), none).unwrap();
    let bank = search(&explorer, "bank", deep);
    assert_eq!(bank.exhausted, Some(WordLimit::Work));
    assert!(bank.hits.is_empty() && bank.total.is_none(), "{bank:?}");
}

#[test]
fn a_word_with_more_pronunciations_than_an_explorer_holds_is_refused_not_copied_into_every_reason() {
    let variants = |n: usize| {
        let mut records: Vec<Value> = (0..n).map(|_| pron("record", None, "R EH1 K ER0 D")).collect();
        records.push(derivation("record", "noun", "record", "verb", "conversion", None));
        records
    };

    // Positive control: at the bound, every variant is evidence.
    let explorer = WordExplorer::new(family_catalog(), Some(load(&variants(MAX_WORD_PRONUNCIATIONS)))).unwrap();
    let record = search(&explorer, "record", WordMode::Derivations);
    let WordReason::Derivation { query_pronunciations, .. } = &hit(&record, "record").reasons[0] else { panic!() };
    assert_eq!(query_pronunciations.len(), MAX_WORD_PRONUNCIATIONS);

    match WordExplorer::new(family_catalog(), Some(load(&variants(MAX_WORD_PRONUNCIATIONS + 1)))) {
        Err(WordError::TooLarge { limit: WordLimit::ListItems, .. }) => {}
        other => panic!("one variant past the bound should be refused: {other:?}"),
    }
}

// ---- roots ------------------------------------------------------------------------------------------------------

fn roots_records() -> Vec<Value> {
    vec![
        origin("en:bank#1", "en", "bank", Some("bank")),
        origin("en:bank#2", "en", "bank", Some("bank")),
        origin("en:bench", "en", "bench", Some("bench")),
        origin("it:banca", "it", "banca", None),
        origin("ang:benc", "ang", "benc", None),
        origin("gem:*bankiz", "gem-pro", "*bankiz", None),
        origin("non:bakki", "non", "bakki", None),
        etymon("en:bank#1", "it:banca", "borrowed", false),
        etymon("it:banca", "gem:*bankiz", "borrowed", false),
        etymon("en:bench", "ang:benc", "inherited", false),
        etymon("ang:benc", "gem:*bankiz", "inherited", false),
        etymon("en:bank#2", "non:bakki", "borrowed", false),
        origin("en:car", "en", "car", Some("car")),
        origin("en:chariot", "en", "chariot", Some("chariot")),
        origin("en:carpet", "en", "carpet", Some("carpet")),
        origin("fro:chariot", "fro", "chariot", None),
        origin("la:carrus", "la", "carrus", None),
        origin("la:carpere", "la", "carpere", None),
        etymon("en:car", "la:carrus", "borrowed", false),
        etymon("en:chariot", "fro:chariot", "borrowed", false),
        etymon("fro:chariot", "la:carrus", "derived", true),
        etymon("en:carpet", "la:carpere", "derived", false),
        // A cycle in the source must end the walk, not hang it.
        origin("en:loopa", "en", "loopa", Some("loopa")),
        origin("en:loopb", "en", "loopb", Some("loopb")),
        etymon("en:loopa", "x:a", "unknown", false),
        etymon("x:a", "x:b", "unknown", false),
        etymon("x:b", "x:a", "unknown", false),
        etymon("en:loopb", "x:b", "unknown", false),
        // An ancestor no origin record declares.
        origin("en:mystery", "en", "mystery", Some("mystery")),
        origin("en:enigma", "en", "enigma", Some("enigma")),
        etymon("en:mystery", "zz:unknown", "derived", false),
        etymon("en:enigma", "zz:unknown", "derived", false),
        // Five edges up on one side, one on the other.
        origin("en:deep", "en", "deep", Some("deep")),
        origin("en:shallow", "en", "shallow", Some("shallow")),
        etymon("en:deep", "x:l1", "inherited", false),
        etymon("x:l1", "x:l2", "inherited", false),
        etymon("x:l2", "x:l3", "inherited", false),
        etymon("x:l3", "x:l4", "inherited", false),
        etymon("x:l4", "x:root", "inherited", false),
        etymon("en:shallow", "x:root", "inherited", false),
        // A modern family edge, which is not an etymology.
        origin("en:possible", "en", "possible", Some("possible")),
        origin("la:possibilis", "la", "possibilis", None),
        etymon("en:possible", "la:possibilis", "borrowed", false),
        derivation("possible", "adj", "possibility", "noun", "suffix", Some("-ity")),
    ]
}

fn roots_catalog() -> Vec<WordCatalogEntry> {
    catalog(&[
        "bank",
        "banker",
        "bench",
        "car",
        "chariot",
        "carpet",
        "loopa",
        "loopb",
        "mystery",
        "enigma",
        "deep",
        "shallow",
        "possible",
        "possibility",
    ])
}

fn shared(h: &WordHit) -> (&OriginNode, &[OriginStep], &[OriginStep]) {
    match &h.reasons[0] {
        WordReason::SharedOrigin { ancestor, query_path, hit_path } => {
            (ancestor, query_path.as_slice(), hit_path.as_slice())
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn roots_follow_the_etymology_graph_with_paths_homographs_and_limits() {
    let explorer = WordExplorer::new(roots_catalog(), Some(load(&roots_records()))).unwrap();
    let deep = WordMode::Roots { max_depth: MAX_ROOT_DEPTH };

    let bank = search(&explorer, "bank", deep);
    assert_eq!(heads(&bank), ["bench"]);
    let (ancestor, query_path, hit_path) = shared(hit(&bank, "bench"));
    assert_eq!(ancestor.id, "gem:*bankiz");
    assert_eq!(ancestor.language.as_deref(), Some("gem-pro"));
    assert_eq!(query_path.first().map(|s| s.child.id.as_str()), Some("en:bank#1"), "which homograph is named");
    assert_eq!(query_path.len(), 2);
    assert_eq!(hit_path.iter().map(|s| s.relation).collect::<Vec<_>>(), [EtymonRelation::Inherited; 2]);
    assert!(!heads(&bank).contains(&"banker"), "a shared spelling is no evidence of a shared root");

    let car = search(&explorer, "car", deep);
    assert_eq!(heads(&car), ["chariot"]);
    let (ancestor, _, hit_path) = shared(hit(&car, "chariot"));
    assert_eq!(ancestor.id, "la:carrus");
    assert!(hit_path.iter().any(|s| s.uncertain), "the source's doubt is kept");
    assert!(!heads(&car).contains(&"carpet"));

    assert_eq!(heads(&search(&explorer, "loopa", deep)), ["loopb"], "a cycle ends");
    let mystery = search(&explorer, "mystery", deep);
    let (ancestor, ..) = shared(hit(&mystery, "enigma"));
    assert_eq!(*ancestor, OriginNode { id: "zz:unknown".into(), language: None, form: None });

    let short = search(&explorer, "deep", WordMode::Roots { max_depth: 4 });
    assert_eq!(short.status, WordStatus::Answered);
    assert!(short.hits.is_empty(), "the common ancestor is five edges up");
    assert_eq!(heads(&search(&explorer, "deep", WordMode::Roots { max_depth: 5 })), ["shallow"]);
}

#[test]
fn roots_are_history_not_the_modern_family() {
    let explorer = WordExplorer::new(roots_catalog(), Some(load(&roots_records()))).unwrap();
    let deep = WordMode::Roots { max_depth: MAX_ROOT_DEPTH };

    assert_eq!(heads(&search(&explorer, "car", deep)), ["chariot"], "positive control");
    let possible = search(&explorer, "possible", deep);
    assert_eq!(possible.status, WordStatus::Answered);
    assert!(!heads(&possible).contains(&"possibility"), "a derivation edge is not an etymology");
    let possibility = search(&explorer, "possibility", deep);
    assert_eq!(possibility.status, WordStatus::QueryUnknown { data: WordData::Origins });

    // And the other way: etymology is not a family.
    let family = search(&explorer, "car", WordMode::Derivations);
    assert_eq!(family.status, WordStatus::QueryUnknown { data: WordData::Derivations });
    let bare = WordExplorer::new(roots_catalog(), Some(load(&family_records()))).unwrap();
    assert_eq!(search(&bare, "car", deep).status, WordStatus::NoData { data: WordData::Origins });
}

#[test]
fn a_graph_walk_past_its_budget_says_so() {
    let budget = WordBudget { max_comparisons: WordBudget::default().max_comparisons, max_graph_nodes: 2 };
    let explorer = WordExplorer::with_budget(roots_catalog(), Some(load(&roots_records())), budget).unwrap();
    let page = search(&explorer, "deep", WordMode::Roots { max_depth: MAX_ROOT_DEPTH });
    assert_eq!(page.exhausted, Some(WordLimit::GraphNodes));
    assert_eq!(page.total, None);
}

// ---- no pack ----------------------------------------------------------------------------------------------------

#[test]
fn without_a_pack_spelling_modes_answer_and_lexical_modes_say_what_is_missing() {
    let explorer = WordExplorer::new(family_catalog(), None).unwrap();
    assert_eq!(heads(&search(&explorer, "ible", WordMode::EndsWith)), ["impossible", "possible"]);
    assert_eq!(heads(&search(&explorer, "hott", WordMode::Fuzzy { max_distance: 1 })), ["hot"]);
    for (mode, data) in [
        (WordMode::Rhyme, WordData::Pronunciation),
        (WordMode::Inflections, WordData::Forms),
        (WordMode::Derivations, WordData::Derivations),
        (WordMode::Roots { max_depth: 3 }, WordData::Origins),
    ] {
        let page = search(&explorer, "possible", mode);
        assert_eq!(page.status, WordStatus::NoData { data }, "{mode:?}");
        assert!(page.hits.is_empty() && page.total.is_none());
    }
    let stats = explorer.stats();
    assert!(stats.sources.is_empty());
    assert_eq!(stats.headwords, 13);
}

// ---- the pack ---------------------------------------------------------------------------------------------------

fn refused(text: &str) -> WordError {
    WordLexicon::from_jsonl(text.as_bytes()).expect_err(text)
}

fn corrupt_line(error: WordError) -> u64 {
    match error {
        WordError::Corrupt { line, .. } => line,
        other => panic!("not corrupt: {other:?}"),
    }
}

#[test]
fn a_pack_loads_its_records_and_sources() {
    let lexicon = load(&roots_records());
    let explorer = WordExplorer::new(roots_catalog(), Some(lexicon.clone())).unwrap();
    let stats = explorer.stats();
    assert_eq!(stats.origins, 21);
    assert_eq!(stats.etymons, 22);
    assert_eq!(stats.derivations, 1);
    assert_eq!(stats.sources.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["cmu", "wikt", "ety"]);
    assert_eq!(stats.sources[0].attribution, "Written by the xdict-core test suite");
    assert_eq!(lexicon.header().language, "en");

    // The plain records are the same schema.
    let again = WordLexicon::from_records(lexicon.header().clone(), lexicon.records().to_vec()).unwrap();
    assert_eq!(&again, lexicon.as_ref());
}

#[test]
fn a_damaged_pack_is_refused_with_its_line() {
    let good = pron("nation", None, "N EY1 SH AH0 N");

    assert_eq!(corrupt_line(refused(&jsonl(std::slice::from_ref(&good)))), 1, "no header");
    assert!(matches!(refused(""), WordError::Corrupt { .. }), "empty");
    let mut wrong_schema = header();
    wrong_schema["schema"] = json!("something-else");
    assert_eq!(corrupt_line(refused(&jsonl(&[wrong_schema]))), 1);
    let mut future = header();
    future["version"] = json!(WORD_PACK_VERSION + 1);
    assert!(matches!(
        refused(&jsonl(&[future])),
        WordError::UnsupportedVersion { found, supported: WORD_PACK_VERSION, .. } if found == WORD_PACK_VERSION + 1
    ));
    let mut unlicensed = header();
    unlicensed["sources"][0]["licence"] = json!("");
    assert_eq!(corrupt_line(refused(&jsonl(&[unlicensed]))), 1, "a source without its licence");

    assert_eq!(corrupt_line(refused(&with_header(&[good.clone(), json!({"type": "definition", "word": "x"})]))), 3);
    assert_eq!(corrupt_line(refused(&format!("{}{{not json\n", with_header(std::slice::from_ref(&good))))), 3);
    let unstressed = pron("nation", None, "N EY SH AH0 N");
    assert_eq!(corrupt_line(refused(&with_header(&[unstressed]))), 2, "a vowel without stress");
    let foreign = pron("nation", None, "N EY1 QQ AH0 N");
    assert_eq!(corrupt_line(refused(&with_header(&[foreign]))), 2, "not ARPAbet");
    let mut stranger = good.clone();
    stranger["source"] = json!("nope");
    assert_eq!(corrupt_line(refused(&with_header(&[stranger]))), 2, "a source the header does not name");
    let lopsided = aligned(
        derivation("possible", "adj", "impossible", "adj", "prefix", Some("im-")),
        stem(POSSIBLE, (0, 3), IMPOSSIBLE, (1, 3)),
    );
    assert_eq!(corrupt_line(refused(&with_header(&[lopsided]))), 2, "stem ranges of different lengths");
    let outside = aligned(
        derivation("possible", "adj", "impossible", "adj", "prefix", Some("im-")),
        stem(POSSIBLE, (0, 3), IMPOSSIBLE, (2, 5)),
    );
    assert_eq!(corrupt_line(refused(&with_header(&[outside]))), 2, "a stem range past the vowels");

    // Positive control: the good record alone loads.
    let lexicon = WordLexicon::from_jsonl(with_header(&[good]).as_bytes()).unwrap();
    assert_eq!(lexicon.records().len(), 1);
}

#[test]
fn a_pack_past_its_bounds_is_refused_not_truncated() {
    let limits = LexiconLimits {
        max_line_bytes: 400,
        max_records: 2,
        max_string_chars: 64,
        max_list_items: 8,
        ..LexiconLimits::default()
    };
    let load_with = |records: &[Value]| WordLexicon::from_jsonl_with_limits(with_header(records).as_bytes(), limits);
    let too_large = |result: Result<WordLexicon, WordError>| match result {
        Err(WordError::TooLarge { limit, .. }) => limit,
        other => panic!("not too large: {other:?}"),
    };
    let mut wide = header();
    wide["sources"] = json!([pack_source("cmu")]);
    let short_header = |records: &[Value]| {
        let mut lines = vec![wide.clone()];
        lines.extend_from_slice(records);
        WordLexicon::from_jsonl_with_limits(jsonl(&lines).as_bytes(), limits)
    };

    assert!(short_header(&[pron("tone", None, "T OW1 N")]).is_ok(), "positive control");
    assert_eq!(too_large(load_with(&[])), WordLimit::LineBytes, "the three-source header is over 400 bytes");
    let three = [pron("a", None, "AH0"), pron("b", None, "B IY1"), pron("c", None, "S IY1")];
    assert_eq!(too_large(short_header(&three)), WordLimit::Records);
    assert_eq!(too_large(short_header(&[pron(&"x".repeat(65), None, "EH1 K S")])), WordLimit::StringChars);
    assert_eq!(too_large(short_header(&[pron("long", None, &["AH0"; 9].join(" "))])), WordLimit::ListItems);
}

// ---- final regressions ------------------------------------------------------------------------------------------

#[test]
fn final_fuzzy_exact_survives_a_partial_scan() {
    let mut words: Vec<String> = (0..10).map(|i| format!("q{i}")).collect();
    words.push("abc".into());
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let fuzzy = WordMode::Fuzzy { max_distance: 1 };

    // Positive control: the default budget scans everything; no two-letter q-word is within one edit of abc.
    let full = search(&WordExplorer::new(catalog(&words), None).unwrap(), "abc", fuzzy);
    assert_eq!(heads(&full), ["abc"]);
    assert_eq!((full.total, full.exhausted), (Some(1), None));

    // Ten length-2 candidates cost 12 cells each, 120 in all, before the length-3 run is reached: the exact
    // spelling is an index probe and must be in the answer however the scan is cut.
    let budget = WordBudget { max_comparisons: 100, ..WordBudget::default() };
    let tight = WordExplorer::with_budget(catalog(&words), None, budget).unwrap();
    let cut = search(&tight, "abc", fuzzy);
    assert_eq!(cut.exhausted, Some(WordLimit::Work), "{cut:?}");
    assert_eq!(cut.total, None, "a cut answer is never presented as complete");
    assert_eq!(heads(&cut), ["abc"], "the exact spelling survives a partial scan");
    assert_eq!(hit(&cut, "abc").reasons, [WordReason::Exact]);
}

#[test]
fn final_inflection_seeding_is_metered() {
    let class_tags: Vec<String> = (0..100).map(|i| format!("class{i}")).collect();
    let mut records: Vec<Value> =
        class_tags.iter().map(|tag| form("ran", "run", "verb", &["past", tag.as_str()])).collect();
    records.push(form("running", "run", "verb", &["present", "participle"]));
    let words = ["run", "ran", "running"];

    // Positive control: the default budget reaches the lemma and the other form.
    let explorer = WordExplorer::new(catalog(&words), Some(load(&records))).unwrap();
    let ran = search(&explorer, "ran", WordMode::Inflections);
    assert_eq!(ran.status, WordStatus::Answered);
    assert_eq!(heads(&ran), ["run", "running"]);
    assert_eq!((ran.total, ran.exhausted), (Some(2), None));

    // A hundred query roles in one paradigm are work: ten comparisons cannot build them for free.
    let budget = WordBudget { max_comparisons: 10, ..WordBudget::default() };
    let tight = WordExplorer::with_budget(catalog(&words), Some(load(&records)), budget).unwrap();
    let cut = search(&tight, "ran", WordMode::Inflections);
    assert_eq!(cut.exhausted, Some(WordLimit::Work), "{cut:?}");
    assert_eq!(cut.total, None);
    assert!(cut.hits.is_empty(), "the budget is spent on query roles before enumerating hits");
}

#[test]
fn final_unstressed_only_query_has_no_known_rime() {
    let pack = load(&[
        pron("the", None, "DH AH0"),
        pron("thee", None, "DH IY1"),
        pron("bough", None, "B AW1"),
        pron("see", None, "S IY1"),
    ]);
    let explorer = WordExplorer::new(catalog(&["the", "thee", "bough", "see"]), Some(pack)).unwrap();

    // Only an unstressed vowel: no rime is known, which is not "no rhyme".
    let the = search(&explorer, "the", WordMode::Rhyme);
    assert_eq!(the.status, WordStatus::QueryUnknown { data: WordData::Pronunciation }, "{the:?}");
    assert!(the.hits.is_empty());
    assert_eq!(the.total, None, "an unknown query claims no total of zero");

    // A stressed query with no rhyme in the catalog is a known answer of none.
    let bough = search(&explorer, "bough", WordMode::Rhyme);
    assert_eq!(bough.status, WordStatus::Answered);
    assert!(bough.hits.is_empty());
    assert_eq!(bough.total, Some(0));

    // And a stressed one with a rhyme answers it.
    assert_eq!(heads(&search(&explorer, "thee", WordMode::Rhyme)), ["see"]);
}

/// Pronunciation variants of `seed`, each a source-distinct record (its own dialect label).
const EVIDENCE_VARIANTS: usize = 64;
/// IPA segments per variant, each `EVIDENCE_SEGMENT_CHARS` scalars: 12.8 KB a variant, 0.8 MB the word.
const EVIDENCE_SEGMENTS: usize = 64;
const EVIDENCE_SEGMENT_CHARS: usize = 200;
/// The proposed bound on the evidence one answer retains.
const PROPOSED_EVIDENCE_CAP: usize = 16 * 1024 * 1024;

fn evidence_records(neighbors: usize) -> Vec<Value> {
    let segment = "a".repeat(EVIDENCE_SEGMENT_CHARS);
    let phonemes = vec![segment.as_str(); EVIDENCE_SEGMENTS];
    let mut records: Vec<Value> = (0..EVIDENCE_VARIANTS)
        .map(|i| {
            json!({
                "type": "pronunciation",
                "word": "seed",
                "pos": null,
                "system": "ipa",
                "phonemes": phonemes,
                "dialect": format!("x-variant-{i:02}"),
                "source": "wikt",
            })
        })
        .collect();
    records
        .extend((0..neighbors).map(|i| derivation("seed", "noun", &format!("n{i:03}"), "noun", "suffix", Some("-x"))));
    records
}

fn evidence_catalog(neighbors: usize) -> Vec<WordCatalogEntry> {
    let mut words = vec!["seed".to_owned()];
    words.extend((0..neighbors).map(|i| format!("n{i:03}")));
    catalog(&words.iter().map(String::as_str).collect::<Vec<_>>())
}

fn evidence_bytes(page: &WordPage) -> usize {
    page.hits
        .iter()
        .flat_map(|h| &h.reasons)
        .map(|r| match r {
            WordReason::Derivation { query_pronunciations, hit_pronunciations, .. } => query_pronunciations
                .iter()
                .chain(hit_pronunciations)
                .flat_map(|p| &p.phonemes)
                .map(String::len)
                .sum::<usize>(),
            other => panic!("{other:?}"),
        })
        .sum()
}

fn assert_full_evidence(page: &WordPage) {
    for h in &page.hits {
        assert!(h.headword.starts_with('n'), "{} is not a neighbour", h.headword);
        let WordReason::Derivation { query_pronunciations, .. } = &h.reasons[0] else { panic!() };
        assert_eq!(query_pronunciations.len(), EVIDENCE_VARIANTS, "a kept hit keeps all its evidence");
    }
}

#[test]
fn final_evidence_memory_is_bounded_across_one_answer() {
    const { assert!(EVIDENCE_VARIANTS < MAX_WORD_PRONUNCIATIONS, "the pack is within the per-word variant bound") };

    // Positive control: a small family answers normally, all its evidence kept.
    let small = WordExplorer::new(evidence_catalog(3), Some(load(&evidence_records(3)))).unwrap();
    let page = search(&small, "seed", WordMode::Derivations);
    assert_eq!(page.status, WordStatus::Answered);
    assert_eq!(heads(&page), ["n000", "n001", "n002"]);
    assert_eq!((page.total, page.exhausted), (Some(3), None));
    assert_full_evidence(&page);

    // About 1 MB of pack; copied into 300 reasons it would be about 250 MB.
    let records = evidence_records(300);
    assert!(with_header(&records).len() < 2 * 1024 * 1024, "the input stays small");
    let wide = WordExplorer::new(evidence_catalog(300), Some(load(&records))).unwrap();
    let page = search(&wide, "seed", WordMode::Derivations);
    assert_eq!(page.status, WordStatus::Answered);
    assert_eq!(page.exhausted, Some(WordLimit::TotalBytes), "hits {}", page.hits.len());
    assert_eq!(page.total, None);
    assert!(!page.hits.is_empty(), "what fit is answered");
    assert!(page.hits.len() < 300);
    assert_full_evidence(&page);
    assert!(evidence_bytes(&page) <= PROPOSED_EVIDENCE_CAP, "{} bytes retained", evidence_bytes(&page));
}

fn bytes64(n: usize) -> u64 {
    u64::try_from(n).unwrap()
}

fn pronunciation_string_bytes(p: &PronunciationRecord) -> u64 {
    let strings = [p.word.len(), p.pos.as_ref().map_or(0, String::len), p.dialect.as_ref().map_or(0, String::len)];
    bytes64(strings.iter().sum::<usize>() + p.phonemes.iter().map(String::len).sum::<usize>() + p.source.len())
}

fn header_string_bytes(h: &LexiconHeader) -> u64 {
    let sources: usize = h
        .sources
        .iter()
        .map(|s| {
            s.id.len()
                + s.name.len()
                + s.url.len()
                + s.version.len()
                + s.sha256.len()
                + s.licence.len()
                + s.attribution.len()
                + s.coverage.as_ref().map_or(0, String::len)
        })
        .sum();
    bytes64(h.language.len() + sources)
}

/// Three records of one length, long enough that half of one is a clear margin.
fn byte_records() -> Vec<Value> {
    (0..3).map(|i| pron(&format!("w{i}{}", "x".repeat(40)), None, "T OW1 N")).collect()
}

fn total_bytes_refused(result: Result<WordLexicon, WordError>) {
    match result {
        Err(WordError::TooLarge { limit: WordLimit::TotalBytes, .. }) => {}
        other => panic!("not refused for total bytes: {other:?}"),
    }
}

#[test]
fn final_loader_bytes_jsonl_caps_the_cumulative_records_after_the_header() {
    let records = byte_records();
    let header_line = bytes64(format!("{}\n", header()).len());
    let record_line = bytes64(format!("{}\n", records[0]).len());
    assert!(records.iter().all(|r| bytes64(format!("{r}\n").len()) == record_line));
    // The header and one record fit; a second record does not.
    let limits =
        LexiconLimits { max_total_bytes: header_line + record_line + record_line / 2, ..LexiconLimits::default() };
    let read = |records: &[Value], limits| WordLexicon::from_jsonl_with_limits(with_header(records).as_bytes(), limits);

    // Paired default controls: every pack here loads.
    assert_eq!(read(&records, LexiconLimits::default()).unwrap().records().len(), 3);
    assert_eq!(read(&records[..2], LexiconLimits::default()).unwrap().records().len(), 2);

    // The limit admits the header, and the header with one record.
    assert!(read(&[], limits).unwrap().records().is_empty());
    assert_eq!(read(&records[..1], limits).unwrap().records().len(), 1);
    // Past it the records, not any one line, are what is too large.
    total_bytes_refused(read(&records[..2], limits));
    total_bytes_refused(read(&records, limits));
}

#[test]
fn final_loader_bytes_plain_records_cap_their_cumulative_strings() {
    let lexicon = load(&byte_records());
    let header = lexicon.header().clone();
    let records = lexicon.records().to_vec();
    let LexiconRecord::Pronunciation(first) = &records[0] else { panic!() };
    let per_record = pronunciation_string_bytes(first);
    let same = |r: &LexiconRecord| match r {
        LexiconRecord::Pronunciation(p) => pronunciation_string_bytes(p) == per_record,
        _ => false,
    };
    assert!(records.iter().all(same));
    let limits = LexiconLimits {
        max_total_bytes: header_string_bytes(&header) + per_record + per_record / 2,
        ..LexiconLimits::default()
    };
    let take = |n: usize, limits| WordLexicon::from_records_with_limits(header.clone(), records[..n].to_vec(), limits);

    // Paired default controls.
    assert_eq!(take(3, LexiconLimits::default()).unwrap().records().len(), 3);
    assert_eq!(take(2, LexiconLimits::default()).unwrap().records().len(), 2);

    // The header alone and with one record fit; the strings of two do not.
    assert!(take(0, limits).unwrap().records().is_empty());
    assert_eq!(take(1, limits).unwrap().records().len(), 1);
    total_bytes_refused(take(2, limits));
    total_bytes_refused(take(3, limits));
}

#[test]
fn final_payload_bytes_are_work_for_duplicate_conversions() {
    let mut records = evidence_records(0);
    records.extend(std::iter::repeat_n(derivation("seed", "noun", "seed", "verb", "conversion", None), 5));
    let pack = load(&records);
    let full = WordExplorer::new(catalog(&["seed"]), Some(Arc::clone(&pack))).unwrap();
    let complete = search(&full, "seed", WordMode::Derivations);
    assert_eq!((heads(&complete), complete.total, complete.exhausted), (vec!["seed"], Some(1), None));
    let tight = WordExplorer::with_budget(
        catalog(&["seed"]),
        Some(pack),
        WordBudget { max_comparisons: 10_000, ..WordBudget::default() },
    )
    .unwrap();
    let cut = search(&tight, "seed", WordMode::Derivations);
    assert_eq!(cut.exhausted, Some(WordLimit::Work), "large evidence copies are work even when duplicate");
    assert_eq!(cut.total, None);
}

#[test]
fn final_payload_bytes_are_work_for_inflection_tags() {
    let large_tag = "a".repeat(200);
    let tags = vec![large_tag.as_str(); 64];
    let pack = load(&[form("ran", "run", "verb", &tags), form("running", "run", "verb", &["present", "participle"])]);
    let full = WordExplorer::new(catalog(&["ran", "run", "running"]), Some(Arc::clone(&pack))).unwrap();
    let complete = search(&full, "ran", WordMode::Inflections);
    assert_eq!((heads(&complete), complete.total, complete.exhausted), (vec!["run", "running"], Some(2), None));
    let tight = WordExplorer::with_budget(
        catalog(&["ran", "run", "running"]),
        Some(pack),
        WordBudget { max_comparisons: 100, ..WordBudget::default() },
    )
    .unwrap();
    let cut = search(&tight, "ran", WordMode::Inflections);
    assert_eq!(cut.exhausted, Some(WordLimit::Work), "large grammatical tags are work before copying");
    assert_eq!(cut.total, None);
    assert!(cut.hits.is_empty());
}

// ---- audit regressions (Fable, 2026-10-24) ----------------------------------------------------------------------

/// The catalog's longest kept headword and longest handle, edition or key, in UTF-8 bytes.
const CATALOG_STRING_BYTES: usize = 4 * 1024;

#[test]
fn fable_an_oversized_headword_is_skipped_and_counted_not_refused() {
    let long = "a".repeat(5_000);
    let mut entries = catalog(&["word"]);
    // Through the core a key is its own headword: the over-long key goes with the over-long headword.
    entries.push(WordCatalogEntry { headword: long.clone(), sources: vec![source("d1", "e1", &long, 0)] });
    // A skipped entry's sources are not inspected: an over-long edition beside it changes nothing.
    let (longer, edition) = (format!("{long}b"), "e".repeat(5_000));
    entries.push(WordCatalogEntry { headword: longer.clone(), sources: vec![source("d1", &edition, &longer, 0)] });

    let explorer = WordExplorer::new(entries, None).expect("an oversized headword is skipped, not refused");
    let stats = explorer.stats();
    assert_eq!((stats.headwords, stats.skipped_headwords), (1, 2), "{stats:?}");
    assert_eq!(stats.editions, ["e1"], "a skipped entry brings no edition");
    assert_eq!(heads(&search(&explorer, "word", WordMode::EndsWith)), ["word"], "the normal headword is kept");
}

#[test]
fn fable_an_overlong_source_string_on_a_normal_headword_is_refused_in_bytes() {
    let at_bound = "x".repeat(CATALOG_STRING_BYTES);
    // 2,049 scalars, 4,098 bytes: over the bound in bytes, well under it in characters.
    let over = "\u{e9}".repeat(CATALOG_STRING_BYTES / 2 + 1);
    let entry = |dict: &str, edition: &str, key: &str| WordCatalogEntry {
        headword: "word".into(),
        sources: vec![source(dict, edition, key, 0)],
    };

    // Positive control: each string at the bound is held.
    let held = WordExplorer::new(vec![entry(&at_bound, &at_bound, &at_bound)], None).unwrap();
    assert_eq!(held.stats().headwords, 1);

    let bad = [entry(&over, "e1", "word"), entry("d1", &over, "word"), entry("d1", "e1", &over)];
    for (field, bad) in ["dict", "edition", "key"].into_iter().zip(bad) {
        match WordExplorer::new(vec![bad], None) {
            Err(WordError::TooLarge { limit: WordLimit::StringBytes, .. }) => {}
            other => panic!("an over-long {field} on a normal headword should be refused as StringBytes: {other:?}"),
        }
    }
}

#[test]
fn fable_a_stated_root_relation_loads_and_is_reported_as_root() {
    let records = vec![
        origin("en:radical", "en", "radical", Some("radical")),
        origin("en:radish", "en", "radish", Some("radish")),
        origin("la:radix", "la", "radix", None),
        etymon("en:radical", "la:radix", "root", false),
        // A pack's `unknown` still loads as unknown.
        etymon("en:radish", "la:radix", "unknown", false),
    ];
    let explorer = WordExplorer::new(catalog(&["radical", "radish"]), Some(load(&records))).unwrap();

    let radical = search(&explorer, "radical", WordMode::Roots { max_depth: 1 });
    assert_eq!(heads(&radical), ["radish"]);
    let (ancestor, query_path, hit_path) = shared(hit(&radical, "radish"));
    assert_eq!(ancestor.id, "la:radix");
    assert_eq!(query_path.iter().map(|s| s.relation).collect::<Vec<_>>(), [EtymonRelation::Root]);
    assert_eq!(hit_path.iter().map(|s| s.relation).collect::<Vec<_>>(), [EtymonRelation::Unknown]);
}

#[test]
fn fable_a_fuzzy_scan_cut_short_keeps_the_closest_lengths_first() {
    let words = ["a", "b", "x", "y", "z", "abcde"];
    let fuzzy = WordMode::Fuzzy { max_distance: 3 };

    // Positive control: the default budget reaches every length; abcde is one edit away, a and b three.
    let full = search(&WordExplorer::new(catalog(&words), None).unwrap(), "abcd", fuzzy);
    assert_eq!(heads(&full), ["abcde", "a", "b"]);
    assert_eq!((full.total, full.exhausted), (Some(3), None));

    // 100 units: the exact probe takes 64; abcde costs (4 + 1) × (5 + 1) = 30 cells, each length-1 word 10. Scanned
    // shortest first, three length-1 words spend the rest and abcde is never compared; scanned by distance from the
    // query's length, abcde comes first.
    let budget = WordBudget { max_comparisons: 100, ..WordBudget::default() };
    let tight = WordExplorer::with_budget(catalog(&words), None, budget).unwrap();
    let cut = search(&tight, "abcd", fuzzy);
    assert_eq!(cut.exhausted, Some(WordLimit::Work), "{cut:?}");
    assert_eq!(cut.total, None);
    assert_eq!(heads(&cut).first(), Some(&"abcde"), "the closest length is compared first: {:?}", heads(&cut));
    assert_eq!(hit(&cut, "abcde").reasons, [WordReason::Spelling { distance: 1 }]);
}

#[test]
fn fable_an_empty_origin_path_means_the_ancestor_is_that_word_itself() {
    let records = vec![
        origin("en:bank", "en", "bank", Some("bank")),
        origin("en:banker", "en", "banker", Some("banker")),
        etymon("en:banker", "en:bank", "derived", false),
    ];
    let explorer = WordExplorer::new(catalog(&["bank", "banker"]), Some(load(&records))).unwrap();
    let deep = WordMode::Roots { max_depth: MAX_ROOT_DEPTH };

    // A direct descendant: the shared ancestor is the query's own node, so the query's path is empty.
    let bank = search(&explorer, "bank", deep);
    assert_eq!(heads(&bank), ["banker"]);
    let (ancestor, query_path, hit_path) = shared(hit(&bank, "banker"));
    assert_eq!(ancestor.id, "en:bank");
    assert!(query_path.is_empty(), "{query_path:?}");
    assert_eq!(hit_path.len(), 1);
    assert_eq!((hit_path[0].child.id.as_str(), hit_path[0].parent.id.as_str()), ("en:banker", "en:bank"));

    // A direct ancestor that is itself a headword: the hit's path is the empty one.
    let banker = search(&explorer, "banker", deep);
    assert_eq!(heads(&banker), ["bank"]);
    let (ancestor, query_path, hit_path) = shared(hit(&banker, "bank"));
    assert_eq!(ancestor.id, "en:bank");
    assert_eq!(query_path.len(), 1);
    assert!(hit_path.is_empty(), "{hit_path:?}");
}

/// The most reasons one hit carries, as `WordHit::reasons` documents it.
const HIT_REASONS: usize = 64;

#[test]
fn fable_a_hit_keeps_at_most_64_reasons_and_the_total_counts_headwords() {
    let variants = |n: usize| {
        let mut records: Vec<Value> = (0..n)
            .map(|i| {
                let mut p = pron("seed", None, "S IY1 D");
                p["dialect"] = json!(format!("x-variant-{i:02}"));
                p
            })
            .collect();
        records.push(pron("need", None, "N IY1 D"));
        WordExplorer::new(catalog(&["seed", "need"]), Some(load(&records))).unwrap()
    };

    // Positive control: under the cap, every distinct witness is a reason.
    let few = search(&variants(3), "seed", WordMode::Rhyme);
    assert_eq!(hit(&few, "need").reasons.len(), 3);

    // One past the cap: the hit stays, with 64 reasons, and the page is still exhaustive over headwords.
    let many = search(&variants(HIT_REASONS + 1), "seed", WordMode::Rhyme);
    assert_eq!(heads(&many), ["need"]);
    assert_eq!(hit(&many, "need").reasons.len(), HIT_REASONS);
    assert_eq!((many.total, many.exhausted), (Some(1), None), "the total counts headwords, not their witnesses");
}
