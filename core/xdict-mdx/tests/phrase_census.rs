//! The phrase census (`dev-docs/plan-phrase-recognition.md` WI-1): how many multi-word headwords the reader's own
//! dictionaries carry, what scripts they are in, how long they are, and what placeholder slots they use. A
//! measurement, not a gate: without the variable it says "not measured" and passes, because a green run over nothing
//! is not a measurement.
//!
//! `XDICT_PHRASE_CENSUS_CORPUS` lists folders (`:`-separated, `;` on Windows) searched two levels deep for `.mdx`;
//! `XDICT_MDX_CORPUS` is used when it is unset, so the corpus the other measurements name is the default.
//! `cargo test --release -p xdict-mdx --test phrase_census -- --nocapture`.
//!
//! What it does not measure: whether a phrase's entry carries senses (that needs the core's entry projection and an
//! import per dictionary), and whether a found span is the unit a reader met (that needs a person-read sample). Both
//! are stated in the plan; neither is claimed here.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};
use std::time::Instant;

use xdict_mdx::File;

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

/// A letter belongs to the Latin script by its code point: ASCII, Latin-1 Supplement and Extended-A/B, and Latin
/// Extended Additional. A combining mark is neutral. Every other alphabetic character is "other" — the CJK, Hangul,
/// Cyrillic and Greek keys the census must keep out of the phrase inventory.
fn letter_script(c: char) -> Option<bool> {
    if !c.is_alphabetic() {
        return None;
    }
    let code = c as u32;
    let latin = c.is_ascii_alphabetic() || (0x00C0..=0x024F).contains(&code) || (0x1E00..=0x1EFF).contains(&code);
    Some(latin)
}

#[derive(Default)]
struct Tally {
    keys: u64,
    public: u64,
    multiword: u64,
    latin: u64,
    other: u64,
    mixed: u64,
    no_letters: u64,
    words: [u64; 5],
    slot_english: u64,
    slot_abbreviation: u64,
    slot_tilde: u64,
    longest: usize,
    longest_key: String,
}

/// The placeholder words the corpus spells. Tokens are compared whole: `something` is a slot, `some` is not, and a
/// hyphenated `sb-sth` is not an abbreviation slot.
const ENGLISH_SLOTS: [&str; 6] = ["something", "someone", "somebody", "oneself", "one's", "somebody's"];
const ABBREVIATION_SLOTS: [&str; 6] = ["sb", "sth", "sb's", "sth's", "sb.", "sth."];

fn is_slot(token: &str) -> (bool, bool, bool) {
    let word = token.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'').to_lowercase();
    let english = ENGLISH_SLOTS.contains(&word.as_str());
    let abbreviation = ABBREVIATION_SLOTS.contains(&word.as_str());
    (english, abbreviation, token.contains('~'))
}

#[test]
fn the_census_counts_multiword_headwords_and_their_shapes() {
    let Ok(roots) =
        std::env::var("XDICT_PHRASE_CENSUS_CORPUS").or_else(|_| std::env::var("XDICT_MDX_CORPUS"))
    else {
        eprintln!("not measured: XDICT_PHRASE_CENSUS_CORPUS and XDICT_MDX_CORPUS are unset");
        return;
    };
    let files = dictionary_files(&roots);
    assert!(!files.is_empty(), "the corpus names no .mdx files");
    let mut total = Tally::default();
    let mut measured = 0;
    eprintln!(
        "file\tkeys\tpublic\tmultiword\tlatin\tother\tmixed\tnoletters\t2w\t3w\t4w\t5w\t6w+\tslot_en\tslot_abbr\tslot_tilde\tlongest\tms"
    );
    for path in &files {
        let started = Instant::now();
        let file = match File::open(path) {
            Ok(file) => file,
            Err(e) => {
                eprintln!("{}\topen failed: {e}", name(path));
                continue;
            }
        };
        let mut t = Tally { keys: file.len() as u64, ..Tally::default() };
        for i in 0..file.len() {
            let Ok(public) = file.is_public(i) else { continue };
            if !public {
                continue;
            }
            t.public += 1;
            let Ok(key) = file.key(i) else { continue };
            let words: Vec<&str> = key.split_whitespace().collect();
            if words.len() < 2 {
                continue;
            }
            t.multiword += 1;
            let (mut latin, mut other) = (false, false);
            for c in key.chars() {
                match letter_script(c) {
                    Some(true) => latin = true,
                    Some(false) => other = true,
                    None => {}
                }
            }
            match (latin, other) {
                (true, true) => t.mixed += 1,
                (true, false) => t.latin += 1,
                (false, true) => t.other += 1,
                (false, false) => t.no_letters += 1,
            }
            let bucket = words.len().clamp(2, 6) - 2;
            t.words[bucket] += 1;
            let (mut english, mut abbreviation, mut tilde) = (false, false, false);
            for word in &words {
                let (e, a, s) = is_slot(word);
                english |= e;
                abbreviation |= a;
                tilde |= s;
            }
            t.slot_english += u64::from(english);
            t.slot_abbreviation += u64::from(abbreviation);
            t.slot_tilde += u64::from(tilde);
            if key.chars().count() > t.longest {
                t.longest = key.chars().count();
                t.longest_key = key.to_string();
            }
        }
        measured += 1;
        eprintln!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{:.0}",
            name(path),
            t.keys,
            t.public,
            t.multiword,
            t.latin,
            t.other,
            t.mixed,
            t.no_letters,
            t.words[0],
            t.words[1],
            t.words[2],
            t.words[3],
            t.words[4],
            t.slot_english,
            t.slot_abbreviation,
            t.slot_tilde,
            t.longest,
            started.elapsed().as_secs_f64() * 1e3
        );
        if !t.longest_key.is_empty() {
            eprintln!("  longest in {}: {:?}", name(path), t.longest_key);
        }
        total.keys += t.keys;
        total.public += t.public;
        total.multiword += t.multiword;
        total.latin += t.latin;
        total.other += t.other;
        total.mixed += t.mixed;
        total.no_letters += t.no_letters;
        for i in 0..5 {
            total.words[i] += t.words[i];
        }
        total.slot_english += t.slot_english;
        total.slot_abbreviation += t.slot_abbreviation;
        total.slot_tilde += t.slot_tilde;
        if t.longest > total.longest {
            total.longest = t.longest;
            total.longest_key = t.longest_key.clone();
        }
    }
    eprintln!(
        "TOTAL\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
        total.keys,
        total.public,
        total.multiword,
        total.latin,
        total.other,
        total.mixed,
        total.no_letters,
        total.words[0],
        total.words[1],
        total.words[2],
        total.words[3],
        total.words[4],
        total.slot_english,
        total.slot_abbreviation,
        total.slot_tilde,
        total.longest
    );
    eprintln!("{measured} files measured");
    assert!(measured > 0, "no file could be read, so the census says nothing");
}
