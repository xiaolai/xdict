//! **Sync through the reader's own folder** (plan-history-and-learning §2.6, ADR-0027): two devices' logs merge by
//! content, study answers from the same revision meet as a conflict the reader resolves, and what travels carries no
//! dictionary text.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

const RUN: &str = r#"<div class="entry"><span class="hw">run</span><span class="sense">move fast</span></div>"#;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-sync-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn path(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn at(&self, name: &str) -> Location {
        Location::Path { path: self.0.join(name).to_string_lossy().into() }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A core whose ledger is a file of its own: two of these are two devices.
fn device(data: &std::path::Path) -> Core {
    Core::new(Config { client_protocol: PROTOCOL, data_dir: Some(data.to_string_lossy().into()), ..Config::default() })
        .unwrap()
}

/// Writes the dictionary under `dir` once and imports it into `core`.
fn import(core: &Core, dir: &Scratch, file: &str, title: &str, entries: &[W]) -> (String, String) {
    let path = dir.0.join(file);
    if !path.exists() {
        let mut spec = Spec::mdx();
        spec.title = title.into();
        std::fs::write(&path, writer::write(&spec, entries).unwrap()).unwrap();
    }
    let package = Package { mdx: dir.at(file), mdd: vec![], sidecars: vec![] };
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (dict, imported.edition),
        other => panic!("not open: {other:?}"),
    }
}

/// What the app does around a pass: this device's written log is put where the peers read.
fn deliver(out: &std::path::Path, inbox: &std::path::Path) {
    for entry in std::fs::read_dir(out).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|extension| extension == "xdlog") {
            std::fs::copy(&path, inbox.join(path.file_name().unwrap())).unwrap();
        }
    }
}

fn stamp(at: f64, device: &str) -> Stamp {
    Stamp { at, device: device.into() }
}

fn policy() -> ReviewPolicy {
    ReviewPolicy { retention: 0.9, maximum_days: 36_500 }
}

#[test]
fn two_devices_readings_merge_through_the_folder() {
    let dir = Scratch::new("readings");
    let (a_data, b_data, inbox) = (dir.path("a"), dir.path("b"), dir.path("meet"));
    let (out_a, out_b) = (dir.path("out-a"), dir.path("out-b"));
    let a = device(&a_data);
    let b = device(&b_data);
    let at = 1_790_640_000.0;
    let reading = Reading {
        surface: "run".into(),
        lemma: "run".into(),
        sentence: "They run each day.".into(),
        span: Some(ReadingSpan { start: 5, len: 3 }),
        cut: 0,
        quality: "complete".into(),
        edition: "mdx-sha256-v1:aa".into(),
        entry_key: "run".into(),
        occurrence: 0,
        dictionary_name: "Tiny".into(),
        language: "en".into(),
        at,
        device: "a".into(),
    };
    assert_eq!(a.ledger_record(reading, "a-1".into(), vec![]).unwrap(), RecordOutcome::Recorded);

    let (text, inbox_text) = (out_a.to_string_lossy().to_string(), inbox.to_string_lossy().to_string());
    let first = a.ledger_sync(inbox_text.clone(), text.clone(), "a".into()).unwrap();
    assert!(first.exported > 0, "this device's log is written for the others");
    assert_eq!(first.peers, 0, "nothing else is in the folder yet");
    deliver(&out_a, &inbox);

    let second = b.ledger_sync(inbox_text.clone(), out_b.to_string_lossy().to_string(), "b".into()).unwrap();
    assert_eq!(second.peers, 1);
    assert_eq!(second.added, 1, "the reading crossed");
    assert_eq!(b.ledger_history(at + 1.0, 0).unwrap().days.len(), 1);
    deliver(&out_b, &inbox);

    // The other direction converges, and a second pass adds nothing.
    let third = a.ledger_sync(inbox_text.clone(), text.clone(), "a".into()).unwrap();
    assert_eq!(third.added, 0, "b had nothing new");
    let fourth = a.ledger_sync(inbox_text, text, "a".into()).unwrap();
    assert_eq!((fourth.peers, fourth.added), (2, 0), "both devices' logs are in the inbox, and nothing is new");
}

