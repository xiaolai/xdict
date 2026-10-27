//! The word catalog (2026-10-24; ADR-0032 and `core/xdict-core/WORD_OPTIONS.md`): [`Core::word_explorer`] builds an
//! immutable, edition-qualified catalog of every public headword of the dictionaries asked for, each with every
//! place it is keyed, from the index alone. Two synthetic dictionaries, written here by the suite's own MDX writer:
//!
//! | Dictionary | Keys, in file order (record marker) |
//! |---|---|
//! | `d1` | `@ref000`…`@ref099` (100 internal: a pattern of the file), `alfa` (`@@@LINK=alpha`), `alpha` (`d1-alpha-0`), `alpha` (`d1-alpha-1`), `beta` |
//! | `d2` | `@home` (public: a lone `@` key is no pattern), `Alpha` (`d2-Alpha-0`), `alpha` (`d2-alpha-0`), `gamma` |
//!
//! Six public spellings in all. The catalog is read back through the explorer's own search and stats, so a stub that
//! answers nothing fails every test here.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::atomic::{AtomicI64, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use xdict_core::explore::ExploreState;
use xdict_core::words::{MAX_WORD_PAGE, WordExplorer, WordMode, WordQuery, WordSource};
use xdict_core::{
    ByteSource, Config, Core, CoreError, EntryRef, FileIdentity, Location, LookupOptions, MatchMode, NoProgress,
    Opened, PROTOCOL, Package, Progress, View,
};
use xdict_mdx_writer::{Entry, Spec, write};

// ---- fixtures -------------------------------------------------------------------------------------------------

/// A file the shell holds, counting every read the core makes of it.
struct Counted {
    bytes: Vec<u8>,
    inode: u64,
    reads: AtomicU64,
}

impl Counted {
    fn reads(&self) -> u64 {
        self.reads.load(Ordering::SeqCst)
    }

    fn reset(&self) {
        self.reads.store(0, Ordering::SeqCst);
    }
}

impl ByteSource for Counted {
    fn size(&self) -> u64 {
        self.bytes.len() as u64
    }

    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        let start = offset as usize;
        Ok(self.bytes[start..start + len as usize].to_vec())
    }

    fn identity(&self) -> Option<FileIdentity> {
        Some(FileIdentity { device: 1, inode: self.inode, size: self.bytes.len() as u64, mtime_ns: 1, ctime_ns: 1 })
    }
}

const INTERNAL_KEYS: usize = 100;

fn d1_entries() -> Vec<Entry> {
    let mut entries: Vec<Entry> =
        (0..INTERNAL_KEYS).map(|i| Entry::text(&format!("@ref{i:03}"), "<p>MARK-d1-ref</p>")).collect();
    entries.extend([
        Entry::text("alpha", "<p>MARK-d1-alpha-0</p>"),
        Entry::text("alpha", "<p>MARK-d1-alpha-1</p>"),
        Entry::text("beta", "<p>MARK-d1-beta-0</p>"),
        Entry::text("alfa", "@@@LINK=alpha"),
    ]);
    entries
}

fn d2_entries() -> Vec<Entry> {
    vec![
        Entry::text("Alpha", "<p>MARK-d2-Alpha-0</p>"),
        Entry::text("alpha", "<p>MARK-d2-alpha-0</p>"),
        Entry::text("gamma", "<p>MARK-d2-gamma-0</p>"),
        Entry::text("@home", "<p>MARK-d2-home-0</p>"),
    ]
}

const D1_KEYS: u64 = INTERNAL_KEYS as u64 + 4;
const D2_KEYS: u64 = 4;
/// `alpha`, `alfa`, `beta` (d1); `Alpha`, `gamma`, `@home` (d2): `alpha` once though both key it.
const PUBLIC_SPELLINGS: u64 = 6;

struct Fixture {
    core: Arc<Core>,
    d1: String,
    d2: String,
    e1: String,
    e2: String,
    s1: Arc<Counted>,
    s2: Arc<Counted>,
}

