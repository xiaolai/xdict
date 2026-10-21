//! **The conformance vectors, through the core.** `conformance/ledger/cases.json` is the same file every binding runs
//! through its own API (ADR-0023, ADR-0024); this test keeps the file honest against the core, so a binding cannot
//! agree with a vector the core has left behind.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;
use xdict_ledger::{Ledger, MemoryStore, Reading};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cases {
    readings: Vec<Case>,
    history: HistoryCase,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    operation: String,
    target_languages: Vec<String>,
    expect: String,
    reading: Reading,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryCase {
    now: f64,
    utc_offset_seconds: i32,
    expect: Value,
}

/// Every field `expected` names must be present and equal; lists must have equal lengths and order. The bindings'
/// subset comparison, in one place.
fn subset(expected: &Value, actual: &Value, at: &str) -> Result<(), String> {
    match expected {
        Value::Object(fields) => {
            let actual = actual.as_object().ok_or_else(|| format!("{at}: expected an object, found {actual:?}"))?;
            for (key, value) in fields {
                let found = actual.get(key).ok_or_else(|| format!("{at}.{key}: missing in {actual:?}"))?;
                subset(value, found, &format!("{at}.{key}"))?;
            }
            Ok(())
        }
        Value::Array(items) => {
            let actual = actual.as_array().ok_or_else(|| format!("{at}: expected an array, found {actual:?}"))?;
            if items.len() != actual.len() {
                return Err(format!("{at}: expected {} entries, found {}: {actual:?}", items.len(), actual.len()));
            }
            for (index, item) in items.iter().enumerate() {
                subset(item, &actual[index], &format!("{at}[{index}]"))?;
            }
            Ok(())
        }
        _ => {
            // Numbers compare by value: the vector writes whole seconds as integers, the core serialises them as f64.
            if let (Some(expected), Some(actual)) = (expected.as_f64(), actual.as_f64()) {
                return if expected == actual {
                    Ok(())
                } else {
                    Err(format!("{at}: expected {expected}, found {actual}"))
                };
            }
            if expected == actual { Ok(()) } else { Err(format!("{at}: expected {expected}, found {actual}")) }
        }
    }
}

#[test]
fn the_bindings_conformance_vectors_hold_in_the_core() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance/ledger/cases.json");
    let text = std::fs::read_to_string(&path).expect("conformance/ledger/cases.json is part of the tree");
    let cases: Cases = serde_json::from_str(&text).expect("the vectors are well formed");

    let mut ledger = Ledger::open(Arc::new(MemoryStore::default())).expect("a fresh in-memory log");
    for case in &cases.readings {
        let outcome = ledger
            .record(case.reading.clone(), &case.operation, &case.target_languages)
            .expect("a reading of the vectors is valid");
        let actual = serde_json::to_value(outcome).expect("an outcome is a word");
        assert_eq!(actual, Value::String(case.expect.clone()), "operation {}", case.operation);
    }

    let history = ledger.history(cases.history.now, cases.history.utc_offset_seconds);
    let actual = serde_json::to_value(&history).expect("a history is JSON");
    if let Err(why) = subset(&cases.history.expect, &actual, "history") {
        panic!("{why}");
    }
}
