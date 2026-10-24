//! The reverse-example API through the core (ADR-0031, plan-reverse-examples WI-2–WI-4): the extractor over entries the
//! role pass classified, the store built and read through `IndexStorage`, the query's dedupe, ranking and offsets, and
//! the rebuild rules. The entries are written here, no dictionary's.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

const SHEET: &str = ".hw { font-weight: bold }\n.d { font-style: italic }\n.x { font-style: italic }\n.tr { color: #333 }\n.s { display: block }";

fn run() -> W {
    W::text(
        "run",
        r#"<div class="e"><b class="hw">run</b><div class="s"><b>1.</b> <span class="d">to move fast on your feet</span></div><div class="s"><b>2.</b> <i class="x">She runs to school every day.</i><span class="tr">她每天跑步去学校。</span></div></div>"#,
    )
}

fn consider() -> W {
    W::text(
        "consider",
        r#"<div class="e"><b class="hw">consider</b><div class="s"><b>1.</b> <span class="d">to think about something</span></div><div class="s"><b>2.</b> <i class="x">Who could have considered such a possibility?</i><span class="tr">谁居然会想到这种可能性？</span></div></div>"#,
    )
}

fn take() -> W {
    W::text(
        "take",
        r#"<div class="e"><b class="hw">take</b><div class="s"><b>1.</b> <span class="d">to remove</span></div><div class="s"><b>2.</b> <span class="d">to leave the ground</span> <span class="lb">informal</span> <i class="x">take it easy</i> <span class="tr">放轻松</span></div></div>"#,
    )
}

fn chinese() -> W {
    W::text(
        "Chinese",
        r#"<div class="e"><b class="hw">Chinese</b><div class="s"><b>1.</b> <span class="d">the language</span></div><div class="s"><b>2.</b> <i class="x">Chinese is spoken here.</i><span class="tr">这里说汉语。</span></div></div>"#,
    )
}

fn pure() -> W {
    W::text(
        "pure",
        r#"<div class="e"><b class="hw">pure</b><div class="s"><b>1.</b> <span class="d">not mixed</span></div></div>"#,
    )
}

fn phrase_pair() -> W {
    W::text(
        "phrase",
        r#"<div class="e"><b class="hw">phrase</b><div class="s"><b>1.</b> <span class="d">a phrase</span></div><div class="s"><b>2.</b> <i class="x">take it easy</i><span class="tr">放轻松</span></div></div>"#,
    )
}

fn sentence_pair() -> W {
    W::text(
        "sentence",
        r#"<div class="e"><b class="hw">sentence</b><div class="s"><b>1.</b> <span class="d">a sentence</span></div><div class="s"><b>2.</b> <i class="x">Take it easy.</i><span class="tr">放轻松吧。</span></div></div>"#,
    )
}

/// One more distinct pair than the scan's own bound, each carrying the query once.
fn many() -> Vec<W> {
    (0..10_001)
        .map(|i| {
            W::text(
                &format!("m{i:05}"),
                &format!(
                    r#"<div class="e"><b class="hw">m{i:05}</b><div class="s"><b>1.</b> <span class="d">a thing</span></div><div class="s"><b>2.</b> <i class="x">A sentence number {i}.</i><span class="tr">的。</span></div></div>"#
                ),
            )
        })
        .collect()
}

/// An abbreviation entry whose English is its expansion, not an example.
fn abbreviation() -> W {
    W::text(
        "AAAL",
        r#"<div class="e"><b class="hw">AAAL</b><div class="s"><b>1.</b> <i class="x">American Academy of Arts and Letters</i><span class="tr">美国艺术和文学学会</span></div></div>"#,
    )
}

/// One pair whose Chinese carries the query twice.
fn repeat_pair() -> W {
    W::text(
        "repeat",
        r#"<div class="e"><b class="hw">repeat</b><div class="s"><b>1.</b> <span class="d">again</span></div><div class="s"><b>2.</b> <i class="x">Who could have considered such a possibility?</i><span class="tr">谁居然会想到这种可能性？居然。</span></div></div>"#,
    )
}