fn new_core() -> Core {
    Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap()
}

/// Imports and opens one synthetic dictionary: its handle, edition and counted source.
fn add(core: &Core, name: &str, inode: u64, entries: &[Entry]) -> (String, String, Arc<Counted>) {
    let spec = Spec { title: name.into(), ..Spec::mdx() };
    let source = Arc::new(Counted { bytes: write(&spec, entries).unwrap(), inode, reads: AtomicU64::new(0) });
    let package = Package {
        mdx: Location::Source { name: format!("{name}.mdx"), source: source.clone() },
        mdd: Vec::new(),
        sidecars: Vec::new(),
    };
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, edition, .. } => {
            assert_eq!(edition, imported.edition);
            (dict, edition, source)
        }
        other => panic!("{name} did not open: {other:?}"),
    }
}

fn fixture() -> Fixture {
    let core = new_core();
    let (d1, e1, s1) = add(&core, "one", 11, &d1_entries());
    let (d2, e2, s2) = add(&core, "two", 22, &d2_entries());
    assert_ne!(e1, e2, "two different files are two editions");
    Fixture { core: Arc::new(core), d1, d2, e1, e2, s1, s2 }
}

fn at(dict: &str, edition: &str, key: &str, occurrence: u32) -> WordSource {
    WordSource { dict: dict.into(), entry: EntryRef { edition: edition.into(), key: key.into(), occurrence } }
}

/// Every source the explorer holds for exactly this spelling, read back through its own search: an ends-with query
/// of the word itself finds the word, whatever else it finds.
fn sources(explorer: &WordExplorer, word: &str) -> Vec<WordSource> {
    let query = WordQuery { text: word.into(), mode: WordMode::EndsWith, limit: MAX_WORD_PAGE, offset: 0 };
    let page = explorer.search(query).unwrap();
    let hits: Vec<_> = page.hits.into_iter().filter(|h| h.headword == word).collect();
    assert!(hits.len() <= 1, "{word:?} is one catalog entry, not {}", hits.len());
    hits.into_iter().flat_map(|h| h.sources).collect()
}

fn view() -> View {
    View { base_url: "xdict://d/".into(), max_body_bytes: 1 << 20, original_style: false }
}

/// Progress that records every report, and answers `false` at the `stop_at`th (1-based).
struct Recorded {
    calls: Mutex<Vec<(u64, u64)>>,
    stop_at: Option<usize>,
}

impl Recorded {
    fn new(stop_at: Option<usize>) -> Self {
        Self { calls: Mutex::new(Vec::new()), stop_at }
    }
}

impl Progress for Recorded {
    fn progress(&self, done: u64, total: u64) -> bool {
        let mut calls = self.calls.lock().unwrap();
        calls.push((done, total));
        self.stop_at != Some(calls.len())
    }
}

/// Runs `call` on a thread of its own and fails, rather than hangs, when it does not return: a lock held across a
/// callback that calls back into the core deadlocks.
fn within<T: Send + 'static>(call: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(call());
    });
    rx.recv_timeout(Duration::from_secs(60)).expect("the call did not return: a lock held across a callback?")
}

// ---- across the boundary (plan-word-exploration WI-4) -----------------------------------------------------------

/// **The shell's way in**: `Core::explore` answers a page of rows — the word, the dictionary and the entry it opens, a
/// label — and every row opens a real entry.
#[test]
fn the_core_answers_an_exploration_and_names_the_entry_it_opens() {
    let f = fixture();
    let dicts = vec![f.d1.clone(), f.d2.clone()];
    let answer = f.core.explore(dicts.clone(), WordMode::EndsWith, "a".into(), 0, 10).unwrap();
    assert_eq!(answer.state, ExploreState::Answered);
    assert!(!answer.rows.is_empty(), "a spelling ends with a");
    for row in &answer.rows {
        assert!(row.word.to_lowercase().ends_with('a'), "{}", row.word);
        let opened = f.core.entry(row.dict.clone(), row.entry.clone(), view()).unwrap();
        assert!(!opened.html.is_empty(), "{} opens nothing", row.word);
    }
    // The same scope answers the same page: one row per headword, its first source.
    let again = f.core.explore(dicts, WordMode::EndsWith, "a".into(), 0, 10).unwrap();
    assert_eq!(again.rows, answer.rows);
}

