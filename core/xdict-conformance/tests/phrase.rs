//! The phrase contract (`conformance/phrase/CONTRACT.md`) against the core directly: the same `vectors.jsonl` every
//! binding's suite runs, held here first so a wrong vector costs the core gate rather than three binding runs.
//!
//! `XDICT_CONFORMANCE_PHRASE` replaces `conformance/phrase/vectors.jsonl`, so a deliberately wrong expectation can be
//! shown to fail.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use xdict_core::*;

mod common;
use common::{outcome, subset};

fn vectors() -> PathBuf {
    std::env::var_os("XDICT_CONFORMANCE_PHRASE")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance/phrase/vectors.jsonl"))
}

fn tempdir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("xdict-conformance-phrase-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The answer as a suite compares it: its dictionary handles are the vector's `phrase` label, since a handle differs
/// from core to core.
fn labelled(mut value: Value) -> Value {
    for field in ["matches", "coverage"] {
        if let Some(items) = value.get_mut(field).and_then(Value::as_array_mut) {
            for item in items {
                if item.get("dict").is_some() {
                    item["dict"] = json!("phrase");
                }
            }
        }
    }
    value
}

#[test]
fn the_phrase_vectors_conform() {
    let text = std::fs::read_to_string(vectors()).unwrap();
    let dir = tempdir();
    xdict_conformance::write_fixture(&xdict_conformance::fixtures().join("phrase"), &dir).unwrap();
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap();
    let package = Package { mdx: Location::Path { path: dir.join("phrase.mdx").to_string_lossy().into_owned() }, mdd: vec![], sidecars: vec![] };
    core.import(package.clone(), &NoProgress).unwrap();
    let Opened::Ready { dict, .. } = core.open(package).unwrap() else { panic!("the fixture did not open") };

    let mut failures = Vec::new();
    let mut check = |name: &str, expected: &Value, actual: &Value| {
        if let Err(e) = subset(expected, actual, name) {
            failures.push(e);
        }
    };
    for (number, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let case: Value =
            serde_json::from_str(line).unwrap_or_else(|e| panic!("vectors.jsonl line {}: {e}", number + 1));
        let name = case["name"].as_str().unwrap_or("case");
        match case["kind"].as_str().unwrap() {
            // The inventory's build: the fixture's phrases counted, and a second build answering from the store.
            "build" => check(&format!("{name}.build"), &case["expect"], &outcome(core.phrases_build(dict.clone(), &NoProgress))),
            "vector" => {
                let sentence = case["sentence"].as_str().unwrap().to_string();
                let location = case["term"]["location"].as_u64().unwrap();
                let length = case["term"]["length"].as_u64().unwrap();
                let answer = labelled(outcome(core.phrases(sentence, location, length, vec![dict.clone()])));
                let mut expected = if case.get("error").is_some() { json!({ "error": case["error"] }) } else { case["expect"].clone() };
                // A capped list says how many it kept without writing all of them into the vector.
                if let Some(count) = expected.as_object_mut().and_then(|object| object.remove("matchCount")) {
                    let matches = answer["matches"].as_array().map_or(0, Vec::len);
                    check(&format!("{name}.matchCount"), &count, &json!(matches));
                }
                check(name, &expected, &answer);
            }
            other => panic!("vectors.jsonl line {}: no kind {other}", number + 1),
        }
    }
    assert!(failures.is_empty(), "{} phrase failures:\n  {}", failures.len(), failures.join("\n  "));
}
