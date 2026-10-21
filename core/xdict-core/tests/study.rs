//! **The study API through the core** (plan-history-and-learning §5): a note enrols an entry, a grade schedules it under
//! the reader's configuration, an undo voids the latest grade, and a re-anchor moves a note only while its definition is
//! still there.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use xdict_core::*;
use xdict_mdx_writer::{self as writer, Entry as W, Spec};

const RUN: &str = r#"<div class="entry"><span class="hw">run</span><span class="sense">move fast</span></div>"#;
const RUN_CHANGED: &str =
    r#"<div class="entry"><span class="hw">run</span><span class="sense">move very fast</span></div>"#;
const WALK: &str = r#"<div class="entry"><span class="hw">walk</span><span class="sense">go on foot</span></div>"#;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("xdict-study-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
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

fn fresh() -> Core {
    Core::new(Config { client_protocol: PROTOCOL, ..Config::default() }).unwrap()
}

/// Writes a dictionary under `file` and imports and opens it **in `core`**: two editions re-anchor in one core, so the
/// second is never imported into a registry of its own.
fn import_open(core: &Core, dir: &Scratch, file: &str, title: &str, entries: &[W]) -> (String, String) {
    let mut spec = Spec::mdx();
    spec.title = title.into();
    std::fs::write(dir.0.join(file), writer::write(&spec, entries).unwrap()).unwrap();
    let package = Package { mdx: dir.at(file), mdd: vec![], sidecars: vec![] };
    let imported = core.import(package.clone(), &NoProgress).unwrap();
    match core.open(package).unwrap() {
        Opened::Ready { dict, .. } => (dict, imported.edition),
        other => panic!("not open: {other:?}"),
    }
}

/// A fresh core with one dictionary imported and opened.
fn opened(dir: &Scratch, file: &str, title: &str, entries: &[W]) -> (Core, String, String) {
    let core = fresh();
    let (dict, edition) = import_open(&core, dir, file, title, entries);
    (core, dict, edition)
}

fn reference(edition: &str, key: &str, occurrence: u32) -> EntryRef {
    EntryRef { edition: edition.into(), key: key.into(), occurrence }
}

fn stamp(at: f64) -> Stamp {
    Stamp { at, device: "device".into() }
}

fn policy() -> ReviewPolicy {
    ReviewPolicy { retention: 0.9, maximum_days: 36_500 }
}