/// **Absence of data is never absence of relatives**: without the pack, a mode that needs it says which data is
/// missing rather than answering "none".
#[test]
fn an_exploration_without_the_pack_says_which_data_is_missing() {
    let f = fixture();
    let answer = f.core.explore(vec![f.d1.clone()], WordMode::Rhyme, "alpha".into(), 0, 10).unwrap();
    assert_eq!(answer.state, ExploreState::NoData);
    assert!(answer.rows.is_empty(), "nothing is claimed without data");
}

/// A query the explorer refuses is the shell's request, answered as one — not a damaged dictionary.
#[test]
fn a_refused_query_is_the_shells_request_not_damage() {
    let f = fixture();
    let refused = f.core.explore(vec![f.d1.clone()], WordMode::Fuzzy { max_distance: 9 }, "alpha".into(), 0, 10);
    assert!(matches!(refused, Err(CoreError::Malformed { .. })), "{refused:?}");
}

// ---- the catalog ------------------------------------------------------------------------------------------------

#[test]
fn every_public_headword_of_every_dictionary_is_in_the_catalog_with_every_place_it_is_keyed() {
    let f = fixture();
    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &NoProgress).unwrap();

    let stats = explorer.stats();
    assert_eq!(stats.headwords, PUBLIC_SPELLINGS, "{stats:?}");
    let mut editions = vec![f.e1.clone(), f.e2.clone()];
    editions.sort();
    assert_eq!(stats.editions, editions);

    // One spelling, three places: the dictionaries in the order asked, each key entry in file order, numbered among
    // the records of exactly this key.
    assert_eq!(
        sources(&explorer, "alpha"),
        vec![at(&f.d1, &f.e1, "alpha", 0), at(&f.d1, &f.e1, "alpha", 1), at(&f.d2, &f.e2, "alpha", 0)]
    );
    // Another spelling is another headword: `Alpha` is not `alpha`, and its occurrence counts only `Alpha`'s records
    // (the file's folding would count `alpha`'s too).
    assert_eq!(sources(&explorer, "Alpha"), vec![at(&f.d2, &f.e2, "Alpha", 0)]);
    assert_eq!(sources(&explorer, "beta"), vec![at(&f.d1, &f.e1, "beta", 0)]);
    assert_eq!(sources(&explorer, "gamma"), vec![at(&f.d2, &f.e2, "gamma", 0)]);
    // A redirect's key is a headword at its own key: the catalog reads keys, never the record that redirects.
    assert_eq!(sources(&explorer, "alfa"), vec![at(&f.d1, &f.e1, "alfa", 0)]);
    // A lone `@` key is public in its file.
    assert_eq!(sources(&explorer, "@home"), vec![at(&f.d2, &f.e2, "@home", 0)]);
}

#[test]
fn the_requested_order_of_dictionaries_is_the_order_of_sources() {
    let f = fixture();
    let explorer = f.core.word_explorer(vec![f.d2.clone(), f.d1.clone()], &NoProgress).unwrap();
    assert_eq!(
        sources(&explorer, "alpha"),
        vec![at(&f.d2, &f.e2, "alpha", 0), at(&f.d1, &f.e1, "alpha", 0), at(&f.d1, &f.e1, "alpha", 1)]
    );
}

#[test]
fn a_dictionary_asked_for_twice_is_read_once() {
    let f = fixture();
    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone(), f.d1.clone()], &NoProgress).unwrap();
    assert_eq!(explorer.stats().headwords, PUBLIC_SPELLINGS);
    assert_eq!(explorer.stats().editions.len(), 2);
    // Its first place in the request is its place; its duplicate occurrences are its own, not repeats of the handle.
    assert_eq!(
        sources(&explorer, "alpha"),
        vec![at(&f.d1, &f.e1, "alpha", 0), at(&f.d1, &f.e1, "alpha", 1), at(&f.d2, &f.e2, "alpha", 0)]
    );
    assert_eq!(sources(&explorer, "beta"), vec![at(&f.d1, &f.e1, "beta", 0)]);
}

