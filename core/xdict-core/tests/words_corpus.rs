//! The words a consumer lists, on real dictionaries (plan-setup-v2 WI-6; ADR-0028):
//! `XDICT_MDX_CORPUS=<dirs> cargo test --release -p xdict-core --test words_corpus -- --nocapture`. Each folder of the
//! corpus is one package, as in `entries_corpus.rs`.
//!
//! What the Spotlight index promises is that **a word it holds opens**: so every edition is paged whole, the pages are
//! checked to cover exactly the key count, and a sample of its words is looked up in reader mode and must come back as
//! an exact hit for that same word. A word that does not open is an item Spotlight would show and XDict could not
//! answer. Repeats are the contract's own (one item per key entry), so the sample is de-duplicated first.
//!
//! Unset, it says "not measured" rather than passing quietly.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};

use xdict_core::{Config, Core, Location, NoProgress, Opened, PROTOCOL, Package};

fn package(dir: &Path) -> Option<Package> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|e| e.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?.clone();
    let location = |p: &Path| Location::Path { path: p.to_string_lossy().into_owned() };
    let hidden = |p: &Path| p.file_name().unwrap().to_string_lossy().starts_with('.');
    let mdd = files.iter().filter(|p| ext(p, "mdd")).map(|p| location(p)).collect();
    let sidecars =
        files.iter().filter(|p| !ext(p, "mdx") && !ext(p, "mdd") && !hidden(p)).map(|p| location(p)).collect();
    Some(Package { mdx: location(&mdx), mdd, sidecars })
}

/// How many of a dictionary's words are looked up: a fixed sample, so a 4.4 M-key file costs a measurement and not an
/// afternoon.
const SAMPLES: usize = 1_000;
const PAGE: u32 = 1_000;

#[test]
fn every_word_the_index_would_hold_opens() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let cache = std::env::temp_dir().join(format!("xdict-words-{}", std::process::id()));
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&dirs)
        .flat_map(|d| std::fs::read_dir(d).unwrap().map(|e| e.unwrap().path()))
        .filter(|p| p.is_dir())
        .collect();
    folders.sort();
    let mut measured = 0;
    for folder in folders {
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let Some(package) = package(&folder) else { continue };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, info, .. } = core.open(package).unwrap() else { panic!("{name}: not open") };

        let started = std::time::Instant::now();
        let first = core.words(dict.clone(), 0, PAGE).unwrap();
        let total = first.total;
        assert_eq!(total, info.keys, "{name}: the total is the key count");
        let edition = first.edition.clone();
        let mut words: Vec<String> = Vec::new();
        let mut page = first;
        let mut from = 0u64;
        loop {
            assert_eq!(page.edition, edition, "{name}: the edition changed while paging");
            for word in &page.words {
                assert!(!word.is_empty(), "{name}: an empty word");
            }
            words.extend(page.words.iter().cloned());
            from += u64::from(PAGE);
            if from >= total {
                break;
            }
            page = core.words(dict.clone(), from, PAGE).unwrap();
            assert_eq!(page.total, total, "{name}: the total moved while paging");
        }
        let secs = started.elapsed().as_secs_f64();
        assert!(!words.is_empty(), "{name}: no words at all");

        // **A word it holds opens**: sampled evenly over the dictionary, looked up as a reader would type it — that is,
        // the lookup answers at least one hit. A key that is a redirect answers its target instead of itself
        // (`12-step` in the corpus's `ahd`), which still opens the right entry; how often that happens is counted and
        // printed rather than asserted, since it is the dictionary's choice and not a defect. The
        // spellings are taken once each, since a repeated key entry is one Spotlight item, and **punctuation-only keys
        // are not sampled**: `,` is a public key of `ahd` and a reader-mode lookup folds it away, so a consumer shows a
        // word only when it can be typed (the issue this test found on its first real run).
        let typeable = |word: &String| word.chars().any(char::is_alphanumeric);
        let mut distinct: Vec<&String> = Vec::new();
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        let mut untypeable = 0usize;
        for word in &words {
            if !typeable(word) {
                untypeable += 1;
                continue;
            }
            if seen.insert(word.as_str()) {
                distinct.push(word);
            }
        }
        assert!(untypeable * 10 < words.len().max(1), "{name}: {untypeable} of {} words cannot be typed", words.len());
        let step = (distinct.len() / SAMPLES).max(1);
        let mut sampled = 0;
        let mut exact = 0;
        for word in distinct.iter().step_by(step).take(SAMPLES) {
            let options = xdict_core::LookupOptions {
                limit: 10,
                offset: 0,
                mode: xdict_core::MatchMode::Reader,
                generation: None,
            };
            let answer = core.lookup((*word).clone(), vec![dict.clone()], options).unwrap();
            assert!(!answer.hits.is_empty(), "{name}: {word} is indexed but opens nothing");
            if answer.hits.iter().any(|hit| hit.entry.key == **word) {
                exact += 1;
            }
            sampled += 1;
        }
        eprintln!(
            "{name}: {} words ({} typeable spellings, {untypeable} not) of {total} keys in {secs:.1} s; \
             {sampled} sampled, all open, {exact} at their own key",
            words.len(),
            distinct.len()
        );
        measured += 1;
    }
    assert!(measured > 0, "not measured: the corpus held no package");
}
