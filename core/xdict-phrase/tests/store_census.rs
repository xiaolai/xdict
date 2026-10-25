//! **The inventory's size and build time over real dictionaries** (`dev-docs/plan-phrase-recognition.md` WI-4): per
//! edition, how many of its public keys become phrases, the store's bytes, and how long the build takes. A
//! measurement, not a gate: without the corpus variable it says "not measured" and passes.
//!
//! `XDICT_PHRASE_CENSUS_CORPUS` (or `XDICT_MDX_CORPUS`) lists folders searched two levels deep for `.mdx`.
//! `cargo test --release -p xdict-phrase --test store_census -- --nocapture`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::time::Instant;

use xdict_mdx::File;
use xdict_phrase::{Inventory, Slots, Versions};

fn dictionary_files(roots: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in std::env::split_paths(roots) {
        let mut stack = vec![(root, 0)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && depth < 2 {
                    stack.push((path, depth + 1));
                } else if path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("mdx")) {
                    out.push(path);
                }
            }
        }
    }
    out.sort();
    out
}

fn name(path: &Path) -> String {
    path.file_name().unwrap().to_string_lossy().into_owned()
}

#[test]
fn the_store_size_and_build_time_are_measured_per_edition() {
    let Ok(roots) = std::env::var("XDICT_PHRASE_CENSUS_CORPUS").or_else(|_| std::env::var("XDICT_MDX_CORPUS")) else {
        eprintln!("not measured: XDICT_PHRASE_CENSUS_CORPUS and XDICT_MDX_CORPUS are unset");
        return;
    };
    let files = dictionary_files(&roots);
    assert!(!files.is_empty(), "the corpus names no .mdx files");
    let slots = Slots::english().with_abbreviations();
    let versions = Versions { policy: 1, folding: 1 };
    let (mut total_phrases, mut total_bytes) = (0u64, 0u64);
    let mut measured = 0;
    eprintln!("file\tmultiword\tphrases\tstore_kib\tbuild_ms\tencode_ms");
    for path in &files {
        let Ok(file) = File::open(path) else {
            eprintln!("{}\topen failed", name(path));
            continue;
        };
        let mut keys: Vec<String> = Vec::new();
        let mut multiword = 0u64;
        for i in 0..file.len() {
            let Ok(public) = file.is_public(i) else { continue };
            if !public {
                continue;
            }
            let Ok(key) = file.key(i) else { continue };
            if key.split_whitespace().count() < 2 {
                continue;
            }
            multiword += 1;
            keys.push(key.into_owned());
        }
        let started = Instant::now();
        let inventory = Inventory::from_keys(keys, slots.clone());
        let build_ms = started.elapsed().as_secs_f64() * 1e3;
        let started = Instant::now();
        let bytes = inventory.encode(&name(path), versions);
        let encode_ms = started.elapsed().as_secs_f64() * 1e3;
        let phrases = inventory.phrases().len() as u64;
        total_phrases += phrases;
        total_bytes += bytes.len() as u64;
        measured += 1;
        eprintln!("{}\t{multiword}\t{phrases}\t{}\t{build_ms:.0}\t{encode_ms:.0}", name(path), bytes.len() / 1024);
    }
    eprintln!("TOTAL\t\t{total_phrases}\t{}\t", total_bytes / (1024 * 1024));
    eprintln!("{measured} files measured");
    assert!(measured > 0, "no file could be read, so the measurement says nothing");
}