#[test]
fn every_source_opens_the_entry_it_names() {
    let f = fixture();
    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &NoProgress).unwrap();
    let expected = [
        ("alpha", vec!["MARK-d1-alpha-0", "MARK-d1-alpha-1", "MARK-d2-alpha-0"]),
        ("Alpha", vec!["MARK-d2-Alpha-0"]),
        ("beta", vec!["MARK-d1-beta-0"]),
        ("gamma", vec!["MARK-d2-gamma-0"]),
        ("@home", vec!["MARK-d2-home-0"]),
    ];
    let all = ["MARK-d1-alpha-0", "MARK-d1-alpha-1", "MARK-d2-alpha-0", "MARK-d2-Alpha-0"];
    for (word, markers) in expected {
        let found = sources(&explorer, word);
        assert_eq!(found.len(), markers.len(), "{word}: {found:?}");
        for (source, marker) in found.into_iter().zip(markers) {
            let entry = f.core.entry(source.dict.clone(), source.entry.clone(), view()).unwrap();
            assert!(entry.html.contains(marker), "{source:?} should open {marker}");
            for other in all.iter().filter(|m| **m != marker) {
                assert!(!entry.html.contains(other), "{source:?} opened {other} as well as {marker}");
            }
        }
    }
}

#[test]
fn internal_keys_are_not_headwords() {
    let f = fixture();
    // The fixture's control: the keys are there and internal, reached by a link and never offered to a reader.
    let link = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Link, generation: None };
    let found = f.core.lookup("@ref000".into(), vec![f.d1.clone()], link).unwrap();
    assert_eq!(found.hits.len(), 1, "the internal key is in the file");
    let words = f.core.words(f.d1.clone(), 0, 1_000).unwrap();
    assert!(!words.words.iter().any(|w| w.starts_with("@ref")), "{:?}", words.words);

    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &NoProgress).unwrap();
    assert_eq!(explorer.stats().headwords, PUBLIC_SPELLINGS, "no internal key counted");
    for i in [0, 42, 99] {
        let key = format!("@ref{i:03}");
        assert!(sources(&explorer, &key).is_empty(), "{key} is internal");
    }
    let query = WordQuery { text: "ref000".into(), mode: WordMode::EndsWith, limit: MAX_WORD_PAGE, offset: 0 };
    assert!(explorer.search(query).unwrap().hits.is_empty());
    // The positive control in the same catalog: d1's public keys are there.
    assert_eq!(sources(&explorer, "beta").len(), 1);
}

/// A key over 4 KiB (a sentence-keyed or badly converted file) is one skipped headword, counted, never a refused
/// catalog: through the core a key is its own headword, so the bound on keys must not refuse what the headword skips.
#[test]
fn fable_an_oversized_key_is_skipped_and_counted_not_a_refused_catalog() {
    let core = new_core();
    let long = "a".repeat(5_000);
    let entries = [Entry::text("word", "<p>MARK-word</p>"), Entry::text(&long, "<p>MARK-long</p>")];
    let (dict, edition, _) = add(&core, "long", 88, &entries);
    // The premise: the file keys it publicly.
    let words = core.words(dict.clone(), 0, 10).unwrap();
    assert!(words.words.contains(&long), "the oversized key is a public key of the file");

    let explorer = core.word_explorer(vec![dict.clone()], &NoProgress);
    let explorer = explorer.unwrap_or_else(|e| panic!("one oversized key refused the whole catalog: {e:?}"));
    let stats = explorer.stats();
    assert_eq!((stats.headwords, stats.skipped_headwords), (1, 1), "{stats:?}");
    assert_eq!(sources(&explorer, "word"), vec![at(&dict, &edition, "word", 0)]);
}

