//! The plan's gate, over the pinned sources: a build whose pack, notices and report are byte-identical to the
//! reference implementation's, and the record counts it promises.
//!
//! ```sh
//! XDICT_WORD_PACK_RAW=~/xdict-wordpack/raw \
//!   cargo test --release -p xdict-pack --test parity -- --nocapture
//! ```
//!
//! Without the variable the test says so and passes: a green run without it is not a measurement.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use xdict_pack::{BuildOptions, Control, build};

/// `f33954be…c691b7a8`, the pack the reference implementation writes from the pinned sources (2026-10-28).
const PACK_SHA256: &str = "f33954be3b147fc7da87dba9b5fd6b11314aaa8e268b21137da407b0c691b7a8";
/// The notices sidecar beside it, which names `xdict-pack` as the builder and `word_lexicon.py` as its reference.
const NOTICES_SHA256: &str = "b8022ca19c24b8b8439909513ec9588281b2d5bb9069d467f33c09fffd9ab38a";

fn manifest() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.push("xdict-core");
    path.push("tools");
    path.push("word_lexicon_sources.json");
    path
}

fn raw_dir() -> Option<PathBuf> {
    std::env::var_os("XDICT_WORD_PACK_RAW").map(PathBuf::from).filter(|path| path.is_dir())
}

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("xdict-pack-parity-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    path.join("xdict-words-en.jsonl")
}

fn run(output: &Path) -> xdict_pack::Report {
    let options = BuildOptions::new(raw_dir().expect("the guard checked this"), output, manifest());
    build(&options, &mut |_event| Control::Continue).expect("the pinned build succeeds")
}

#[test]
fn a_build_from_the_pinned_sources_is_the_reference_packs_bytes() {
    let Some(_) = raw_dir() else {
        println!("not measured: set XDICT_WORD_PACK_RAW to the directory holding the pinned downloads");
        return;
    };
    let first = run(&scratch("one"));
    let second = run(&scratch("two"));
    assert_eq!(first.pack_sha256, PACK_SHA256, "the pack's SHA-256 is the reference implementation's");
    assert_eq!(second.pack_sha256, PACK_SHA256, "a second run is the same bytes");
    assert_eq!(first.notices_sha256, NOTICES_SHA256, "the notices sidecar is the reference implementation's");
    assert_eq!(
        std::fs::read(&first.pack).unwrap(),
        std::fs::read(&second.pack).unwrap(),
        "two runs are byte-identical to each other"
    );
    assert_eq!(
        std::fs::read(&first.notices).unwrap(),
        std::fs::read(&second.notices).unwrap(),
        "two notices sidecars are byte-identical to each other"
    );
}

#[test]
fn every_record_count_is_the_reference_builders() {
    let Some(_) = raw_dir() else {
        println!("not measured: set XDICT_WORD_PACK_RAW to the directory holding the pinned downloads");
        return;
    };
    let report = run(&scratch("counts"));
    let expected: BTreeMap<&str, usize> = BTreeMap::from([
        ("derivation", 437_361),
        ("etymon", 166_503),
        ("form", 223_517),
        ("origin", 189_129),
        ("pronunciation", 178_698),
        ("sense", 293_511),
    ]);
    assert_eq!(report.records, expected);
    let parsed: BTreeMap<(&str, &str), u64> = BTreeMap::from([
        (("cmu", "pronunciation"), 135_166),
        (("ety", "derivation"), 211_899),
        (("ety", "etymon"), 166_503),
        (("ety", "origin"), 189_129),
        (("morphynet-deri", "derivation"), 205_267),
        (("morphynet-infl", "form"), 223_876),
        (("oewn", "derivation"), 73_534),
        (("oewn", "pronunciation"), 43_534),
        (("oewn", "sense"), 301_518),
    ]);
    for ((source, kind), count) in parsed {
        let held = report.parsed_by_source.get(source).and_then(|types| types.get(kind)).copied();
        assert_eq!(held, Some(count), "{source}'s {kind} records");
    }
    assert!(report.rejected.is_empty(), "no record is over a loader bound: {:?}", report.rejected);
    assert_eq!(
        report.source_ids,
        ["cmu", "ety", "morphynet-deri", "morphynet-infl", "oewn"],
        "the header lists every source, in id order"
    );
}

#[test]
fn the_zip_lists_its_seventy_three_members_and_reads_one() {
    let Some(raw) = raw_dir() else {
        println!("not measured: set XDICT_WORD_PACK_RAW to the directory holding the pinned downloads");
        return;
    };
    let zip = xdict_pack::zip::Zip::open(&raw.join("oewn-2025-json.zip"), "oewn").unwrap();
    assert_eq!(zip.entries().len(), 73, "the pinned archive's members");
    let names: Vec<&str> = zip.entries().iter().map(|entry| entry.name.as_str()).collect();
    assert!(names.contains(&"entries-p.json"), "the members are the archive's own names");
    let entry = zip.entries().iter().find(|entry| entry.name == "entries-p.json").unwrap();
    let data = zip.read(entry, "oewn").unwrap();
    assert_eq!(data.len() as u64, entry.uncompressed, "the member inflates to its declared size");
    let parsed: serde_json::Value = serde_json::from_slice(&data).unwrap();
    assert!(parsed.as_object().is_some_and(|object| !object.is_empty()), "entries-p.json is an object of lemmas");
}

/// **The ancestry graph's size over the pinned file**, which is what decision 4's bound is set against: the graph is
/// held whole, and it is what a Mac with 8 GB must carry before a single record is written.
#[test]
fn the_ancestry_graph_is_within_its_bound() {
    let Some(raw) = raw_dir() else {
        println!("not measured: set XDICT_WORD_PACK_RAW to the directory holding the pinned downloads");
        return;
    };
    let file = std::fs::File::open(raw.join("etymology-2023-12.csv.gz")).unwrap();
    let graph = xdict_pack::etymology::parse_etymology_csv(
        xdict_pack::sources::gzip_reader(file),
        "ety",
        &std::sync::atomic::AtomicBool::new(false),
    )
    .expect("the pinned file parses");
    println!("ancestry graph: {} nodes, {} edges", graph.node_count(), graph.edge_count());
    assert!(graph.node_count() as u64 <= xdict_pack::limits::MAX_GRAPH_NODES, "{} nodes", graph.node_count());
    assert!(graph.edge_count() <= xdict_pack::limits::MAX_GRAPH_EDGES, "{} edges", graph.edge_count());
}

/// **The report too, not only the pack and the notices** (audit 2026-10-28): the reference implementation's report,
/// checked in as `tests/fixtures/xdict-words-en.report.json` with its two path fields blanked — the only part of it a
/// machine decides. Everything else in it, the counts, the samples and the two hashes, is held byte for byte.
#[test]
fn the_report_is_the_reference_builders() {
    let Some(_) = raw_dir() else {
        println!("not measured: set XDICT_WORD_PACK_RAW to the directory holding the pinned downloads");
        return;
    };
    let report = run(&scratch("report"));
    let mut parsed: serde_json::Value = serde_json::from_str(&report.report_text).expect("the report is JSON");
    parsed["pack"] = serde_json::Value::String(String::new());
    parsed["notices"] = serde_json::Value::String(String::new());
    let normalised = format!("{}\n", serde_json::to_string_pretty(&parsed).expect("re-serialised"));
    let expected = include_str!("fixtures/xdict-words-en.report.json");
    // `to_string_pretty` indents two and sorts nothing: serde_json's map is already sorted, as the writer's is.
    assert_eq!(normalised, expected, "the report is the reference implementation's, its paths aside");
}