/// 100 records, Chinese only in the 91st: the 64 spread sample points do not include it.
fn sparse() -> Vec<W> {
    let mut entries: Vec<W> = (0..100)
        .map(|i| {
            W::text(
                &format!("w{i:03}"),
                &format!(
                    r#"<div class="e"><b class="hw">w{i:03}</b><div class="s"><b>1.</b> <span class="d">a word</span></div></div>"#
                ),
            )
        })
        .collect();
    entries[90] = W::text(
        "w090",
        r#"<div class="e"><b class="hw">w090</b><div class="s"><b>1.</b> <span class="d">a word</span></div><div class="s"><b>2.</b> <i class="x">Who could have considered such a possibility?</i><span class="tr">谁居然会想到这种可能性？</span></div></div>"#,
    );
    entries
}

fn short_pair() -> W {
    W::text(
        "short",
        r#"<div class="e"><b class="hw">short</b><div class="s"><b>1.</b> <span class="d">a greeting</span></div><div class="s"><b>2.</b> <i class="x">Hello to you.</i><span class="tr">你好。</span></div></div>"#,
    )
}

fn long_pair() -> W {
    W::text(
        "long",
        r#"<div class="e"><b class="hw">long</b><div class="s"><b>1.</b> <span class="d">a remark</span></div><div class="s"><b>2.</b> <i class="x">The weather is very nice today.</i><span class="tr">今天天气很好。</span></div></div>"#,
    )
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-examples-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn at(&self, name: &str) -> Location {
        Location::Path { path: self.0.join(name).to_string_lossy().into() }
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn package(dir: &Scratch, name: &str, entries: &[W]) -> Package {
    std::fs::write(dir.0.join(format!("{name}.mdx")), writer::write(&Spec::mdx(), entries).unwrap()).unwrap();
    std::fs::write(dir.0.join(format!("{name}.css")), SHEET).unwrap();
    Package { mdx: dir.at(&format!("{name}.mdx")), mdd: vec![], sidecars: vec![dir.at(&format!("{name}.css"))] }
}

fn core() -> Core {
    Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap()
}

fn opened(core: &Core, package: Package) -> (String, String) {
    core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, edition, .. } => (dict, edition),
        other => panic!("not open: {other:?}"),
    }
}

/// A `ByteSource` over bytes, for the index storage a shell would supply.
struct Bytes(Vec<u8>);

impl ByteSource for Bytes {
    fn size(&self) -> u64 {
        self.0.len() as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        let start = usize::try_from(offset).unwrap();
        let end = start.checked_add(len as usize).unwrap();
        self.0.get(start..end).map(<[u8]>::to_vec).ok_or_else(|| CoreError::Io {
            kind: IoKind::ShortRead,
            detail: "a short read from the recording store".into(),
        })
    }
    fn identity(&self) -> Option<FileIdentity> {
        None
    }
}

/// The storage a shell supplies: what was written, by name.
#[derive(Default)]
struct Recording {
    written: Mutex<HashMap<String, Vec<u8>>>,
}

impl Recording {
    fn bytes(&self, name: &str) -> Option<Vec<u8>> {
        self.written.lock().unwrap().get(name).cloned()
    }
    fn examples_names(&self) -> Vec<String> {
        self.written.lock().unwrap().keys().filter(|name| name.starts_with("examples-")).cloned().collect()
    }
    fn put_raw(&self, name: &str, bytes: Vec<u8>) {
        self.written.lock().unwrap().insert(name.to_owned(), bytes);
    }
    fn remove(&self, name: &str) {
        self.written.lock().unwrap().remove(name);
    }
}

impl IndexStorage for Recording {
    fn get(&self, name: &str) -> Result<Option<Arc<dyn ByteSource>>, CoreError> {
        Ok(self.bytes(name).map(|bytes| Arc::new(Bytes(bytes)) as Arc<dyn ByteSource>))
    }
    fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), CoreError> {
        self.put_raw(name, bytes);
        Ok(())
    }
}

fn core_with(storage: Arc<Recording>) -> Core {
    Core::with_index_storage(Config { client_protocol: PROTOCOL, ..Config::default() }, storage).unwrap()
}