#[test]
fn the_catalog_reads_the_index_and_no_byte_of_any_file() {
    let f = fixture();
    // The premise: a dictionary's keys and their public flags are in its index, so listing them reads nothing of the
    // file (`Core::words`). Any read while the catalog is built is a record, a resource or a key block read again.
    f.s1.reset();
    f.core.words(f.d1.clone(), 0, 1_000).unwrap();
    assert_eq!(f.s1.reads(), 0, "premise: the index answers the keys");

    f.s1.reset();
    f.s2.reset();
    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &NoProgress).unwrap();
    assert_eq!((f.s1.reads(), f.s2.reads()), (0, 0), "the catalog read the files");
    assert_eq!(explorer.stats().headwords, PUBLIC_SPELLINGS);
    // Searching it reads nothing either.
    assert_eq!(sources(&explorer, "alpha").len(), 3);
    assert_eq!((f.s1.reads(), f.s2.reads()), (0, 0), "a search read the files");

    // The counter's control: opening an entry reads its record.
    let source = sources(&explorer, "beta").remove(0);
    f.core.entry(source.dict, source.entry, view()).unwrap();
    assert!(f.s1.reads() > 0, "the counter counts reads");
}

// ---- handles ----------------------------------------------------------------------------------------------------

#[test]
fn a_closed_foreign_or_malformed_handle_is_refused_whole() {
    let f = fixture();
    let other = new_core();
    let (foreign, _, _) = add(&other, "foreign", 33, &d2_entries());
    let (closed, _, _) = add(&f.core, "closed", 44, &d2_entries());
    f.core.close(closed.clone()).unwrap();

    for bad in [closed, foreign, "not a handle".to_owned()] {
        // The bad handle after a good one: no partial catalog of the good one.
        let answer = f.core.word_explorer(vec![f.d1.clone(), bad.clone()], &NoProgress);
        assert!(matches!(answer, Err(CoreError::StaleHandle { .. })), "{bad}: {answer:?}");
    }
    // Asking for none is an empty catalog, not an error; the good handles still answer after the refusals.
    assert_eq!(f.core.word_explorer(Vec::new(), &NoProgress).unwrap().stats().headwords, 0);
    let explorer = f.core.word_explorer(vec![f.d1.clone()], &NoProgress).unwrap();
    assert_eq!(explorer.stats().headwords, 3);
}

#[test]
fn a_dictionary_closed_by_a_callback_is_refused_never_answered_from() {
    let f = fixture();
    struct Closer {
        core: Arc<Core>,
        dict: String,
        closed: AtomicUsize,
    }
    impl Progress for Closer {
        fn progress(&self, _: u64, _: u64) -> bool {
            if self.closed.fetch_add(1, Ordering::SeqCst) == 0 {
                self.core.close(self.dict.clone()).unwrap();
            }
            true
        }
    }
    let closer = Arc::new(Closer { core: f.core.clone(), dict: f.d2.clone(), closed: AtomicUsize::new(0) });
    let (core, dicts, progress) = (f.core.clone(), vec![f.d1.clone(), f.d2.clone()], closer.clone());
    let answer = within(move || core.word_explorer(dicts, &*progress));
    assert!(closer.closed.load(Ordering::SeqCst) > 0, "the callback ran");
    // d2 is closed: its handle no longer names an open dictionary, so a catalog naming it would send the shell to a
    // handle that answers nothing.
    assert!(matches!(answer, Err(CoreError::StaleHandle { .. })), "{answer:?}");
    // The core is still usable.
    assert_eq!(f.core.word_explorer(vec![f.d1.clone()], &NoProgress).unwrap().stats().headwords, 3);
}

// ---- files changed under a callback -------------------------------------------------------------------------------

/// A file the shell holds whose modification time the test moves, as a rewrite of the file would.
struct Movable {
    bytes: Vec<u8>,
    inode: u64,
    mtime_ns: AtomicI64,
}

