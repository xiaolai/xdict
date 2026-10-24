//! Lookup on real dictionaries (`plan-core-v1.md` WI-5): `XDICT_MDX_CORPUS=<dirs> cargo test --release -p
//! xdict-lookup --test corpus -- --nocapture`. Says "not measured" when the variable is unset. Checks:
//!
//! - every key a reader cannot reach at tier 1 by typing it without its marks (`core-api.md` §1a: no key matches
//!   the unmarked form) is reached at tier 2, unless it is internal;
//! - no suggestion is an internal key, and every internal key resolves as a link;
//! - and prints `corpus_shapes.py`'s redirect table, computed the same way with the core's tier-1 matching in
//!   place of the collection's normalisation.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use xdict_lookup::{Mode, Policy, Problem, matches, redirect_targets, resolve, suggest, unmark};
use xdict_mdx::{Budget, DiskFile, File, Kind};

fn mdx_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = entries.map(|e| e.unwrap().path()).collect();
    paths.sort();
    for path in paths {
        if path.is_dir() {
            mdx_files(&path, out);
        } else if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("mdx")) {
            out.push(path);
        }
    }
}

fn open(path: &Path) -> File {
    let source = DiskFile::open(path).unwrap();
    let index = File::build_index(&source, Some(Kind::Mdx), [0; 32], &Policy).unwrap();
    File::with_index(
        Box::new(DiskFile::open(path).unwrap()),
        Some(Kind::Mdx),
        Box::new(index),
        [0; 32],
        Arc::new(Policy),
    )
    .unwrap()
    .unwrap()
}

/// Every key's redirect targets (empty for an entry), every record read once.
fn records(file: &File) -> Vec<Vec<String>> {
    let mut out = vec![Vec::new(); file.len()];
    let all: Vec<usize> = (0..file.len()).collect();
    for chunk in all.chunks(5_000) {
        file.for_each_record(chunk, &mut Budget::new(u64::MAX, usize::MAX), |i, r| {
            out[i] = redirect_targets(&String::from_utf8_lossy(&r.data));
            Ok(())
        })
        .unwrap();
    }
    out
}

#[derive(Default, Debug)]
struct Reach {
    marked: usize,
    unreachable: usize,
    stressed: usize,
    stressed_unreachable: usize,
    internal: usize,
    reached: usize,
}

fn reach(file: &File, failures: &mut Vec<String>, name: &str) -> Reach {
    let mut r = Reach::default();
    for i in 0..file.len() {
        let key = file.key(i).unwrap();
        let plain = unmark(key.trim());
        if plain == key.trim() {
            continue;
        }
        let stress = key.contains(['ˈ', 'ˌ']);
        r.marked += 1;
        r.stressed += usize::from(stress);
        if file.find(&plain).unwrap().is_empty() {
            r.unreachable += 1;
            r.stressed_unreachable += usize::from(stress);
        }
        if !file.is_public(i).unwrap() {
            r.internal += 1;
            continue;
        }
        // Reached typed plainly, whether or not another key is found for the same spelling (`AAA` and `AAA²`).
        let found = matches(file, &plain, Mode::Reader).unwrap();
        if found.iter().any(|(j, _)| *j == i) {
            r.reached += 1;
        } else {
            failures.push(format!("{name}: {key:?} typed as {plain:?} is not found"));
        }
    }
    r
}

/// Internal keys: how many, none suggested, every one a link.
fn internal(file: &File, failures: &mut Vec<String>, name: &str) -> usize {
    let internal: Vec<usize> = (0..file.len()).filter(|&i| !file.is_public(i).unwrap()).collect();
    let public: HashSet<String> =
        (0..file.len()).filter(|&i| file.is_public(i).unwrap()).map(|i| file.key(i).unwrap().into_owned()).collect();
    for (n, &i) in internal.iter().enumerate() {
        let key = file.key(i).unwrap();
        if !matches(file, &key, Mode::Link).unwrap().iter().any(|(j, _)| *j == i) {
            failures.push(format!("{name}: internal {key:?} does not resolve as a link"));
        }
        if n % 50 == 0 {
            let prefix: String = key.chars().take(3).collect();
            let mut out = Vec::new();
            suggest(file, &prefix, 100, &mut out).unwrap();
            for s in out.iter().filter(|s| !public.contains(*s)) {
                failures.push(format!("{name}: {s:?} was suggested for {prefix:?} and is internal"));
            }
        }
    }
    internal.len()
}

