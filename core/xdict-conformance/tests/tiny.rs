//! The conformance scenario (`conformance/README.md`) against the core directly: what the Linux shell
//! calls, and the reference every binding's suite is held to.
//!
//! `XDICT_CONFORMANCE_EXPECTED` replaces `expected.json`, so a deliberately wrong expectation can be shown
//! to fail.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use xdict_core::*;

mod common;
use common::{outcome, subset};

fn expected() -> Value {
    let path = std::env::var_os("XDICT_CONFORMANCE_EXPECTED")
        .map(PathBuf::from)
        .unwrap_or_else(|| xdict_conformance::fixtures().join("tiny/expected.json"));
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
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

/// A progress that cancels at once.
struct Stop;

impl Progress for Stop {
    fn progress(&self, _: u64, _: u64) -> bool {
        false
    }
}

/// A sidecar whose identity the suite changes after it is opened, as a moved or rewritten file's would.
struct Moving {
    text: Vec<u8>,
    identity: Mutex<FileIdentity>,
}

impl ByteSource for Moving {
    fn size(&self) -> u64 {
        self.text.len() as u64
    }
    fn read_at(&self, offset: u64, len: u32) -> Result<Vec<u8>, CoreError> {
        let start = offset as usize;
        Ok(self.text[start..(start + len as usize).min(self.text.len())].to_vec())
    }
    fn identity(&self) -> Option<FileIdentity> {
        Some(*self.identity.lock().unwrap())
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

    // The generation each lookup returned, for the cases that continue it (`{ "of": n }`).
    let mut generations: Vec<Option<u64>> = Vec::new();
    for (i, case) in x["lookups"].as_array().unwrap().iter().enumerate() {
        let generation = match &case["generation"] {
            Value::Null => None,
            g => Some(g["of"].as_u64().and_then(|n| generations[n as usize]).expect("a page that gave a generation")),
        };
        let options = LookupOptions {
            limit: case["limit"].as_u64().unwrap() as u32,
            offset: case["offset"].as_u64().unwrap() as u32,
            mode: if case["mode"] == "link" { MatchMode::Link } else { MatchMode::Reader },
            generation: generation.map(|g| g as u32),
        };
        let got = outcome(core.lookup(case["query"].as_str().unwrap().into(), vec![dict.clone()], options));
        generations.push(got["generation"].as_u64());
        let want = if case.get("error").is_some() { json!({ "error": case["error"] }) } else { case["page"].clone() };
        check(&format!("lookups[{i}]"), &want, got);
    }
    for (i, case) in x["suggestions"].as_array().unwrap().iter().enumerate() {
        let got = core.suggest(
            case["prefix"].as_str().unwrap().into(),
            vec![dict.clone()],
            case["limit"].as_u64().unwrap() as u32,
        );
        let want = if case.get("error").is_some() { json!({ "error": case["error"] }) } else { case["keys"].clone() };
        check(&format!("suggestions[{i}]"), &want, outcome(got));
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
    check("health", &x["health"], outcome(core.health(dict.clone(), &NoProgress)));

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

    let e = &x["errors"];
    for name in ["unsupported", "malformed", "notFound"] {
        let package = Package { mdx: at(e[name]["file"].as_str().unwrap()), mdd: vec![], sidecars: vec![] };
        let got = outcome(core.import(package, &NoProgress));
        check(&format!("errors.{name}"), &json!({ "error": e[name]["error"] }), got);
    }
    let alone = Package { mdx: at("tiny.mdx"), mdd: vec![], sidecars: vec![] };
    check("errors.cancelled", &json!({ "error": e["cancelled"]["error"] }), outcome(core.import(alone, &Stop)));
    let moving =
        Arc::new(Moving { text: b["sidecar"]["text"].as_str().unwrap().into(), identity: Mutex::new(identity) });
    let package = Package {
        mdx: source(name, std::fs::read(dir.join("tiny.mdx")).unwrap(), Some(identity), false),
        mdd: vec![],
        sidecars: vec![Location::Source { name: "tiny.css".into(), source: moving.clone() }],
    };
    core.import(package.clone(), &NoProgress).unwrap();
    let Opened::Ready { dict: watched, .. } = core.open(package).unwrap() else { panic!("not open") };
    moving.identity.lock().unwrap().inode += 1;
    check(
        "errors.sourceChanged",
        &json!({ "error": e["sourceChanged"]["error"] }),
        outcome(core.resource(watched, "tiny.css".into(), view(None))),
    );

    // The reader's joins and splits; each lineage answered is compared as a label, since ids are minted at random.
    let n = &x["lineages"];
    let rebuilt = Package { mdx: at(n["file"].as_str().unwrap()), mdd: vec![], sidecars: vec![] };
    let rebuilt = core.import(rebuilt, &NoProgress).unwrap();
    let label = |v: Value| match v.as_str() {
        Some(id) if id == imported.lineage => json!("tiny"),
        Some(id) if id == rebuilt.lineage => json!("rebuilt"),
        _ => v,
    };
    let mut got = outcome::<Imported>(Ok(rebuilt.clone()));
    got["lineage"] = label(got["lineage"].clone());
    check("lineages.import", &n["import"], got);
    let edition = rebuilt.edition.clone();
    let lineage_of = |e: &str| label(outcome(core.lineage_of(e.into())));
    let join = |e: &str, l: &str| label(outcome(core.join_lineage(e.into(), l.into())));
    let split = |e: &str, l: &str| label(outcome(core.split_lineage(e.into(), l.into())));
    check("lineages.before", &n["before"], lineage_of(&edition));
    check("lineages.join", &n["join"], join(&edition, &imported.lineage));
    check("lineages.afterJoin", &n["afterJoin"], lineage_of(&edition));
    check("lineages.joinAgain", &n["joinAgain"], join(&edition, &imported.lineage));
    check("lineages.split", &n["split"], split(&edition, &rebuilt.lineage));
    check("lineages.afterSplit", &n["afterSplit"], lineage_of(&edition));
    let new = n["newLineage"].as_str().unwrap();
    check("lineages.splitToNew", &n["splitToNew"], split(&edition, new));
    check("lineages.splitToNewAgain", &n["splitToNewAgain"], split(&edition, new));
    let unknown = n["unknownEdition"].as_str().unwrap();
    check("lineages.joinUnknownEdition", &n["joinUnknownEdition"], join(unknown, &imported.lineage));
    check("lineages.lineageOfUnknownEdition", &n["lineageOfUnknownEdition"], lineage_of(unknown));
    let nobody = n["unknownLineage"].as_str().unwrap();
    check("lineages.joinUnknownLineage", &n["joinUnknownLineage"], join(&edition, nobody));
    let not_one = n["notALineage"].as_str().unwrap();
    check("lineages.splitNotALineage", &n["splitNotALineage"], split(&edition, not_one));
    check("lineages.splitIntoAnother", &n["splitIntoAnother"], split(&imported.edition, &rebuilt.lineage));

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