impl Movable {
    fn touch(&self) {
        self.mtime_ns.fetch_add(1, Ordering::SeqCst);
    }
}

impl ByteSource for Movable {
    fn size(&self) -> u64 {
        self.bytes.len() as u64
    }

    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        let start = offset as usize;
        Ok(self.bytes[start..start + len as usize].to_vec())
    }

    fn identity(&self) -> Option<FileIdentity> {
        let mtime_ns = self.mtime_ns.load(Ordering::SeqCst);
        Some(FileIdentity { device: 1, inode: self.inode, size: self.bytes.len() as u64, mtime_ns, ctime_ns: 1 })
    }
}

/// Imports and opens one synthetic dictionary on a [`Movable`] source: its handle and source.
fn add_movable(core: &Core, name: &str, inode: u64, entries: &[Entry]) -> (String, Arc<Movable>) {
    let spec = Spec { title: name.into(), ..Spec::mdx() };
    let source = Arc::new(Movable { bytes: write(&spec, entries).unwrap(), inode, mtime_ns: AtomicI64::new(1) });
    let package = Package {
        mdx: Location::Source { name: format!("{name}.mdx"), source: source.clone() },
        mdd: Vec::new(),
        sidecars: Vec::new(),
    };
    core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (dict, source),
        other => panic!("{name} did not open: {other:?}"),
    }
}

/// Progress that records every report and, at the report whose `done` is `at`, rewrites `source` (none: never).
struct Toucher {
    source: Option<Arc<Movable>>,
    at: u64,
    touched: AtomicUsize,
    calls: Mutex<Vec<(u64, u64)>>,
}

impl Toucher {
    fn new(source: Option<Arc<Movable>>, at: u64) -> Self {
        Self { source, at, touched: AtomicUsize::new(0), calls: Mutex::new(Vec::new()) }
    }
}

impl Progress for Toucher {
    fn progress(&self, done: u64, total: u64) -> bool {
        self.calls.lock().unwrap().push((done, total));
        if done == self.at
            && let Some(source) = &self.source
        {
            source.touch();
            self.touched.fetch_add(1, Ordering::SeqCst);
        }
        true
    }
}

fn source_changed(answer: &Result<WordExplorer, CoreError>) -> bool {
    matches!(answer, Err(CoreError::SourceChanged { .. }))
}

/// The last report is the callback's last chance to rewrite the file: a catalog read from the file as it was is not
/// an answer about the file as it is.
#[test]
fn a_file_changed_by_the_last_callback_is_refused() {
    let core = new_core();
    let (dict, source) = add_movable(&core, "last", 55, &d2_entries());
    let toucher = Toucher::new(Some(source), D2_KEYS);
    let answer = core.word_explorer(vec![dict.clone()], &toucher);
    let calls = toucher.calls.lock().unwrap().clone();
    assert_eq!(toucher.touched.load(Ordering::SeqCst), 1, "the last report was not (total, total): {calls:?}");
    // The premise: the core sees the rewrite, so the catalog had a way to.
    assert!(matches!(core.words(dict, 0, 1), Err(CoreError::SourceChanged { .. })), "the touch is no change");
    assert!(source_changed(&answer), "{answer:?}");
}

/// A dictionary already read is not settled: a callback while a later one is read may rewrite it.
#[test]
fn an_earlier_file_changed_by_a_later_dictionarys_callback_is_refused() {
    let core = new_core();
    let (d1, s1) = add_movable(&core, "earlier", 66, &d1_entries());
    let (d2, _) = add_movable(&core, "later", 77, &d2_entries());
    // `D1_KEYS + D2_KEYS` is reported once d2 is read: a callback of d2's, after d1's own last check.
    let toucher = Toucher::new(Some(s1), D1_KEYS + D2_KEYS);
    let answer = core.word_explorer(vec![d1.clone(), d2.clone()], &toucher);
    let calls = toucher.calls.lock().unwrap().clone();
    assert_eq!(toucher.touched.load(Ordering::SeqCst), 1, "d2's report was not reached: {calls:?}");
    assert!(matches!(core.words(d1, 0, 1), Err(CoreError::SourceChanged { .. })), "the touch is no change");
    assert!(core.words(d2, 0, 1).is_ok(), "d2 was not touched");
    assert!(source_changed(&answer), "{answer:?}");
}