/// `corpus_shapes.py`'s redirect shapes, with "equal" meaning "found by tier 1".
fn redirect_shapes(file: &File, targets: &[Vec<String>]) -> String {
    // A key's class: the lowest key number of everything tier 1 finds for it.
    let class = |text: &str| file.find(text).unwrap().into_iter().min();
    let mut entries: HashSet<usize> = HashSet::new();
    let mut redirects: HashMap<usize, Vec<Option<usize>>> = HashMap::new();
    let mut count = 0;
    for (i, t) in targets.iter().enumerate() {
        let key = file.key(i).unwrap();
        let Some(c) = class(key.trim()) else { continue };
        if t.is_empty() {
            entries.insert(c);
        } else {
            count += t.len();
            redirects.entry(c).or_default().extend(t.iter().map(|t| class(t)));
        }
    }
    let multi = redirects.values().filter(|v| v.len() > 1).count();
    let also = redirects.keys().filter(|c| entries.contains(c)).count();
    let (mut chained, mut dangling, mut cycles, mut max_hops) = (0, 0, 0, 0);
    for (&n, ts) in &redirects {
        for &tn in ts {
            if tn.is_some_and(|t| entries.contains(&t)) {
                continue;
            }
            let Some(tn) = tn.filter(|t| redirects.contains_key(t)) else {
                dangling += 1;
                continue;
            };
            chained += 1;
            let (mut seen, mut frontier, mut hops, mut reached) = (HashSet::from([n]), vec![tn], 1, false);
            while !frontier.is_empty() && hops < 10 && !reached {
                let mut following = Vec::new();
                for c in std::mem::take(&mut frontier) {
                    if !seen.insert(c) {
                        cycles += 1;
                        continue;
                    }
                    if entries.contains(&c) {
                        reached = true;
                    } else {
                        following.extend(redirects.get(&c).into_iter().flatten().flatten());
                    }
                }
                if !reached {
                    frontier = following;
                    hops += 1;
                }
            }
            max_hops = max_hops.max(hops);
            dangling += usize::from(!reached);
        }
    }
    format!(
        "redirects {count:>7}  multi-target {multi:>6}  chained {chained:>6}  max hops {max_hops}  dangling {dangling:>5}  \
         cycles {cycles:>5}  key also an entry {also:>6}"
    )
}

/// The resolver itself from every redirect key: dangling targets and loops counted, and no limit met.
fn resolved(file: &File, targets: &[Vec<String>], failures: &mut Vec<String>, name: &str) -> String {
    let mut texts: Vec<String> = targets
        .iter()
        .enumerate()
        .filter(|(_, t)| !t.is_empty())
        .map(|(i, _)| file.key(i).unwrap().into_owned())
        .collect();
    texts.sort();
    texts.dedup();
    let (mut hits, mut dangling, mut loops) = (0, 0, 0);
    for text in &texts {
        match resolve(file, text, Mode::Link, &mut Budget::lookup()) {
            Ok(r) => {
                hits += r.hits.len();
                for p in r.problems.iter().chain(r.hits.iter().flat_map(|h| &h.problems)) {
                    match p {
                        Problem::Dangling { .. } => dangling += 1,
                        Problem::Loop { .. } => loops += 1,
                        Problem::Limit { .. } => failures.push(format!("{name}: {text:?} met a redirect limit")),
                    }
                }
            }
            Err(e) => failures.push(format!("{name}: {text:?}: {e}")),
        }
    }
    format!("resolved {} redirect keys: {hits} hits, {dangling} dangling, {loops} loops", texts.len())
}

#[test]
fn lookup_on_the_corpus() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let mut files = Vec::new();
    for dir in std::env::split_paths(&dirs) {
        mdx_files(&dir, &mut files);
    }
    let mut failures = Vec::new();
    let mut total = Reach::default();
    for path in &files {
        let name = path.parent().and_then(|p| p.file_name()).unwrap().to_string_lossy().into_owned();
        let file = open(path);
        let r = reach(&file, &mut failures, &name);
        let internal_keys = internal(&file, &mut failures, &name);
        let targets = records(&file);
        let shapes = redirect_shapes(&file, &targets);
        let followed = resolved(&file, &targets, &mut failures, &name);
        eprintln!(
            "{name:10} keys {:>8}  internal {internal_keys:>6}  marked {:>6} (reached plainly {:>6}, internal {:>5})  \
             nothing at tier 1 {:>6} (stressed {:>6})",
            file.len(),
            r.marked,
            r.reached,
            r.internal,
            r.unreachable,
            r.stressed_unreachable,
        );
        eprintln!("{name:10} {shapes}");
        eprintln!("{name:10} {followed}");
        total.marked += r.marked;
        total.reached += r.reached;
        total.internal += r.internal;
        total.unreachable += r.unreachable;
        total.stressed_unreachable += r.stressed_unreachable;
    }
    // The leading newline is the gate's marker: `Tools/land.sh` counts a corpus run as measured only when this line
    // starts a line of the log, and the harness's result line is written without a trailing newline before stderr is
    // flushed (2026-10-24: "…143.52s24 files:…", a green run the gate refused as unmeasured).
    eprintln!(
        "\n{} files: {} marked keys, {} public and reached typed plainly, {} internal; {} found nothing at tier 1 typed \
         plainly ({} with stress marks)",
        files.len(),
        total.marked,
        total.reached,
        total.internal,
        total.unreachable,
        total.stressed_unreachable
    );
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
