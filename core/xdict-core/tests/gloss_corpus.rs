//! **The glosses of real dictionaries** (ADR-0037): `XDICT_MDX_CORPUS=<the 24> cargo test --release -p xdict-core
//! --test gloss_corpus -- --nocapture`. Says "not measured" when the variable is unset.
//!
//! Each folder is imported as a package and sampled at 60 evenly spaced records. Per dictionary it prints how many
//! samples carry a gloss, from the definition body or a translation, how many do not, how many were clamped, and the
//! median and p95 of the gloss's bytes and of the call's time. `XDICT_GLOSS_DUMP=<file>` also writes
//! `dictionary \t key \t source \t part of speech \t gloss` for a person to read — **the file is dictionary content and
//! is written outside the repository, on the measurement host, and never committed**.
//!
//! What the test itself asserts is structure, never a meaning: a found gloss is non-empty, one line, within its bound and
//! names its source. Whether a gloss is *right* is the owner's per-dictionary audit, recorded in
//! `dev-docs/measurements/2026-10-31-history-gloss/`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::time::Instant;

use xdict_core::{Config, Core, EntryRef, GlossSource, Location, NoProgress, Opened, PROTOCOL, Package};
use xdict_entry::GLOSS_MAX_CHARS;
use xdict_mdx::File;

/// One sample per this many records, so a dictionary of any size is read at the same breadth.
const SAMPLE: usize = 60;

/// A folder's package: its MDX, its MDD volumes in order, every other file a sidecar (as `entries_corpus` reads it).
fn package(dir: &Path) -> Option<(PathBuf, Package)> {
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.map(|e| e.unwrap().path()).filter(|p| p.is_file()).collect();
    files.sort();
    let ext = |p: &Path, e: &str| p.extension().is_some_and(|x| x.eq_ignore_ascii_case(e));
    let mdx = files.iter().find(|p| ext(p, "mdx"))?.clone();
    let mut mdd: Vec<&PathBuf> = files.iter().filter(|p| ext(p, "mdd")).collect();
    let volume = |p: &Path| -> u32 {
        let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
        stem.rsplit_once('.').and_then(|(_, n)| n.parse().ok()).map_or(0, |n: u32| n + 1)
    };
    mdd.sort_by_key(|p| volume(p));
    let location = |p: &Path| Location::Path { path: p.to_string_lossy().into_owned() };
    let hidden = |p: &Path| p.file_name().unwrap().to_string_lossy().starts_with('.');
    let sidecars =
        files.iter().filter(|p| !ext(p, "mdx") && !ext(p, "mdd") && !hidden(p)).map(|p| location(p)).collect();
    let package = Package { mdx: location(&mdx), mdd: mdd.into_iter().map(|p| location(p)).collect(), sidecars };
    Some((mdx, package))
}

/// The value at `p` of a sorted copy, or zero when there is none.
fn percentile(values: &[u128], p: f64) -> u128 {
    if values.is_empty() {
        return 0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let index = (((sorted.len() - 1) as f64) * p).round() as usize;
    sorted[index]
}

#[test]
fn glosses_of_the_corpus() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let dump_path = std::env::var("XDICT_GLOSS_DUMP").ok();
    let cache = std::env::temp_dir().join(format!("xdict-gloss-{}", std::process::id()));
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

    let mut dump = String::new();
    let mut failures = Vec::new();
    let mut total_sampled = 0usize;
    let mut total_found = 0usize;

    for folder in folders {
        let Some((mdx_path, package)) = package(&folder) else { continue };
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        core.import(package.clone(), &NoProgress).unwrap();
        let Opened::Ready { edition, .. } = core.open(package).unwrap() else {
            failures.push(format!("{name}: not open"));
            continue;
        };
        let file = File::open(&mdx_path).unwrap();
        let step = (file.len() / SAMPLE).max(1);
        let (mut sampled, mut found, mut definitions, mut translations, mut none, mut truncated, mut errors) =
            (0usize, 0usize, 0usize, 0usize, 0usize, 0usize, 0usize);
        let mut sizes: Vec<u128> = Vec::new();
        let mut times: Vec<u128> = Vec::new();

        for i in (0..file.len()).step_by(step) {
            let key = file.key(i).unwrap().into_owned();
            let occurrence = file.find(&key).unwrap().iter().filter(|&&j| file.key(j).unwrap() == key && j < i).count();
            let record = file.record(i).unwrap();
            let text = String::from_utf8_lossy(&record.data);
            if text.trim_start().starts_with("@@@LINK=") {
                continue;
            }
            let entry = EntryRef { edition: edition.clone(), key: key.clone(), occurrence: occurrence as u32 };
            sampled += 1;
            let start = Instant::now();
            match core.entry_gloss(entry) {
                Ok(gloss) => {
                    times.push(start.elapsed().as_micros());
                    match gloss.text {
                        Some(text) => {
                            found += 1;
                            sizes.push(text.len() as u128);
                            if text.is_empty() || text.contains('\n') || text.chars().count() > GLOSS_MAX_CHARS {
                                failures.push(format!("{name}: {key:?}/{occurrence}: a malformed gloss: {text:?}"));
                            }
                            match gloss.source {
                                Some(GlossSource::Definition) => definitions += 1,
                                Some(GlossSource::Translation) => translations += 1,
                                None => failures.push(format!("{name}: {key:?}/{occurrence}: a gloss with no source")),
                            }
                            if gloss.truncated {
                                truncated += 1;
                            }
                            if dump_path.is_some() {
                                // A person reads this: plain words, not Rust's debug forms.
                                let source = match gloss.source {
                                    Some(GlossSource::Definition) => "definition",
                                    Some(GlossSource::Translation) => "translation",
                                    None => "none",
                                };
                                let pos = gloss.pos.as_deref().unwrap_or("");
                                dump.push_str(&format!("{name}\t{key}\t{source}\t{pos}\t{text}\n"));
                            }
                        }
                        None => none += 1,
                    }
                }
                Err(e) => {
                    errors += 1;
                    failures.push(format!("{name}: {key:?}/{occurrence}: {e:?}"));
                }
            }
        }

        eprintln!(
            "{name:12} sampled {sampled} found {found} (definition {definitions}, translation {translations}) none \
             {none} truncated {truncated} errors {errors}; bytes median {} p95 {}; time median {} µs p95 {} µs",
            percentile(&sizes, 0.5),
            percentile(&sizes, 0.95),
            percentile(&times, 0.5),
            percentile(&times, 0.95),
        );
        total_sampled += sampled;
        total_found += found;
    }

    if let Some(path) = dump_path {
        std::fs::write(&path, dump).unwrap();
        eprintln!("the sampled glosses are in {path} (dictionary content: read them, never commit them)");
    }
    eprintln!("{total_sampled} sampled, {total_found} with a gloss");
    assert!(total_sampled > 0, "the corpus path held no dictionaries");
    assert!(failures.is_empty(), "{} gloss failures, first: {:?}", failures.len(), failures.first());
}