/// The control of the two above: the same files and callbacks, nothing rewritten, build a catalog.
#[test]
fn unchanged_files_under_the_same_callbacks_build_a_catalog() {
    let core = new_core();
    let (d1, _) = add_movable(&core, "earlier", 66, &d1_entries());
    let (d2, _) = add_movable(&core, "later", 77, &d2_entries());
    let total = D1_KEYS + D2_KEYS;
    let toucher = Toucher::new(None, total);
    let answer = core.word_explorer(vec![d1, d2], &toucher);
    assert!(answer.is_ok(), "{answer:?}");
    assert_eq!(toucher.calls.lock().unwrap().last().copied(), Some((total, total)));
}

// ---- progress ---------------------------------------------------------------------------------------------------

#[test]
fn progress_counts_key_entries_of_each_dictionary_once() {
    let f = fixture();
    let recorded = Recorded::new(None);
    f.core.word_explorer(vec![f.d1.clone(), f.d2.clone(), f.d1.clone()], &recorded).unwrap();
    let calls = recorded.calls.lock().unwrap().clone();
    // Key entries, internal ones included, of each distinct dictionary: at least one report per dictionary, the
    // total fixed, the count never going back, and the last report the whole.
    let total = D1_KEYS + D2_KEYS;
    assert!(calls.len() >= 2, "{calls:?}");
    assert!(calls.iter().all(|&(done, t)| t == total && done <= total), "{calls:?}");
    assert!(calls.windows(2).all(|w| w[0].0 <= w[1].0), "{calls:?}");
    assert_eq!(calls.last().copied(), Some((total, total)), "{calls:?}");
}

#[test]
fn answering_false_cancels_and_leaves_the_core_usable() {
    let f = fixture();
    for stop_at in [1, 2] {
        let recorded = Recorded::new(Some(stop_at));
        let answer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &recorded);
        assert!(matches!(answer, Err(CoreError::Cancelled { .. })), "stop at {stop_at}: {answer:?}");
        assert_eq!(recorded.calls.lock().unwrap().len(), stop_at, "no report after the one that said stop");
    }
    let explorer = f.core.word_explorer(vec![f.d1.clone(), f.d2.clone()], &NoProgress).unwrap();
    assert_eq!(explorer.stats().headwords, PUBLIC_SPELLINGS);
}

#[test]
fn a_callback_may_call_back_into_the_core() {
    let f = fixture();
    struct Reenter {
        core: Arc<Core>,
        dicts: Vec<String>,
        calls: AtomicUsize,
    }
    impl Progress for Reenter {
        fn progress(&self, _: u64, _: u64) -> bool {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let _ = Core::versions();
            let words = self.core.words(self.dicts[0].clone(), 0, 10).unwrap();
            assert!(!words.words.is_empty());
            let reader = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Reader, generation: None };
            assert!(!self.core.lookup("alpha".into(), self.dicts.clone(), reader).unwrap().hits.is_empty());
            // A catalog built inside a catalog's callback: the core's lock is not held here either.
            let inner = self.core.word_explorer(vec![self.dicts[1].clone()], &NoProgress).unwrap();
            assert_eq!(inner.stats().headwords, 4);
            true
        }
    }
    let dicts = vec![f.d1.clone(), f.d2.clone()];
    let reenter = Arc::new(Reenter { core: f.core.clone(), dicts: dicts.clone(), calls: AtomicUsize::new(0) });
    let (core, progress) = (f.core.clone(), reenter.clone());
    let explorer = within(move || core.word_explorer(dicts, &*progress)).unwrap();
    assert!(reenter.calls.load(Ordering::SeqCst) > 0, "the callback ran");
    assert_eq!(explorer.stats().headwords, PUBLIC_SPELLINGS);
}
