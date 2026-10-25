//! **Phrase recognition's cost beside a lookup's** (`dev-docs/plan-phrase-recognition.md` WI-7): on each dictionary,
//! the inventory's build and its cold decode, then warm `phrases` and `lookup` calls timed side by side, so the two
//! calls a capture may make are compared with numbers rather than assumed. A measurement, not a gate:
//! `XDICT_MDX_CORPUS=<the 24> cargo test --release -p xdict-core --test phrase_latency -- --nocapture`. Says
//! "not measured" when the variable is unset.
//!
//! `XDICT_PHRASE_LATENCY_ITERATIONS` sets the warm calls per dictionary (20 by default).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::time::Instant;

use xdict_core::{Config, Core, Location, LookupOptions, MatchMode, NoProgress, Opened, PROTOCOL, Package};

/// A sentence a reader could meet, with the term on its head word: the `slotted` conformance vector's sentence.
const SENTENCE: &str = "they took the delay into account before deciding";
const TERM: (u64, u64) = (25, 7);
/// A word every dictionary carries, asked as the search field asks it.
const QUERY: &str = "take";

fn package(dir: &Path) -> Option<Package> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|entry| entry.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?;
    let mdd: Vec<Location> =
        files.iter().filter(|p| ext(p, "mdd")).map(|p| Location::Path { path: p.to_string_lossy().into() }).collect();
    let sidecars: Vec<Location> = files
        .iter()
        .filter(|p| !ext(p, "mdx") && !ext(p, "mdd"))
        .map(|p| Location::Path { path: p.to_string_lossy().into() })
        .collect();
    Some(Package { mdx: Location::Path { path: mdx.to_string_lossy().into() }, mdd, sidecars })
}

fn percentile(sorted: &[f64], fraction: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let index = ((sorted.len() - 1) as f64 * fraction).round() as usize;
    sorted[index.min(sorted.len() - 1)]
}

fn stats(mut times: Vec<f64>) -> (f64, f64, f64) {
    times.sort_by(f64::total_cmp);
    (percentile(&times, 0.5), percentile(&times, 0.95), percentile(&times, 0.99))
}

#[test]
fn the_phrase_question_and_a_lookup_are_timed_on_every_dictionary() {
    let Ok(roots) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let iterations: u32 =
        std::env::var("XDICT_PHRASE_LATENCY_ITERATIONS").ok().and_then(|value| value.parse().ok()).unwrap_or(20);
    let cache = std::env::temp_dir().join(format!("xdict-phrase-latency-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&cache);
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&roots)
        .flat_map(|root| std::fs::read_dir(root).unwrap().map(|entry| entry.unwrap().path()))
        .filter(|path| path.is_dir())
        .collect();
    folders.sort();
    let mut all_phrases = Vec::new();
    let mut all_lookups = Vec::new();
    let mut all_builds = Vec::new();
    eprintln!(
        "file\tkeys\tphrases\tbuild_ms\tphrases_p50_us\tphrases_p95_us\tphrases_p99_us\tlookup_p50_us\tlookup_p95_us\tlookup_p99_us\tcold_ms"
    );
    for folder in folders {
        let Some(spec) = package(&folder) else { continue };
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let imported = core.import(spec.clone(), &NoProgress);
        let Ok(imported) = imported else {
            eprintln!("{name}\timport failed");
            continue;
        };
        let Opened::Ready { dict, .. } = core.open(spec.clone()).unwrap() else {
            eprintln!("{name}\tnot open");
            continue;
        };
        let started = Instant::now();
        let built = core.phrases_build(dict.clone(), &NoProgress).unwrap();
        let build_ms = started.elapsed().as_secs_f64() * 1e3;
        let ask = |into: &str| core.phrases(SENTENCE.to_string(), TERM.0, TERM.1, vec![into.to_string()]).unwrap();
        // One warm ask, then the timed ones; the answer is not printed, only its cost.
        ask(&dict);
        let mut phrase_times = Vec::with_capacity(iterations as usize);
        for _ in 0..iterations {
            let started = Instant::now();
            let answer = ask(&dict);
            phrase_times.push(started.elapsed().as_secs_f64() * 1e6);
            assert_ne!(answer.state, xdict_core::PhraseState::NotAsked);
        }
        let options = LookupOptions { limit: 50, offset: 0, mode: MatchMode::Reader, generation: None };
        core.lookup(QUERY.to_string(), vec![dict.clone()], options.clone()).unwrap();
        let mut lookup_times = Vec::with_capacity(iterations as usize);
        for _ in 0..iterations {
            let started = Instant::now();
            core.lookup(QUERY.to_string(), vec![dict.clone()], options.clone()).unwrap();
            lookup_times.push(started.elapsed().as_secs_f64() * 1e6);
        }
        // Cold: the matcher is dropped with the handle, so the next open's first ask decodes and indexes the store.
        core.close(dict.clone()).unwrap();
        let Opened::Ready { dict: again, .. } = core.open(spec).unwrap() else { continue };
        let started = Instant::now();
        core.phrases(SENTENCE.to_string(), TERM.0, TERM.1, vec![again.clone()]).unwrap();
        let cold_ms = started.elapsed().as_secs_f64() * 1e3;
        core.close(again).unwrap();

        let (phrase_p50, phrase_p95, phrase_p99) = stats(phrase_times.clone());
        let (lookup_p50, lookup_p95, lookup_p99) = stats(lookup_times.clone());
        eprintln!(
            "{name}\t{}\t{}\t{build_ms:.1}\t{phrase_p50:.1}\t{phrase_p95:.1}\t{phrase_p99:.1}\t{lookup_p50:.1}\t{lookup_p95:.1}\t{lookup_p99:.1}\t{cold_ms:.1}",
            imported.info.keys, built.phrases
        );
        all_phrases.extend(phrase_times);
        all_lookups.extend(lookup_times);
        all_builds.push(build_ms);
    }
    let _ = std::fs::remove_dir_all(&cache);
    assert!(!all_phrases.is_empty(), "no dictionary was measured");
    let (p50, p95, p99) = stats(all_phrases);
    let (l50, l95, l99) = stats(all_lookups);
    let (b50, b95, b99) = stats(all_builds);
    eprintln!("ALL\tphrases p50 {p50:.1} p95 {p95:.1} p99 {p99:.1} us");
    eprintln!("ALL\tlookup  p50 {l50:.1} p95 {l95:.1} p99 {l99:.1} us");
    eprintln!("ALL\tbuild   p50 {b50:.1} p95 {b95:.1} p99 {b99:.1} ms");
    eprintln!(
        "ALL\tone capture, serial: p50 {:.1} p95 {:.1} p99 {:.1} us (lookup + phrases)",
        l50 + p50,
        l95 + p95,
        l99 + p99
    );
    eprintln!(
        "ALL\tone capture, parallel: p50 {:.1} p95 {:.1} p99 {:.1} us (the slower of the two)",
        l50.max(p50),
        l95.max(p95),
        l99.max(p99)
    );
}
