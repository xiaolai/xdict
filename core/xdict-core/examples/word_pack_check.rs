//! **Loads a word pack the way the reader's Mac will** and says what it holds: the check a generated pack passes
//! before it is published (plan-word-exploration WI-5). It reads the file through the same loader the service uses,
//! so a pack it accepts is a pack the app can install, and one it refuses fails with the sentence the Settings row
//! would show.
//!
//! ```sh
//! cargo run --release -p xdict-core --example word_pack_check -- ~/xdict-wordpack/pack/xdict-words-en.jsonl
//! ```

use std::collections::BTreeMap;
use std::fs::File;
use std::io::BufReader;

use xdict_core::words::{LexiconRecord, WordLexicon};

fn main() -> Result<(), String> {
    let Some(path) = std::env::args().nth(1) else {
        return Err("usage: word_pack_check <pack.jsonl>".into());
    };
    let file = File::open(&path).map_err(|error| format!("{path}: {error}"))?;
    let bytes = file.metadata().map_err(|error| format!("{path}: {error}"))?.len();
    let lexicon = WordLexicon::from_jsonl(BufReader::new(file)).map_err(|error| format!("{path}: {error}"))?;
    let mut counts: BTreeMap<&str, u64> = BTreeMap::new();
    for record in lexicon.records() {
        let kind = match record {
            LexiconRecord::Pronunciation(_) => "pronunciation",
            LexiconRecord::Form(_) => "form",
            LexiconRecord::Derivation(_) => "derivation",
            LexiconRecord::Origin(_) => "origin",
            LexiconRecord::Etymon(_) => "etymon",
            LexiconRecord::Sense(_) => "sense",
        };
        *counts.entry(kind).or_default() += 1;
    }
    let header = lexicon.header();
    let sources: Vec<&str> = header.sources.iter().map(|source| source.id.as_str()).collect();
    println!("pack {path} ({} bytes) loads as version {}", bytes, header.version);
    println!("sources: {}", sources.join(", "));
    for (kind, count) in &counts {
        println!("{kind}: {count}");
    }
    Ok(())
}
