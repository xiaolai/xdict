//! **What the reader's collocation dictionaries actually write**: the frame vocabulary WI-6's closed list must come
//! from, measured over real entries rather than guessed from a stylesheet.
//!
//! `cargo run --release -p xdict-entry --example colloc_spike -- <corpus dir> [entries per file]`
//!
//! For every `.mdx` whose name holds `ocd` (the Oxford Collocations Dictionary) or `oald`/`ldoce`, it prints the
//! `ocd_pos` chips — `ADJ.`, `VERB +`, and so on — that head each collocate group, counted, plus a few whole entries so
//! the shape can be read. No dictionary content leaves the machine: only labels and counts are printed.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use xdict_mdx::File;

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
    File::open(path).unwrap()
}

/// Every `class="ocd_pos"` span's text, in order.
fn chips(html: &str, class: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(at) = rest.find(class) {
        rest = &rest[at + class.len()..];
        let Some(open) = rest.find('>') else { break };
        let after = &rest[open + 1..];
        let Some(end) = after.find('<') else { break };
        let text = after[..end].trim();
        if !text.is_empty() {
            out.push(text.to_string());
        }
        rest = &after[end..];
    }
    out
}

fn main() {
    let Some(root) = std::env::args().nth(1) else {
        eprintln!("usage: colloc_spike <corpus dir> [entries per file]");
        std::process::exit(2);
    };
    let per_file: usize = std::env::args().nth(2).and_then(|n| n.parse().ok()).unwrap_or(20);
    let mut files = Vec::new();
    mdx_files(Path::new(&root), &mut files);
    for path in &files {
        // **The folder names the dictionary; the file names the edition** (the corpus keeps one folder per
        // dictionary: `ocd/`, `oald/`, `oalecd/`, `ldoce/`).
        let name = path.file_name().unwrap_or_default().to_string_lossy().to_lowercase();
        let folder = path.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().to_lowercase());
        let folder = folder.unwrap_or_default();
        let wanted = |n: &str| n.contains("ocd") || n.contains("oald") || n.contains("ldoce") || n.contains("oalecd");
        if !(wanted(&folder) || wanted(&name)) {
            continue;
        }
        let file = open(path);
        let total = file.len();
        let step = (total / per_file.max(1)).max(1);
        let mut frames: BTreeMap<String, usize> = BTreeMap::new();
        let mut with_chips = 0usize;
        let mut sampled = 0usize;
        let mut shown = 0usize;
        for i in (0..total).step_by(step).take(per_file) {
            let record = match file.record(i) {
                Ok(record) => record,
                Err(_) => continue,
            };
            let html = String::from_utf8_lossy(&record.data);
            let found = chips(&html, "ocd_ps");
            sampled += 1;
            if !found.is_empty() {
                with_chips += 1;
                for chip in &found {
                    *frames.entry(chip.clone()).or_default() += 1;
                }
            }
            if shown < 1 && found.len() > 1 {
                shown += 1;
                println!("--- {} #{} frames: {:?}", name, i, found);
                let start = 0;
                let end = (start + 1200).min(html.len());
                println!("{}", html[start..end].replace('\n', " "));
            }
        }
        println!("=== {name}: {total} records, {sampled} sampled, {with_chips} with ocd_ps frames");
        let mut by_count: Vec<_> = frames.into_iter().collect();
        by_count.sort_by(|a, b| b.1.cmp(&a.1));
        for (chip, count) in by_count.iter().take(40) {
            println!("  {count:>5}  {chip}");
        }
    }
}
