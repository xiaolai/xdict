//! **The reverse-example measurement** (ADR-0031, plan-reverse-examples WI-2): every record of the five bilingual
//! dictionaries in `the24` read once through the core's own render, the pairs each tier finds, the query's scan cost,
//! and an evenly spaced sample per dictionary for a person to read.
//!
//! `XDICT_MDX_CORPUS=<dirs> [XDICT_EXAMPLES_DICTS=cobuild-ec,…] [XDICT_EXAMPLES_AUDIT_DIR=<outside the repo>]
//!   cargo test --release -p xdict-core --test examples_corpus -- --nocapture`
//!
//! The pairs are dictionary content: the audit dump belongs outside every repository and is never committed. Says
//! "not measured" when `XDICT_MDX_CORPUS` is unset.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use xdict_core::*;

/// The five bilingual dictionaries in `the24` (ADR-0031's evidence table).
const DICTS: &str = "cobuild-ec,ldoce-ec,oalecd,odecn,yhdcd";
/// The parallel corpus's audited pair counts for them, from its build of 2026-10-05 (`data/parallel.db`, dictionary
/// ids 1, 8, 6, 5 and 4; the file's sha256 is pinned in `dev-docs/measurements/2026-10-24-reverse-examples/README.md`
/// as `66d89125…5052`, with `verdicts.json` at `b61aaa38…f77f`). The corpus is the recall oracle, never shipped
/// (ADR-0031 Context).
const ORACLE: &[(&str, u64)] =
    &[("cobuild-ec", 97_924), ("ldoce-ec", 81_957), ("oalecd", 96_930), ("odecn", 74_368), ("yhdcd", 171_109)];

fn package(dir: &Path) -> Option<(PathBuf, Package)> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|entry| entry.unwrap().path()).filter(|path| path.is_file()).collect();
    files.sort();
    let ext = |path: &Path, extension: &str| path.extension().is_some_and(|x| x.eq_ignore_ascii_case(extension));
    let mdx = files.iter().find(|path| ext(path, "mdx"))?.clone();
    let mut mdd: Vec<&PathBuf> = files.iter().filter(|path| ext(path, "mdd")).collect();
    let volume = |path: &Path| -> u32 {
        let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
        stem.rsplit_once('.').and_then(|(_, n)| n.parse().ok()).map_or(0, |n: u32| n + 1)
    };
    mdd.sort_by_key(|path| volume(path));
    let location = |path: &Path| Location::Path { path: path.to_string_lossy().into_owned() };
    let hidden = |path: &Path| path.file_name().unwrap().to_string_lossy().starts_with('.');
    let sidecars = files
        .iter()
        .filter(|path| !ext(path, "mdx") && !ext(path, "mdd") && !hidden(path))
        .map(|path| location(path))
        .collect();
    let mdx_location = location(&mdx);
    Some((mdx, Package { mdx: mdx_location, mdd: mdd.into_iter().map(|path| location(path)).collect(), sidecars }))
}

/// Progress once per tenth: a pass of 232k records would otherwise print one line per report.
#[derive(Default)]
struct Watch {
    last: AtomicU64,
}

impl Progress for Watch {
    fn progress(&self, done: u64, total: u64) -> bool {
        if total == 0 {
            return true;
        }
        let tenth = done.saturating_mul(10) / total;
        let previous = self.last.swap(tenth, Ordering::Relaxed);
        if tenth != previous {
            eprintln!("      {done:>7} / {total} records");
        }
        true
    }
}

fn median(times: &mut [f64]) -> f64 {
    times.sort_by(f64::total_cmp);
    times.get(times.len() / 2).copied().unwrap_or(0.0)
}

