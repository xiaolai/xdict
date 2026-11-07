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
    assert_eq!(b.ledger_history(at + 1.0, vec![ZoneOffset::fixed(0)]).unwrap().days.len(), 1);
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

/// **A folder the system refuses is an I/O failure that names its path** (audit 2026-11-05, M16): a missing folder and an
/// output that is a file are the reader's storage, not a malformed log, and the shell reads `Io` to say so.
#[test]
fn a_folder_that_cannot_be_read_or_written_is_an_io_failure_naming_it() {
    let dir = Scratch::new("io");
    let a = device(&dir.path("data-a"));
    let missing = dir.0.join("not-there");
    let out = dir.path("out");
    match a.ledger_sync(missing.to_string_lossy().into(), out.to_string_lossy().into(), "a".into()) {
        Err(CoreError::Io { kind: IoKind::NotFound, detail }) => {
            assert!(detail.contains("not-there"), "the detail names the folder: {detail}")
        }
        other => panic!("a missing sync folder: {other:?}"),
    }
    let file = dir.0.join("a-file");
    std::fs::write(&file, b"").unwrap();
    let inbox = dir.path("inbox");
    match a.ledger_sync(inbox.to_string_lossy().into(), file.to_string_lossy().into(), "a".into()) {
        Err(CoreError::Io { detail, .. }) => assert!(detail.contains("a-file"), "{detail}"),
        other => panic!("an output folder that is a file: {other:?}"),
    }
}