#[test]
fn a_query_before_the_build_says_not_ready_and_after_it_finds_the_pair() {
    let dir = Scratch::new("query");
    let package = package(&dir, "noad", &[run(), consider(), take()]);
    let core = core();
    let (dict, edition) = opened(&core, package);

    let before = core.examples("跑步".into(), vec![dict.clone()], 100).unwrap();
    assert!(before.hits.is_empty());
    assert_eq!(before.not_ready, vec![dict.clone()], "a dictionary without a store is not an error");

    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(!built.cached);
    assert!(!built.no_chinese);
    assert_eq!(built.entries, 3);
    assert!(built.pairs >= 3, "{built:?}");

    let after = core.examples("跑步".into(), vec![dict.clone()], 100).unwrap();
    assert!(after.not_ready.is_empty());
    assert_eq!(after.hits.len(), 1);
    let hit = &after.hits[0];
    assert_eq!(hit.english, "She runs to school every day.");
    assert_eq!(hit.chinese, "她每天跑步去学校。");
    assert_eq!(hit.chinese.get(hit.start as usize..(hit.start + hit.len) as usize), Some("跑步"));
    assert!(hit.sentence);
    assert_eq!(hit.sources.len(), 1);
    assert_eq!(hit.sources[0].entry.key, "run");
    assert_eq!(hit.sources[0].entry.edition, edition);
    assert_eq!(hit.sources[0].entry.occurrence, 0);

    let again = core.examples_build(dict, &NoProgress).unwrap();
    assert!(again.cached, "{again:?}");
    assert_eq!(again.pairs, built.pairs);
}

