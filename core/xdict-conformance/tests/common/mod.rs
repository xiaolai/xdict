//! What both suites share: the subset comparison and a result as the suites compare it.
#![allow(clippy::unwrap_used, dead_code)]

use serde_json::{Value, json};
use xdict_core::CoreError;

/// Every field of `expected` is in `actual` and equal; lists have equal lengths.
pub fn subset(expected: &Value, actual: &Value, at: &str) -> Result<(), String> {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => {
            for (key, value) in e {
                if key == "comment" {
                    continue;
                }
                let found = a.get(key).ok_or_else(|| format!("{at}.{key}: missing in {actual}"))?;
                subset(value, found, &format!("{at}.{key}"))?;
            }
            Ok(())
        }
        (Value::Array(e), Value::Array(a)) => {
            if e.len() != a.len() {
                return Err(format!("{at}: {} items expected, {} found: {actual}", e.len(), a.len()));
            }
            e.iter().zip(a).enumerate().try_for_each(|(i, (e, a))| subset(e, a, &format!("{at}[{i}]")))
        }
        _ if expected == actual => Ok(()),
        _ => Err(format!("{at}: expected {expected}, found {actual}")),
    }
}

/// A result as the suites compare it: the value, or `{"error": …}`; a resource's bytes as text.
pub fn outcome<T: serde::Serialize>(result: Result<T, CoreError>) -> Value {
    match result {
        Ok(value) => {
            let mut value = serde_json::to_value(value).unwrap();
            if value["type"] == "found"
                && let Some(bytes) = value.get("bytes").cloned()
            {
                let bytes: Vec<u8> = serde_json::from_value(bytes).unwrap();
                value["text"] = json!(String::from_utf8(bytes).unwrap());
            }
            value
        }
        Err(error) => json!({ "error": serde_json::to_value(error).unwrap() }),
    }
}
