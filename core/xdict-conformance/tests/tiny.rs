//! The conformance scenario (`conformance/README.md`) against the core directly: what the Linux shell
//! calls, and the reference every binding's suite is held to.
//!
//! `XDICT_CONFORMANCE_EXPECTED` replaces `expected.json`, so a deliberately wrong expectation can be shown
//! to fail.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use xdict_core::*;

fn expected() -> Value {
    let path = std::env::var_os("XDICT_CONFORMANCE_EXPECTED")
        .map(PathBuf::from)
        .unwrap_or_else(|| xdict_conformance::fixtures().join("tiny/expected.json"));
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

/// Every field of `expected` is in `actual` and equal; lists have equal lengths.
fn subset(expected: &Value, actual: &Value, at: &str) -> Result<(), String> {
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
fn outcome<T: serde::Serialize>(result: Result<T, CoreError>) -> Value {
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

/// A file's bytes, served as a shell would serve them.
struct Bytes {
    bytes: Vec<u8>,
    identity: Option<FileIdentity>,
    short: bool,
}

impl ByteSource for Bytes {
    fn size(&self) -> u64 {
        self.bytes.len() as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        let start = offset as usize;
        let end = (start + len as usize).min(self.bytes.len()) - usize::from(self.short);
        Ok(self.bytes[start..end].to_vec())
    }
    fn identity(&self) -> Option<FileIdentity> {
        self.identity
    }
}

fn source(name: &str, bytes: Vec<u8>, identity: Option<FileIdentity>, short: bool) -> Location {
    Location::Source { name: name.into(), source: Arc::new(Bytes { bytes, identity, short }) }
}

#[test]
fn the_tiny_dictionary_conforms() {
    let x = expected();
    let dir = tempdir();
    xdict_conformance::write_fixture(&xdict_conformance::fixtures().join("tiny"), &dir).unwrap();
    let at = |name: &str| Location::Path { path: dir.join(name).to_string_lossy().into_owned() };
    let config = |client_protocol| Config { client_protocol, ..Config::default() };
    let view = |max: Option<u64>| View {
        base_url: x["view"]["baseUrl"].as_str().unwrap().into(),
        skin: None,
        max_body_bytes: max.unwrap_or(x["view"]["maxBodyBytes"].as_u64().unwrap()),
    };
    let mut failures = Vec::new();
    let mut check = |name: &str, expected: &Value, actual: Value| {
        if let Err(e) = subset(expected, &actual, name) {
            failures.push(e);
        }
    };

    check("versions", &x["versions"], outcome::<Versions>(Ok(Core::versions())));
    let client = x["newWrongProtocol"]["client"].as_u64().unwrap() as u32;
    check(
        "newWrongProtocol",
        &x["newWrongProtocol"]["error"],
        outcome(Core::new(config(client)).map(|_| ()))["error"].clone(),
    );

    let core = Core::new(config(PROTOCOL)).unwrap();
    let package = Package { mdx: at("tiny.mdx"), mdd: vec![at("tiny.mdd")], sidecars: vec![at("tiny.css")] };
    check("openBeforeImport", &x["openBeforeImport"], outcome(core.open(package.clone())));
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    check("import", &x["import"], outcome::<Imported>(Ok(imported.clone())));
    let opened = core.open(package).unwrap();
    check("open", &x["open"], outcome::<Opened>(Ok(opened.clone())));
    let Opened::Ready { dict, .. } = opened else { panic!("not open") };

    for (i, case) in x["lookups"].as_array().unwrap().iter().enumerate() {
        let options = LookupOptions {
            limit: case["limit"].as_u64().unwrap() as u32,
            offset: case["offset"].as_u64().unwrap() as u32,
            mode: MatchMode::Reader,
            generation: case["generation"].as_u64().map(|g| g as u32),
        };
        let got = outcome(core.lookup(case["query"].as_str().unwrap().into(), vec![dict.clone()], options));
        let want = if case.get("error").is_some() { json!({ "error": case["error"] }) } else { case["page"].clone() };
        check(&format!("lookups[{i}]"), &want, got);
    }
    for (i, case) in x["suggestions"].as_array().unwrap().iter().enumerate() {
        let got = core.suggest(
            case["prefix"].as_str().unwrap().into(),
            vec![dict.clone()],
            case["limit"].as_u64().unwrap() as u32,
        );
        check(&format!("suggestions[{i}]"), &case["keys"], outcome(got));
    }
    for (i, case) in x["entries"].as_array().unwrap().iter().enumerate() {
        let entry = EntryRef {
            edition: case["edition"].as_str().unwrap_or(&imported.edition).into(),
            key: case["entry"]["key"].as_str().unwrap().into(),
            occurrence: case["entry"]["occurrence"].as_u64().unwrap() as u32,
        };
        let got = core.entry(dict.clone(), entry, view(case["maxBodyBytes"].as_u64()));
        if let (Some(needle), Ok(e)) = (case["cspContains"].as_str(), &got) {
            check(&format!("entries[{i}].csp contains {needle:?}"), &json!(true), json!(e.csp.contains(needle)));
        }
        let want = if case.get("error").is_some() { json!({ "error": case["error"] }) } else { case["result"].clone() };
        check(&format!("entries[{i}]"), &want, outcome(got));
    }
    let origin =
        LinkOrigin::Entry { entry: EntryRef { edition: imported.edition.clone(), key: "run".into(), occurrence: 0 } };
    for (i, case) in x["links"].as_array().unwrap().iter().enumerate() {
        let got = core.link(dict.clone(), case["url"].as_str().unwrap().into(), origin.clone(), view(None));
        check(&format!("links[{i}]"), &case["link"], outcome(got));
    }
    for (i, case) in x["resources"].as_array().unwrap().iter().enumerate() {
        let got = core.resource(dict.clone(), case["path"].as_str().unwrap().into(), view(None));
        check(&format!("resources[{i}]"), &case["resource"], outcome(got));
    }

    let b = &x["byteSource"];
    let mdx = std::fs::read(dir.join("tiny.mdx")).unwrap();
    let identity: FileIdentity = serde_json::from_value(b["identity"].clone()).unwrap();
    let name = b["name"].as_str().unwrap();
    let copy = source(name, mdx.clone(), Some(identity), false);
    let sidecar =
        source(b["sidecar"]["name"].as_str().unwrap(), b["sidecar"]["text"].as_str().unwrap().into(), None, false);
    let package = Package { mdx: copy, mdd: vec![], sidecars: vec![sidecar] };
    check("byteSource.import", &b["import"], outcome(core.import(package.clone(), &NoProgress)));
    let opened = core.open(package).unwrap();
    check("byteSource.open", &b["open"], outcome::<Opened>(Ok(opened.clone())));
    let Opened::Ready { dict: second, .. } = opened else { panic!("not open") };
    check(
        "byteSource.resourceFromPath",
        &b["resourceFromPath"],
        outcome(core.resource(dict.clone(), "tiny.css".into(), view(None))),
    );
    check(
        "byteSource.resourceFromSource",
        &b["resourceFromSource"],
        outcome(core.resource(second.clone(), "tiny.css".into(), view(None))),
    );
    let short = Package { mdx: source("short.mdx", mdx, None, true), mdd: vec![], sidecars: vec![] };
    check("byteSource.shortRead", &b["shortRead"], outcome(core.import(short, &NoProgress)));

    let l = &x["lifecycle"];
    core.close(second.clone()).unwrap();
    let page = LookupOptions { limit: 10, offset: 0, mode: MatchMode::Reader, generation: None };
    check(
        "lifecycle.afterClose",
        &l["afterClose"],
        outcome(core.lookup("run".into(), vec![second.clone()], page.clone())),
    );
    check("lifecycle.closeTwice", &l["closeTwice"], json!(core.close(second).map(|()| "ok").unwrap_or("error")));
    let other = Core::new(config(PROTOCOL)).unwrap();
    check(
        "lifecycle.foreignHandle",
        &l["foreignHandle"],
        outcome(other.lookup("run".into(), vec![dict.clone()], page)),
    );
    check("lifecycle.panic", &l["panic"], outcome(core.self_test_panic()));

    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

fn tempdir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("xdict-conformance-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