#[test]
fn a_page_walks_every_pair_in_store_order() {
    let dir = Scratch::new("page");
    let package = package(&dir, "noad", &[run(), consider(), take(), short_pair()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert_eq!(built.roles + built.fallback, built.pairs, "{built:?}");
    let page = core.examples_page(dict.clone(), 0, 1000).unwrap();
    assert_eq!(page.total, built.pairs);
    assert_eq!(page.pairs.len(), built.pairs as usize);
    assert!(
        page.pairs
            .iter()
            .all(|pair| { !pair.english.is_empty() && !pair.chinese.is_empty() && !pair.entry.key.is_empty() })
    );
    let second = core.examples_page(dict, 1, 1).unwrap();
    assert_eq!(second.pairs.len(), 1);
    assert_eq!(second.pairs[0], page.pairs[1]);
}

#[test]
fn a_pair_that_matches_twice_is_one_hit_with_one_source() {
    let core = core();
    let scratch = Scratch::new("repeat");
    let (dict, _) = opened(&core, package(&scratch, "repeat", &[repeat_pair()]));
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert_eq!(built.pairs, 1);
    let examples = core.examples("居然".into(), vec![dict], 10).unwrap();
    assert_eq!(examples.hits.len(), 1, "a pair shown once, though its Chinese holds the query twice");
    assert_eq!(examples.hits.first().map(|hit| hit.sources.len()), Some(1));
}

#[test]
fn the_chinese_scan_finds_what_the_sample_missed() {
    let core = core();
    let scratch = Scratch::new("sparse");
    let (dict, _) = opened(&core, package(&scratch, "sparse", &sparse()));
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(!built.no_chinese, "record 90 holds Chinese, though no sample point reads it");
    assert_eq!(built.pairs, 1);
}

#[test]
fn a_traditional_query_finds_simplified_text_and_a_phrase_is_marked() {
    let dir = Scratch::new("traditional");
    let package = package(&dir, "noad", &[chinese(), take()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();

    let traditional = core.examples("漢語".into(), vec![dict.clone()], 100).unwrap();
    assert_eq!(traditional.hits.len(), 1);
    assert!(traditional.hits[0].chinese.contains("汉语"));
    assert_eq!(
        traditional.hits[0]
            .chinese
            .get(traditional.hits[0].start as usize..(traditional.hits[0].start + traditional.hits[0].len) as usize),
        Some("汉语")
    );

    let phrase = core.examples("放轻松".into(), vec![dict], 100).unwrap();
    assert_eq!(phrase.hits.len(), 1);
    assert!(!phrase.hits[0].sentence, "a phrase is marked");
}

#[test]
fn the_limit_bounds_the_page_and_total_counts_every_distinct_pair() {
    let dir = Scratch::new("limit");
    let package = package(&dir, "noad", &[run(), consider(), short_pair(), long_pair()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();

    let all = core.examples("。".into(), vec![dict.clone()], 100).unwrap();
    assert!(all.total >= 3, "{all:?}");
    assert_eq!(all.hits.len(), all.total as usize);

    let one = core.examples("。".into(), vec![dict.clone()], 1).unwrap();
    assert_eq!(one.hits.len(), 1);
    assert_eq!(one.total, all.total);

    let too_many = core.examples("。".into(), vec![dict], MAX_PAGE + 1);
    assert!(matches!(too_many, Err(CoreError::TooLarge { limit: Limit::Page, .. })));
}

#[test]
fn within_a_dictionary_shorter_chinese_ranks_first() {
    let dir = Scratch::new("rank");
    let package = package(&dir, "noad", &[short_pair(), long_pair()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();
    let found = core.examples("好".into(), vec![dict], 100).unwrap();
    assert_eq!(found.hits.len(), 2);
    assert!(
        found.hits[0].chinese.chars().count() <= found.hits[1].chinese.chars().count(),
        "{} then {}",
        found.hits[0].chinese,
        found.hits[1].chinese
    );
}

#[test]
fn a_sentence_ranks_before_a_shorter_phrase() {
    let dir = Scratch::new("sentences-first");
    let package = package(&dir, "noad", &[phrase_pair(), sentence_pair()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();
    let found = core.examples("放轻松".into(), vec![dict], 100).unwrap();
    assert_eq!(found.hits.len(), 2);
    assert!(found.hits[0].sentence, "the sentence comes first: {:?}", found.hits);
    assert!(!found.hits[1].sentence);
}

#[test]
fn identical_pairs_from_two_dictionaries_are_one_hit_with_both_sources() {
    let dir = Scratch::new("dedupe");
    let one = package(&dir, "one", &[run()]);
    let two = package(&dir, "two", &[run()]);
    let core = core();
    let (first, _) = opened(&core, one);
    let (second, _) = opened(&core, two);
    core.examples_build(first.clone(), &NoProgress).unwrap();
    core.examples_build(second.clone(), &NoProgress).unwrap();
    let found = core.examples("跑步".into(), vec![first, second], 100).unwrap();
    assert_eq!(found.total, 1);
    assert_eq!(found.hits.len(), 1);
    assert_eq!(found.hits[0].sources.len(), 2);
}

#[test]
fn a_dictionary_with_no_chinese_keeps_an_empty_store_and_is_ready() {
    let dir = Scratch::new("monolingual");
    let package = package(&dir, "noad", &[pure()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(built.no_chinese);
    assert_eq!(built.pairs, 0);
    assert_eq!(built.entries, 0);
    let found = core.examples("的".into(), vec![dict.clone()], 100).unwrap();
    assert!(found.not_ready.is_empty());
    assert!(found.hits.is_empty());
    // The empty answer was confirmed by reading every record, so it is cached like any other result.
    let again = core.examples_build(dict, &NoProgress).unwrap();
    assert!(again.no_chinese);
    assert!(again.cached);
}

#[test]
fn a_damaged_or_foreign_store_is_rebuilt_byte_for_byte() {
    let dir = Scratch::new("rebuild");
    let package = package(&dir, "noad", &[run(), consider()]);
    let storage = Arc::new(Recording::default());
    let core = core_with(storage.clone());
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();
    let names = storage.examples_names();
    assert_eq!(names.len(), 1, "{names:?}");
    let name = names[0].clone();
    let good = storage.bytes(&name).unwrap();

    let mut truncated = good.clone();
    truncated.truncate(good.len() / 2);
    storage.put_raw(&name, truncated);
    let found = core.examples("跑步".into(), vec![dict.clone()], 100).unwrap();
    assert_eq!(found.not_ready, vec![dict.clone()], "a store that does not decode is not read");
    let rebuilt = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(!rebuilt.cached);
    assert_eq!(storage.bytes(&name).unwrap(), good, "a rebuild is byte-identical");

    storage.put_raw(&name, b"XDEX not a store".to_vec());
    assert!(!core.examples_build(dict.clone(), &NoProgress).unwrap().cached);
    assert_eq!(storage.bytes(&name).unwrap(), good);

    let mut changed_version = good.clone();
    if let Some(byte) = changed_version.get_mut(12) {
        *byte = 99;
    }
    storage.put_raw(&name, changed_version);
    assert!(!core.examples_build(dict, &NoProgress).unwrap().cached);
    assert_eq!(storage.bytes(&name).unwrap(), good);
}

#[test]
fn an_abbreviation_entrys_expansion_is_not_stored() {
    let dir = Scratch::new("abbreviation");
    let package = package(&dir, "noad", &[abbreviation(), run()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert_eq!(built.pairs, 1, "only the example entry's pair: {built:?}");
    let found = core.examples("美国".into(), vec![dict], 100).unwrap();
    assert!(found.hits.is_empty(), "{found:?}");
}

#[test]
fn the_api_caps_a_one_character_query() {
    let dir = Scratch::new("cap");
    let package = package(&dir, "noad", &many());
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();
    let found = core.examples("的".into(), vec![dict], 100).unwrap();
    assert!(found.capped, "the scan stopped at its own bound");
    assert_eq!(found.total, 10_000, "10,001 distinct pairs, one past the bound");
    assert_eq!(found.hits.len(), 100, "the page holds at most 100");
}

#[test]
fn a_store_under_another_extractors_name_is_not_read() {
    let dir = Scratch::new("version-name");
    let package = package(&dir, "noad", &[run()]);
    let storage = Arc::new(Recording::default());
    let core = core_with(storage.clone());
    let (dict, _) = opened(&core, package);
    let built = core.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(!built.cached);
    let current = storage.examples_names().pop().unwrap();
    let bytes = storage.bytes(&current).unwrap();
    // The same bytes under the name another extractor version would have written: never read.
    let older = current.replace(&format!("-e{EXAMPLES_EXTRACTOR}-"), "-e0-");
    assert_ne!(older, current);
    storage.put_raw(&older, bytes);
    storage.remove(&current);
    let found = core.examples("跑步".into(), vec![dict.clone()], 100).unwrap();
    assert_eq!(found.not_ready, vec![dict.clone()], "only this extractor's name is read");
    assert!(!core.examples_build(dict.clone(), &NoProgress).unwrap().cached, "it builds under the current name");
    assert!(storage.examples_names().contains(&current));
    assert_eq!(core.examples("跑步".into(), vec![dict], 100).unwrap().hits.len(), 1);
}

#[test]
fn cancelling_the_pass_keeps_no_store() {
    struct Stop;
    impl Progress for Stop {
        fn progress(&self, _: u64, _: u64) -> bool {
            false
        }
    }
    let dir = Scratch::new("cancel");
    let package = package(&dir, "noad", &[run(), consider()]);
    let storage = Arc::new(Recording::default());
    let core = core_with(storage.clone());
    let (dict, _) = opened(&core, package);
    let outcome = core.examples_build(dict, &Stop);
    assert!(matches!(outcome, Err(CoreError::Cancelled { .. })), "{outcome:?}");
    assert!(storage.examples_names().is_empty(), "a cancelled pass writes nothing");
}

#[test]
fn building_a_store_writes_no_ledger_event() {
    let dir = Scratch::new("sync");
    let package = package(&dir, "noad", &[run()]);
    let storage = Arc::new(Recording::default());
    let core = core_with(storage);
    let (dict, _) = opened(&core, package);
    core.examples_build(dict, &NoProgress).unwrap();
    assert!(core.ledger_export().unwrap().is_empty(), "the store is derived and never synced");
}

#[test]
fn the_native_directory_round_trips_across_cores() {
    let dir = Scratch::new("native");
    let cache = dir.path().join("cache");
    let data = dir.path().join("data");
    std::fs::create_dir_all(&cache).unwrap();
    std::fs::create_dir_all(&data).unwrap();
    let config = || Config {
        cache_dir: Some(cache.to_string_lossy().into()),
        data_dir: Some(data.to_string_lossy().into()),
        client_protocol: PROTOCOL,
        ..Config::default()
    };
    let package = package(&dir, "noad", &[run(), consider()]);
    let first = Core::new(config()).unwrap();
    let (dict, _) = opened(&first, package.clone());
    let built = first.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(!built.cached);
    let stored = std::fs::read_dir(&cache)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("examples-"))
        .count();
    assert_eq!(stored, 1, "the store is one file in the index directory");
    drop(first);

    let second = Core::new(config()).unwrap();
    let (dict, _) = opened(&second, package);
    let again = second.examples_build(dict.clone(), &NoProgress).unwrap();
    assert!(again.cached, "{again:?}");
    assert_eq!(again.pairs, built.pairs);
    assert!(second.examples("跑步".into(), vec![dict], 10).unwrap().total >= 1);
}

#[test]
fn the_same_key_twice_keeps_each_records_occurrence() {
    let dir = Scratch::new("occurrence");
    let package = package(&dir, "noad", &[run(), run()]);
    let core = core();
    let (dict, _) = opened(&core, package);
    core.examples_build(dict.clone(), &NoProgress).unwrap();
    let found = core.examples("跑步".into(), vec![dict], 100).unwrap();
    assert_eq!(found.hits.len(), 1, "the identical pair is one hit: {found:?}");
    let mut occurrences: Vec<u32> = found.hits[0].sources.iter().map(|source| source.entry.occurrence).collect();
    occurrences.sort_unstable();
    assert_eq!(occurrences, vec![0, 1], "each record keeps its own occurrence");
}
