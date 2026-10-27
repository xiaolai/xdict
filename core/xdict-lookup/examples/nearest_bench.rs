//! **What a "did you mean" would cost if it scanned the file's own keys** (2026-10-27): the measurement that decides
//! between scanning keys per miss and storing a normalised key table in the edition index (which would raise
//! `NORMALIZATION` and rebuild every index).
//!
//! `XDICT_MDX_CORPUS=<dirs> cargo run --release --example nearest_bench -p xdict-lookup`
//!
//! Three folds of the same scan: raw lower case only (the floor), `unmark` + lower case on every key (the honest
//! cost), and an ASCII fast path with a length filter (the shape the real code would have). Every query is a real
//! misspelling of a word the dictionaries hold.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use xdict_lookup::{Policy, unmark};
use xdict_mdx::{DiskFile, File, Kind};

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

const FAR: usize = usize::MAX / 4;

/// The engine's own metric, copied here so the measurement needs no change to the crate: optimal string alignment,
/// `None` once it must exceed `max`.
fn osa(a: &[char], b: &[char], max: usize) -> Option<usize> {
    if a.len().abs_diff(b.len()) > max {
        return None;
    }
    let width = b.len() + 1;
    let mut before: Vec<usize> = vec![FAR; width];
    let mut previous: Vec<usize> = (0..width).collect();
    let mut current: Vec<usize> = vec![FAR; width];
    let at = |row: &[usize], j: usize| row.get(j).copied().unwrap_or(FAR);
    for (i, ai) in a.iter().enumerate() {
        let i = i + 1;
        if let Some(first) = current.first_mut() {
            *first = i;
        }
        let mut row_min = i;
        for (j, bj) in b.iter().enumerate() {
            let j = j + 1;
            let cost = usize::from(ai != bj);
            let mut value = (at(&previous, j) + 1).min(at(&current, j - 1) + 1).min(at(&previous, j - 1) + cost);
            if i > 1 && j > 1 {
                let a_before = a.get(i - 2);
                let b_before = b.get(j - 2);
                if a_before == Some(bj) && b_before == Some(ai) {
                    value = value.min(at(&before, j - 2) + 1);
                }
            }
            if let Some(cell) = current.get_mut(j) {
                *cell = value;
            }
            row_min = row_min.min(value);
        }
        if row_min > max {
            return None;
        }
        std::mem::swap(&mut before, &mut previous);
        std::mem::swap(&mut previous, &mut current);
    }
    let distance = at(&previous, b.len());
    (distance <= max).then_some(distance)
}

#[derive(Clone, Copy, PartialEq)]
enum Fold {
    /// Lower case only: the floor a scan can cost.
    Raw,
    /// `unmark` and lower case on every key: what tier 2 means.
    Unmark,
    /// `unmark` only where the key is not ASCII, with a length filter first: the shape the real code would have.
    Fast,
    /// The same, inside the band of keys that begin with the query's first letter — the cheap narrowing, with the
    /// full scan as the fallback when the band yields nothing.
    Band,
}

fn main() {
    let Ok(dirs) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        std::process::exit(2);
    };
    let mut paths = Vec::new();
    for dir in dirs.split(':') {
        mdx_files(Path::new(dir), &mut paths);
    }
    println!("files: {}", paths.len());
    let files: Vec<(PathBuf, File)> = paths.iter().map(|p| (p.clone(), open(p))).collect();

    let queries = ["recieve", "acommodate", "taht", "seperate", "definately"];

    // One file's scan under one fold: the hits, and how many keys were actually compared.
    let scan = |file: &File, query: &[char], max: usize, fold: Fold| -> (usize, usize) {
        let mut found = 0usize;
        let mut compared = 0usize;
        let try_key = |key: &str, found: &mut usize, compared: &mut usize| {
            if key.chars().count().abs_diff(query.len()) > max {
                return;
            }
            *compared += 1;
            let lowered = if key.is_ascii() { key.to_ascii_lowercase() } else { unmark(key).to_lowercase() };
            let chars: Vec<char> = lowered.chars().collect();
            if osa(query, &chars, max).is_some() {
                *found += 1;
            }
        };
        match fold {
            Fold::Raw | Fold::Unmark => {
                for key in file.keys() {
                    let key = key.unwrap();
                    let chars: Vec<char> = if fold == Fold::Raw {
                        key.to_lowercase().chars().collect()
                    } else {
                        unmark(&key).to_lowercase().chars().collect()
                    };
                    if osa(query, &chars, max).is_some() {
                        found += 1;
                    }
                    compared += 1;
                }
            }
            Fold::Fast => {
                for key in file.keys() {
                    try_key(&key.unwrap(), &mut found, &mut compared);
                }
            }
            Fold::Band => {
                let band = query.first().map(|c| c.to_string()).unwrap_or_default();
                file.prefixed(&band, |i| {
                    let key = file.key(i).unwrap();
                    try_key(&key, &mut found, &mut compared);
                    Ok(true)
                })
                .unwrap();
                if found == 0 {
                    for key in file.keys() {
                        try_key(&key.unwrap(), &mut found, &mut compared);
                    }
                }
            }
        }
        (found, compared)
    };

    for fold in [Fold::Raw, Fold::Unmark, Fold::Fast, Fold::Band] {
        for max in [1usize, 2] {
            let mut total = std::time::Duration::ZERO;
            let mut hits = 0usize;
            let mut compared = 0usize;
            for query in queries {
                let chars: Vec<char> = query.chars().collect();
                for (_, file) in &files {
                    let began = Instant::now();
                    let (found, seen) = scan(file, &chars, max, fold);
                    total += began.elapsed();
                    hits += found;
                    compared += seen;
                }
            }
            let name = match fold {
                Fold::Raw => "raw",
                Fold::Unmark => "unmark",
                Fold::Fast => "fast",
                Fold::Band => "band",
            };
            let scope = total.as_secs_f64() * 1000.0 / queries.len() as f64;
            println!(
                "{name:>6} d<={max}: {scope:.1} ms for one miss across {} files ({hits} hits, {compared} keys compared)",
                files.len()
            );
        }
    }
}