#[test]
fn a_note_enrols_the_entry_and_a_grade_and_an_undo_move_the_card() {
    let dir = Scratch::new("grade");
    let (core, dict, edition) = opened(&dir, "noad.mdx", "Test Dictionary", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    let note = core
        .study_note(
            dict.clone(),
            reference(&edition, "run", 0),
            "my own words".into(),
            "Test Dictionary".into(),
            stamp(at),
            "note-1".into(),
        )
        .unwrap();
    assert_eq!(note.text, "my own words", "the note is the reader's words");
    assert_eq!(note.target.entry_key, "run");
    assert_eq!(note.target.occurrence, 0);
    assert_eq!(note.target.edition, edition);
    assert!(!note.target.definition_hash.is_empty());
    assert!(!note.target.lineage.is_empty(), "the ledger owns the association");

    let queue = core.review_queue(at, 10).unwrap();
    assert_eq!(queue.len(), 1, "a new card is due at once");
    assert!(queue[0].state.is_new());
    let key = queue[0].target.key();

    let graded = core.review_grade(key.clone(), String::new(), 3, policy(), stamp(at), "grade-1".into()).unwrap();
    assert_eq!(graded.outcome, RecordOutcome::Recorded);
    assert!(!graded.card.state.is_new());
    assert!(graded.card.state.due.unwrap() > at);
    assert_eq!(core.review_queue(at, 10).unwrap().len(), 0, "scheduled, not due yet");

    // A grade of a revision the reader no longer sees is refused before anything is written.
    let late =
        core.review_grade(key.clone(), String::new(), 3, policy(), stamp(at + 1.0), "grade-late".into()).unwrap();
    assert_eq!(late.outcome, RecordOutcome::Ineligible);

    let undone = core.review_undo(key, graded.card.head.clone(), stamp(at + 60.0), "undo-1".into()).unwrap();
    assert_eq!(undone.outcome, RecordOutcome::Recorded);
    assert!(undone.card.state.is_new(), "the grade is voided");
    assert_eq!(core.review_queue(at + 60.0, 10).unwrap().len(), 1, "the card is new again");
    assert_eq!(core.study_notes().unwrap().len(), 1);
}

#[test]
fn the_definition_hash_is_the_evidence_not_the_text() {
    let dir = Scratch::new("hash");
    let (core, dict, edition) = opened(&dir, "noad.mdx", "Test Dictionary", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    let note = core
        .study_note(
            dict.clone(),
            reference(&edition, "run", 0),
            "mine".into(),
            "Test Dictionary".into(),
            stamp(at),
            "note".into(),
        )
        .unwrap();
    let hash = core.definition_hash_of(dict, reference(&edition, "run", 0)).unwrap();
    assert_eq!(note.target.definition_hash, hash);
    // The evidence is a hash: neither the entry's words nor its markup enter the log.
    let exported = serde_json::to_string(&core.ledger_export().unwrap()).unwrap();
    assert!(exported.contains(&hash), "the hash is in the note's evidence");
    assert!(!exported.contains("move fast"), "the definition's text never enters the ledger");
    assert!(!exported.contains("<div"), "nor its markup");
}

/// The same definition under a new title: another edition, the same lineage, the note moves.
#[test]
fn a_note_reanchors_when_the_definition_is_still_there() {
    let dir = Scratch::new("reanchor-same");
    let (core, dict, old) = opened(&dir, "a.mdx", "First", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    core.study_note(dict, reference(&old, "run", 0), "mine".into(), "First".into(), stamp(at), "note".into()).unwrap();
    let (_, new) = import_open(&core, &dir, "b.mdx", "Second", &[W::text("run", RUN)]);
    let lineage = core.lineage_of(old.clone()).unwrap().expect("the old edition's lineage");
    core.join_lineage(new.clone(), lineage).unwrap();
    let report = core.study_reanchor(old.clone(), new.clone(), stamp(at + 60.0), "reanchor".into()).unwrap();
    assert_eq!(report.outcomes.len(), 1);
    assert_eq!(report.outcomes[0].result, ReanchorResult::Reanchored);
    let notes = core.study_notes().unwrap();
    assert_eq!(notes[0].target.edition, new, "the note carries the new edition's evidence");
    assert_eq!(notes[0].target.key(), report.outcomes[0].target.key(), "the identity did not move");
}

#[test]
fn a_changed_or_missing_definition_leaves_the_note_where_it_is() {
    for (name, entries, expected) in [
        ("changed", vec![W::text("run", RUN_CHANGED)], ReanchorResult::Changed),
        ("missing", vec![W::text("walk", WALK)], ReanchorResult::Missing),
    ] {
        let dir = Scratch::new(name);
        let (core, dict, old) = opened(&dir, "a.mdx", "First", &[W::text("run", RUN)]);
        let at = 1_790_640_000.0;
        core.study_note(dict, reference(&old, "run", 0), "mine".into(), "First".into(), stamp(at), "note".into())
            .unwrap();
        let (_, new) = import_open(&core, &dir, "b.mdx", "Second", &entries);
        let lineage = core.lineage_of(old.clone()).unwrap().expect("lineage");
        core.join_lineage(new.clone(), lineage).unwrap();
        let report = core.study_reanchor(old.clone(), new.clone(), stamp(at + 60.0), "reanchor".into()).unwrap();
        assert_eq!(report.outcomes[0].result, expected, "{name}");
        assert_eq!(core.study_notes().unwrap()[0].target.edition, old, "{name} keeps its evidence");
    }
}

/// The same definition under another occurrence: reordering is not re-anchoring.
#[test]
fn a_reordered_definition_leaves_the_note_where_it_is() {
    let dir = Scratch::new("reordered");
    let (core, dict, old) = opened(&dir, "a.mdx", "First", &[W::text("run", RUN)]);
    let at = 1_790_640_000.0;
    core.study_note(dict, reference(&old, "run", 0), "mine".into(), "First".into(), stamp(at), "note".into()).unwrap();
    let (_, new) = import_open(&core, &dir, "b.mdx", "Second", &[W::text("run", RUN_CHANGED), W::text("run", RUN)]);
    let lineage = core.lineage_of(old.clone()).unwrap().expect("lineage");
    core.join_lineage(new.clone(), lineage).unwrap();
    let report = core.study_reanchor(old.clone(), new.clone(), stamp(at + 60.0), "reanchor".into()).unwrap();
    assert_eq!(report.outcomes[0].result, ReanchorResult::Reordered);
    assert_eq!(core.study_notes().unwrap()[0].target.edition, old);
}
