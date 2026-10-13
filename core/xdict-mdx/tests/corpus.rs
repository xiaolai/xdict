//! The reader against real dictionaries, which never enter this repository.
//!
//! `XDICT_MDX_CORPUS` lists folders (`:`-separated, `;` on Windows) searched two levels deep for `.mdx` and
//! `.mdd` files. `XDICT_MDX_ORACLE` names a JSON list of `{"file": path, "entries": n}` produced by a
//! different reader, which every count is checked against. `XDICT_MDX_EVERY_KEY=1` looks up every key
//! instead of three, so every record block is decompressed and its checksum verified.
//! `XDICT_MDX_ANSWERS` names a JSON file of each file's answers, digested: written when it does not exist,
//! compared with when it does, so a change to the reader can be held to the answers it gave before. **Without
//! `XDICT_MDX_CORPUS` this test prints "not measured" and passes: a green run without it is not a
//! measurement.**
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use xdict_mdx::{File, Kind};
use xxhash_rust::xxh64::Xxh64;

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
                } else if matches!(
                    path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref(),
                    Some("mdx" | "mdd")
                ) {
                    out.push(path);
                }
            }
        }
    }
    out.sort();
    out
}

fn oracle() -> HashMap<PathBuf, u64> {
    let Ok(path) = std::env::var("XDICT_MDX_ORACLE") else { return HashMap::new() };
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("XDICT_MDX_ORACLE {path}: {e}"));
    let list: serde_json::Value = serde_json::from_str(&text).unwrap();
    list.as_array()
        .unwrap()
        .iter()
        .filter_map(|row| Some((PathBuf::from(row["file"].as_str()?), row["entries"].as_u64()?)))
        .collect()
}

fn name(path: &Path) -> String {
    path.file_name().unwrap().to_string_lossy().into_owned()
}

#[test]
fn every_dictionary_in_the_corpus_opens_and_answers() {
    let Ok(roots) = std::env::var("XDICT_MDX_CORPUS") else {
        eprintln!("not measured: XDICT_MDX_CORPUS is unset");
        return;
    };
    let files = dictionary_files(&roots);
    assert!(!files.is_empty(), "XDICT_MDX_CORPUS names no .mdx or .mdd files");
    let expected = oracle();
    let (mut failures, mut checked_against_oracle) = (Vec::new(), 0);
    let mut answers = serde_json::Map::new();

    for path in &files {
        let started = Instant::now();
        let file = match File::open(path) {
            Ok(file) => file,
            Err(e) => {
                failures.push(format!("{}: {e}", name(path)));
                continue;
            }
        };
        let opened = started.elapsed();
        if let Some(&n) = expected.get(path) {
            checked_against_oracle += 1;
            if file.len() as u64 != n {
                failures.push(format!("{}: {} keys, the oracle counts {n}", name(path), file.len()));
            }
        }
        // First, middle and last key, or every key: each must find at least its own record.
        let mut keys: Vec<String> = file.keys().map(|k| k.map(|k| k.into_owned())).collect::<Result<_, _>>().unwrap();
        let samples: Vec<usize> = if std::env::var_os("XDICT_MDX_EVERY_KEY").is_some() {
            keys.dedup();
            (0..keys.len()).collect()
        } else {
            vec![0, keys.len() / 2, keys.len().saturating_sub(1)]
        };
        let started = Instant::now();
        // Every answer, digested in order: the records' keys and bytes, or the kind of error.
        let mut digest = Xxh64::new(0);
        for &i in &samples {
            let Some(key) = keys.get(i) else { continue };
            digest.update(key.as_bytes());
            digest.update(&[0]);
            match file.lookup(key) {
                Ok(records) => {
                    for r in &records {
                        digest.update(r.key.as_bytes());
                        digest.update(&(r.data.len() as u64).to_le_bytes());
                        digest.update(&r.data);
                    }
                    if !records.iter().any(|r| r.key == *key) {
                        failures.push(format!("{}: {key:?} found nothing for itself", name(path)));
                    }
                }
                Err(e) => {
                    digest.update(format!("error {:?}", std::mem::discriminant(&e)).as_bytes());
                    failures.push(format!("{}: {key:?}: {e}", name(path)));
                }
            }
        }
        let answer = serde_json::json!({ "keys": file.len(), "lookups": samples.len(), "digest": format!("{:016x}", digest.digest()) });
        answers.insert(path.to_string_lossy().into_owned(), answer);
        let kind = if file.header().kind == Kind::Mdx { "mdx" } else { "mdd" };
        eprintln!(
            "{kind} {:>8} keys  open {:>6.0} ms  {} lookups {:>5.1} ms  {}",
            file.len(),
            opened.as_secs_f64() * 1e3,
            samples.len(),
            started.elapsed().as_secs_f64() * 1e3,
            name(path)
        );
    }
    eprintln!("{} files, {checked_against_oracle} checked against the oracle", files.len());
    if let Ok(path) = std::env::var("XDICT_MDX_ANSWERS") {
        let path = PathBuf::from(path);
        if path.exists() {
            let before: serde_json::Map<String, serde_json::Value> =
                serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            let mut compared = 0;
            for (file, then) in &before {
                match answers.get(file) {
                    Some(now) if now == then => compared += 1,
                    Some(now) => failures.push(format!("{file}: answered {now}, before {then}")),
                    None => failures.push(format!("{file}: answered before, not now")),
                }
            }
            eprintln!("{compared} of {} files answer as before", before.len());
        } else {
            std::fs::write(&path, serde_json::to_string_pretty(&answers).unwrap()).unwrap();
            eprintln!("answers of {} files written to {}", answers.len(), path.display());
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    if !expected.is_empty() {
        assert!(checked_against_oracle > 0, "XDICT_MDX_ORACLE is set but matched no file");
    }
}