#[test]
fn two_devices_grades_of_one_revision_are_a_conflict_the_reader_resolves() {
    let dir = Scratch::new("grades");
    let (a_data, b_data, inbox) = (dir.path("a"), dir.path("b"), dir.path("meet"));
    let (out_a, out_b) = (dir.path("out-a"), dir.path("out-b"));
    let a = device(&a_data);
    let b = device(&b_data);
    let (a_dict, edition) = import(&a, &dir, "a.mdx", "Test Dictionary", &[W::text("run", RUN)]);
    let (b_dict, _) = import(&b, &dir, "a.mdx", "Test Dictionary", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    let reference = |edition: &str| EntryRef { edition: edition.into(), key: "run".into(), occurrence: 0 };
    let note = a
        .study_note(a_dict, reference(&edition), "mine".into(), "Test Dictionary".into(), stamp(at, "a"), "n".into())
        .unwrap();
    let key = note.target.key();

    // Device b learns the note through the folder, then both grade the same revision offline.
    let inbox_text = inbox.to_string_lossy().to_string();
    a.ledger_sync(inbox_text.clone(), out_a.to_string_lossy().to_string(), "a".into()).unwrap();
    deliver(&out_a, &inbox);
    b.ledger_sync(inbox_text.clone(), out_b.to_string_lossy().to_string(), "b".into()).unwrap();
    deliver(&out_b, &inbox);
    let _ = b_dict;
    let queue = b.review_queue(at, 10).unwrap();
    assert_eq!(queue.len(), 1, "the note crossed, and enrols the card");
    assert_eq!(queue[0].target.key(), key);

    let a_out = a.review_grade(key.clone(), String::new(), 3, policy(), stamp(at + 10.0, "a"), "ga".into()).unwrap();
    let b_out = b.review_grade(key.clone(), String::new(), 1, policy(), stamp(at + 20.0, "b"), "gb".into()).unwrap();
    let (g_a, g_b) = (a_out.card.head.clone(), b_out.card.head.clone());
    assert_ne!(g_a, g_b);

    a.ledger_sync(inbox_text.clone(), out_a.to_string_lossy().to_string(), "a".into()).unwrap();
    deliver(&out_a, &inbox);
    b.ledger_sync(inbox_text.clone(), out_b.to_string_lossy().to_string(), "b".into()).unwrap();
    deliver(&out_b, &inbox);
    a.ledger_sync(inbox_text.clone(), out_a.to_string_lossy().to_string(), "a".into()).unwrap();
    for core in [&a, &b] {
        let conflicts = core.review_conflicts().unwrap();
        assert_eq!(conflicts.len(), 1, "one card, two answers");
        assert_eq!(conflicts[0].candidates.len(), 2);
        assert!(core.review_queue(at + 30.0, 10).unwrap().is_empty(), "not a card to grade, a question to answer");
    }

    // The reader keeps device a's answer on device a; the choice travels like any other event.
    let resolved = a.review_resolve(key.clone(), g_a.clone(), stamp(at + 40.0, "a"), "resolve".into()).unwrap();
    assert_eq!(resolved.outcome, RecordOutcome::Recorded);
    assert_eq!(resolved.card.head, g_a);
    a.ledger_sync(inbox_text.clone(), out_a.to_string_lossy().to_string(), "a".into()).unwrap();
    deliver(&out_a, &inbox);
    b.ledger_sync(inbox_text.clone(), out_b.to_string_lossy().to_string(), "b".into()).unwrap();
    assert!(b.review_conflicts().unwrap().is_empty(), "the resolution crossed");
    assert_eq!(b.review_queue(at + 41.0, 10).unwrap().len(), 0, "graded, not due");

    // A grade of a branch that is already resigned is refused, not written.
    let late = a.review_grade(key, g_b, 3, policy(), stamp(at + 50.0, "a"), "late".into()).unwrap();
    assert_eq!(late.outcome, RecordOutcome::Ineligible);
}

/// **What travels carries no dictionary text** (plan §5.3): the sync artifact holds the note, the evidence hash and the
/// grades, and never the definition they are about.
#[test]
fn the_sync_artifact_holds_no_definition() {
    let dir = Scratch::new("sentinel");
    let (a_data, inbox, out) = (dir.path("a"), dir.path("meet"), dir.path("out"));
    let a = device(&a_data);
    let (dict, edition) = import(&a, &dir, "a.mdx", "Test Dictionary", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    let reference = EntryRef { edition: edition.as_str().into(), key: "run".into(), occurrence: 0 };
    let hash = a.definition_hash_of(dict.clone(), reference.clone()).unwrap();
    a.study_note(dict, reference, "my own words".into(), "Test Dictionary".into(), stamp(at, "a"), "n".into()).unwrap();
    a.ledger_sync(inbox.to_string_lossy().to_string(), out.to_string_lossy().to_string(), "a".into()).unwrap();

    let artifact = std::fs::read(out.join("xdict-a.xdlog")).unwrap();
    let text = String::from_utf8_lossy(&artifact);
    assert!(text.contains(&hash), "the evidence travels");
    assert!(text.contains("my own words"), "the reader's own words travel");
    assert!(!text.contains("move fast"), "the definition never does");
    assert!(!text.contains("<div"), "nor its markup");
}