/// The audit's sample: `count` pairs evenly spaced over the store, as `sentence, key, English, Chinese` lines.
fn dump(core: &Core, dict: &str, name: &str, dir: &Path) -> usize {
    let total = core.examples_page(dict.to_owned(), 0, 1).unwrap().total;
    if total == 0 {
        return 0;
    }
    let count = 120u64;
    let step = (total / count).max(1);
    let mut out = String::new();
    for k in 0..count {
        let from = k * step;
        if from >= total {
            break;
        }
        let page = core.examples_page(dict.to_owned(), from, 1).unwrap();
        if let Some(pair) = page.pairs.first() {
            let clean = |text: &str| text.replace(['\t', '\n', '\r'], " ");
            out.push_str(&format!(
                "{}\t{}\t{}\t{}\n",
                pair.sentence,
                clean(&pair.entry.key),
                clean(&pair.english),
                clean(&pair.chinese)
            ));
        }
    }
    let path = dir.join(format!("{name}.tsv"));
    std::fs::write(&path, &out).unwrap();
    eprintln!("  audit sample: {} pairs -> {}", out.lines().count(), path.display());
    out.lines().count()
}

#[test]
fn the_five_bilingual_dictionaries() {
    let Ok(corpus) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let only: Vec<String> = std::env::var("XDICT_EXAMPLES_DICTS")
        .unwrap_or_else(|_| DICTS.to_owned())
        .split(',')
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .collect();
    let audit = std::env::var("XDICT_EXAMPLES_AUDIT_DIR").ok().map(PathBuf::from);
    if let Some(dir) = &audit {
        std::fs::create_dir_all(dir).unwrap();
    }
    let cache = std::env::temp_dir().join("xdict-examples-corpus-cache");
    std::fs::create_dir_all(&cache).unwrap();
    let core = Core::new(Config {
        client_protocol: PROTOCOL,
        cache_dir: Some(cache.to_string_lossy().into()),
        ..Config::default()
    })
    .unwrap();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&corpus)
        .flat_map(|dir| std::fs::read_dir(dir).unwrap().map(|entry| entry.unwrap().path()))
        .filter(|path| path.is_dir())
        .collect();
    folders.sort();
    let mut measured = 0;
    for folder in folders {
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        if !only.contains(&name) {
            continue;
        }
        let Some((_mdx, package)) = package(&folder) else { continue };
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { dict, info, .. } = core.open(package).unwrap() else { panic!("{name}: not open") };
        eprintln!("{name}: {} records", info.keys);
        let started = Instant::now();
        let built = core.examples_build(dict.clone(), &Watch::default()).unwrap();
        let seconds = started.elapsed().as_secs_f64();
        let oracle = ORACLE.iter().find(|(asked, _)| *asked == name).map_or(0, |(_, count)| *count);
        eprintln!(
            "  {name}: records {}, roles {}, fallback {}, pairs {}, failed {}; corpus {oracle} ({:.3} of it); {seconds:.1} s",
            built.entries,
            built.roles,
            built.fallback,
            built.pairs,
            built.failed,
            if oracle == 0 { 0.0 } else { built.pairs as f64 / oracle as f64 },
        );
        let mut times = Vec::new();
        let mut total = 0;
        for _ in 0..10 {
            let started = Instant::now();
            let found = core.examples("居然".into(), vec![dict.clone()], 100).unwrap();
            times.push(started.elapsed().as_secs_f64() * 1000.0);
            total = found.total;
        }
        let best = times.iter().copied().fold(f64::INFINITY, f64::min);
        let typical = median(&mut times);
        eprintln!("  scan 居然: {total} pairs, {best:.2} ms best, {typical:.2} ms median");
        let started = Instant::now();
        let common = core.examples("的".into(), vec![dict.clone()], 100).unwrap();
        eprintln!(
            "  scan 的: {} pairs, capped {}, {:.2} ms",
            common.total,
            common.capped,
            started.elapsed().as_secs_f64() * 1000.0
        );
        if let Some(dir) = &audit {
            dump(&core, &dict, &name, dir);
        }
        assert!(built.pairs > 0, "{name}: no pairs extracted");
        measured += 1;
        core.close(dict).unwrap();
    }
    assert_eq!(measured, only.len(), "every dictionary asked for was measured: {measured} of {}", only.len());
}