/// A whole frame — the log's magic, length and checksum — around a payload that is not an event: what a peer's corrupt
/// log looks like once its checksum no longer hides the damage.
fn corrupt_log() -> Vec<u8> {
    let payload = b"{\"not\": \"an event\"";
    let mut out = Vec::new();
    out.extend_from_slice(&0x5844_4C47u32.to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&xxhash_rust::xxh3::xxh3_64(payload).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// One device's log with one reading, written by a sync pass of its own, as the folder would hold it.
fn peer_log(dir: &Scratch, name: &str, surface: &str, at: f64) -> Vec<u8> {
    let core = device(&dir.path(&format!("data-{name}")));
    let reading = Reading {
        surface: surface.into(),
        lemma: surface.into(),
        sentence: format!("They {surface} each day."),
        span: None,
        cut: 0,
        quality: "complete".into(),
        edition: "mdx-sha256-v1:aa".into(),
        entry_key: surface.into(),
        occurrence: 0,
        dictionary_name: "Tiny".into(),
        language: "en".into(),
        at,
        device: name.into(),
    };
    core.ledger_record(reading, format!("{name}-1"), vec![]).unwrap();
    let out = dir.path(&format!("out-{name}"));
    core.ledger_sync(dir.path("empty").to_string_lossy().into(), out.to_string_lossy().into(), name.into()).unwrap();
    std::fs::read(out.join(format!("xdict-{name}.xdlog"))).unwrap()
}

/// **One bad peer log does not block sync, and is named** (audit 2026-11-05, M16): of three peers the middle one is
/// corrupt; the other two merge, this device's log is still written, and the report names the one it left out.
#[test]
fn a_corrupt_peer_is_named_and_the_others_still_merge() {
    let dir = Scratch::new("corrupt-peer");
    let (inbox, out) = (dir.path("inbox"), dir.path("out"));
    let at = 1_790_640_000.0;
    std::fs::write(inbox.join("xdict-a.xdlog"), peer_log(&dir, "a", "run", at)).unwrap();
    std::fs::write(inbox.join("xdict-b.xdlog"), corrupt_log()).unwrap();
    std::fs::write(inbox.join("xdict-c.xdlog"), peer_log(&dir, "c", "walk", at + 1.0)).unwrap();
    let me = device(&dir.path("data-me"));

    let report = me.ledger_sync(inbox.to_string_lossy().into(), out.to_string_lossy().into(), "me".into()).unwrap();
    assert_eq!((report.peers, report.added), (2, 2), "both readable peers merged");
    let refused: Vec<&str> = report.refused.iter().map(|refusal| refusal.file.as_str()).collect();
    assert_eq!(refused, ["xdict-b.xdlog"], "the corrupt one is named");
    assert!(out.join("xdict-me.xdlog").exists(), "this device's log is written whatever a peer holds");
    assert!(report.exported > 0);
    assert_eq!(me.ledger_history(at + 2.0, vec![ZoneOffset::fixed(0)]).unwrap().days[0].cards.len(), 2);
}

/// **A peer over the size bound is a size refusal that names the bound** (audit 2026-11-05, M16), not damage: the file
/// is sparse, so the test writes nothing, and it is refused before a byte of it is read.
#[test]
fn a_peer_over_the_size_bound_is_named_with_the_bound() {
    let dir = Scratch::new("over-bound");
    let (inbox, out) = (dir.path("inbox"), dir.path("out"));
    std::fs::File::create(inbox.join("xdict-huge.xdlog")).unwrap().set_len(MAX_SYNC_BYTES + 1).unwrap();
    let me = device(&dir.path("data-me"));
    let report = me.ledger_sync(inbox.to_string_lossy().into(), out.to_string_lossy().into(), "me".into()).unwrap();
    let [refusal] = report.refused.as_slice() else { panic!("one refusal: {report:?}") };
    assert_eq!(refusal.file, "xdict-huge.xdlog");
    assert!(refusal.detail.contains("TooLarge"), "a size refusal: {}", refusal.detail);
    assert!(refusal.detail.contains(&format!("{MAX_SYNC_BYTES}-byte")), "the bound is in it: {}", refusal.detail);
    assert_eq!(report.peers, 0);
    assert!(out.join("xdict-me.xdlog").exists());
}

/// **A link is never followed** (audit 2026-11-05, the class of L1): the service checks a path and the core opens it
/// later, so a symbolic link put in the folder between the two would read a file outside it. A peer that is a link is
/// refused and named; a sync folder or an output folder that is a link refuses the pass, naming it.
#[cfg(unix)]
#[test]
fn a_link_in_the_sync_folder_is_refused_and_named() {
    let dir = Scratch::new("link");
    let (inbox, out) = (dir.path("inbox"), dir.path("out"));
    let outside = dir.0.join("outside.xdlog");
    std::fs::write(&outside, peer_log(&dir, "a", "run", 1_790_640_000.0)).unwrap();
    std::os::unix::fs::symlink(&outside, inbox.join("xdict-a.xdlog")).unwrap();
    let me = device(&dir.path("data-me"));
    let report = me.ledger_sync(inbox.to_string_lossy().into(), out.to_string_lossy().into(), "me".into()).unwrap();
    assert_eq!(report.peers, 0, "the file outside the folder was not read");
    let [refusal] = report.refused.as_slice() else { panic!("one refusal: {report:?}") };
    assert_eq!(refusal.file, "xdict-a.xdlog");
    assert!(refusal.detail.contains("symbolic link"), "{}", refusal.detail);

    let linked = dir.0.join("linked-inbox");
    std::os::unix::fs::symlink(&inbox, &linked).unwrap();
    match me.ledger_sync(linked.to_string_lossy().into(), out.to_string_lossy().into(), "me".into()) {
        Err(CoreError::Io { kind: IoKind::PermissionDenied, detail }) => {
            assert!(detail.contains("linked-inbox"), "{detail}")
        }
        other => panic!("a sync folder that is a link: {other:?}"),
    }
    let linked_out = dir.0.join("linked-out");
    std::os::unix::fs::symlink(&out, &linked_out).unwrap();
    match me.ledger_sync(inbox.to_string_lossy().into(), linked_out.to_string_lossy().into(), "me".into()) {
        Err(CoreError::Io { kind: IoKind::PermissionDenied, detail }) => {
            assert!(detail.contains("linked-out"), "{detail}")
        }
        other => panic!("an output folder that is a link: {other:?}"),
    }
    // This device's log, made a link to a file outside, is replaced by the log, never written through.
    let target = dir.0.join("victim");
    std::fs::write(&target, b"untouched").unwrap();
    std::os::unix::fs::symlink(&target, out.join("xdict-me.xdlog.tmp")).unwrap();
    me.ledger_sync(inbox.to_string_lossy().into(), out.to_string_lossy().into(), "me".into()).unwrap();
    assert_eq!(std::fs::read(&target).unwrap(), b"untouched", "the temporary link was not written through");
}

/// **A zone is a list of offsets in ascending order** (audit 2026-11-05, L5d): none, one out of order, or one beyond any
/// zone's offset is a malformed request, refused before the ledger reads it.
#[test]
fn a_zone_out_of_order_or_empty_is_malformed() {
    let dir = Scratch::new("zone");
    let me = device(&dir.path("data-me"));
    let at = 1_790_640_000.0;
    for zone in [
        vec![],
        vec![ZoneOffset { from: at, seconds: 0 }, ZoneOffset { from: at - 1.0, seconds: 3_600 }],
        vec![ZoneOffset { from: f64::NAN, seconds: 0 }],
        vec![ZoneOffset::fixed(25 * 3_600)],
    ] {
        assert!(matches!(me.ledger_history(at, zone.clone()), Err(CoreError::Malformed { .. })), "{zone:?} is refused");
        assert!(matches!(me.ledger_compact(at, zone.clone()), Err(CoreError::Malformed { .. })), "{zone:?}");
    }
}
