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

/// Every marked span of one class, in document order: its byte offset and its text.
fn spans<'a>(html: &'a str, class: &str) -> Vec<(usize, &'a str)> {
    let needle = format!("class=\"{class}\"");
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(at) = html[from..].find(&needle) {
        let at = from + at;
        let Some(open) = html[at..].find('>') else { break };
        let body = at + open + 1;
        let Some(end) = html[body..].find('<') else { break };
        out.push((at, html[body..body + end].trim()));
        from = body + end;
    }
    out
}

/// **The closed frame vocabulary**: the headword's own name in capitals becomes `HW`, so `VERB + BLOOD VESSEL` and
/// `VERB + TRUSTEE` are one frame; anything else keeps its words, and a frame outside this list is reported rather than
/// quietly widened.
fn frame(label: &str, headword: &str) -> Option<String> {
    // **The same word, spelled the same way**: the label and the headword are compared with case, hyphens and spaces
    // taken out (`ELECTRIC-SHOCK` is `electric shock`), and a leading `…` stands for the headword itself.
    let squash = |text: &str| -> String {
        text.to_uppercase().chars().filter(|c| c.is_alphanumeric() || *c == '+').collect()
    };
    let head = squash(headword);
    let mut normalized: String = squash(label);
    if !head.is_empty() {
        normalized = normalized.replace(&head, "HW");
    }
    let spaced = |frame: &str| -> String {
        frame.split('+').map(str::trim).collect::<Vec<_>>().join(" + ")
    };
    if let Some(rest) = normalized.strip_prefix("…") {
        normalized = format!("… + {}", spaced(rest).trim_start_matches(" + ").to_string());
        normalized = normalized.replace("… + HW", "… OF HW");
    }
    let normalized = spaced(&normalized).replace("…  OF HW", "… OF HW");
    let known = [
        "ADJECTIVE", "ADVERB", "NOUN", "VERB", "VERBS", "PREPOSITION", "PHRASES", "VERB + HW", "HW + VERB",
        "HW + NOUN", "NOUN + HW", "ADJECTIVE + HW", "… OF HW",
    ];
    known.contains(&normalized.as_str()).then_some(normalized)
}

/// One entry's collocations: the frame each collocate stands under, comma lists split.
fn pairs(html: &str) -> (String, Vec<(String, String)>) {
    let headword = spans(html, "ocd_hw").first().map(|(_, t)| t.to_string()).unwrap_or_default();
    let frames = spans(html, "ocd_ps");
    let collocates = spans(html, "ocd_co");
    let mut out = Vec::new();
    for (at, text) in &collocates {
        let frame = match frames.iter().rev().find(|(f, _)| f < at) {
            Some((_, label)) => match frame(label, &headword) {
                Some(known) => known,
                None => format!("?{label}"),
            },
            None => "?none".to_string(),
        };
        for word in text.split(',') {
            let word = word.trim();
            if !word.is_empty() {
                out.push((frame.clone(), word.to_string()));
            }
        }
    }
    (headword, out)
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
        let mut shown_pairs = 0usize;
        for i in (0..total).step_by(step).take(per_file) {
            let record = match file.record(i) {
                Ok(record) => record,
                Err(_) => continue,
            };
            let html = String::from_utf8_lossy(&record.data);
            let (headword, found) = pairs(&html);
            sampled += 1;
            if !found.is_empty() {
                with_chips += 1;
            }
            for (label, word) in &found {
                *frames.entry(label.clone()).or_default() += 1;
                if shown_pairs < 8 {
                    shown_pairs += 1;
                    println!("pair: {headword} | {label} | {word}");
                }
            }
            let _ = &mut shown;
        }
        println!("=== {name}: {total} records, {sampled} sampled, {with_chips} with ocd_ps frames");
        let mut by_count: Vec<_> = frames.into_iter().collect();
        by_count.sort_by(|a, b| b.1.cmp(&a.1));
        for (chip, count) in by_count.iter().take(40) {
            println!("  {count:>5}  {chip}");
        }
    }
}
