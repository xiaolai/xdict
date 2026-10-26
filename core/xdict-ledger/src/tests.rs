//! The ledger's own tests: the storage contract of ADR-0024 and the projections of ADR-0025, against the in-memory store
//! and (for the writer lock) a real file.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::sync::Arc;

use super::*;
use crate::projection::{self, StoredEvent};

fn reading(surface: &str, sentence: &str, at: f64, language: &str) -> Reading {
    Reading {
        surface: surface.into(),
        lemma: surface.to_lowercase(),
        sentence: sentence.into(),
        span: Some(ReadingSpan { start: 0, len: surface.len() as u32 }),
        cut: 0,
        quality: "complete".into(),
        edition: "mdx-sha256-v1:aa".into(),
        entry_key: surface.to_lowercase(),
        occurrence: 0,
        dictionary_name: "A".into(),
        language: language.into(),
        at,
        device: "test".into(),
    }
}

fn ledger() -> Ledger {
    Ledger::open(Arc::new(MemoryStore::default())).unwrap()
}

#[test]
fn a_reading_round_trips_and_retries_are_one_event() {
    let mut ledger = ledger();
    let one = reading("hold", "They hold that view.", 1_790_640_000.0, "en");
    assert_eq!(ledger.record(one.clone(), "op-1", &[]), Ok(RecordOutcome::Recorded));
    // A retry of the same operation is one event.
    assert_eq!(ledger.record(one.clone(), "op-1", &[]), Ok(RecordOutcome::Duplicate));
    // A meeting of the same reading again is a second event, and one card with ×2.
    assert_eq!(ledger.record(one.clone(), "op-2", &[]), Ok(RecordOutcome::Recorded));
    // A retry naming the same reading under a *different* operation is that operation's event, not a duplicate.
    let mut other = reading("hold", "They hold that view.", 1_790_640_000.0, "en");
    other.occurrence = 1;
    assert_eq!(ledger.record(other, "op-3", &[]), Ok(RecordOutcome::Recorded));
    assert_eq!(ledger.event_count(), 3);
    let history = ledger.history(1_790_640_000.0, 0);
    assert_eq!(history.days.len(), 1);
    // Same second, recorded later: the occurrence 1 card fronts the day, then the collapsed occurrence 0 card.
    assert_eq!(history.days[0].cards[0].reading.occurrence, 1);
    assert_eq!(history.days[0].cards[1].reading.surface, "hold");
    assert_eq!(history.days[0].cards[1].times, 2);
    assert_eq!(history.days[0].cards[1].events.len(), 2);
}

#[test]
fn a_reading_outside_the_target_languages_writes_nothing() {
    let mut ledger = ledger();
    let chinese = reading("词", "这是一个词。", 1_790_640_000.0, "zh-Hans");
    assert_eq!(ledger.record(chinese, "op-1", &["en".into()]), Ok(RecordOutcome::SkippedLanguage));
    assert_eq!(ledger.event_count(), 0);
    // An empty set keeps every language, the unknown one included.
    let unknown = reading("hold", "They hold that view.", 1_790_640_001.0, "");
    assert_eq!(ledger.record(unknown, "op-2", &[]), Ok(RecordOutcome::Recorded));
    // A non-empty set never silently treats an unknown language as a target.
    let unknown = reading("keep", "They keep that view.", 1_790_640_002.0, "");
    assert_eq!(ledger.record(unknown, "op-3", &["en".into()]), Ok(RecordOutcome::SkippedLanguage));
}

#[test]
fn repeats_on_one_day_collapse_and_days_are_calendar_days_in_the_readers_zone() {
    let mut ledger = ledger();
    // 23:58, 23:59 and 00:01 around one UTC midnight.
    let late = 1_793_059_080.0;
    let early = 1_793_059_260.0;
    ledger.record(reading("hold", "They hold that view.", late, "en"), "a", &[]).unwrap();
    ledger.record(reading("hold", "They hold that view.", late + 60.0, "en"), "b", &[]).unwrap();
    ledger.record(reading("keep", "They keep that view.", early, "en"), "c", &[]).unwrap();
    let history = ledger.history(early + 3_600.0, 0);
    assert_eq!(history.days.len(), 2, "two calendar days, not a 24-hour window");
    assert_eq!(history.days[0].cards[0].reading.surface, "keep");
    assert_eq!(history.days[1].cards[0].times, 2, "the repeat is one card with ×2");
    assert_eq!(history.days[0].label, DayLabel::Today);
    assert_eq!(history.days[1].label, DayLabel::Yesterday);
    // Eight hours west, both readings share a local day.
    let history = ledger.history(early + 3_600.0, -8 * 3_600);
    assert_eq!(history.days.len(), 1);
}

#[test]
fn a_torn_tail_is_truncated_and_the_whole_frames_survive() {
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    ledger.record(reading("hold", "They hold that view.", 1_790_640_000.0, "en"), "a", &[]).unwrap();
    // A frame the writer never finished: the length says 100 bytes, the file has eight.
    let mut bytes = store.load().unwrap();
    let whole = bytes.len();
    bytes.extend_from_slice(&0x5844_4C47u32.to_le_bytes());
    bytes.extend_from_slice(&100u32.to_le_bytes());
    bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
    store.rewrite(&bytes).unwrap();
    let reopened = Ledger::open(store.clone()).unwrap();
    assert_eq!(reopened.event_count(), 1);
    assert_eq!(store.load().unwrap().len(), whole, "the tail is cut at the last whole frame");
}

/// A store whose sync can be made to fail: the uncertain commit's test.
struct FlakyStore {
    inner: MemoryStore,
    fail_sync: std::sync::atomic::AtomicBool,
}

impl Store for FlakyStore {
    fn load(&self) -> Result<Vec<u8>, LedgerError> {
        self.inner.load()
    }
    fn append(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        self.inner.append(bytes)
    }
    fn sync(&self) -> Result<(), LedgerError> {
        if self.fail_sync.load(std::sync::atomic::Ordering::SeqCst) {
            Err(LedgerError::Storage("the disk would not flush".into()))
        } else {
            self.inner.sync()
        }
    }
    fn truncate(&self, length: u64) -> Result<(), LedgerError> {
        self.inner.truncate(length)
    }
    fn rewrite(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        self.inner.rewrite(bytes)
    }
    fn load_snapshot(&self) -> Result<Option<Vec<u8>>, LedgerError> {
        self.inner.load_snapshot()
    }
    fn save_snapshot(&self, bytes: &[u8]) -> Result<(), LedgerError> {
        self.inner.save_snapshot(bytes)
    }
}

#[test]
fn an_uncertain_commit_answers_so_and_a_retry_settles_it_to_one_event() {
    let store =
        Arc::new(FlakyStore { inner: MemoryStore::default(), fail_sync: std::sync::atomic::AtomicBool::new(true) });
    let one = reading("hold", "They hold that view.", 1_790_640_000.0, "en");
    let mut ledger = Ledger::open(store.clone()).unwrap();
    assert_eq!(ledger.record(one.clone(), "op-1", &[]), Ok(RecordOutcome::Uncertain));
    assert_eq!(ledger.event_count(), 1, "the event is in this process's history");

    // The retry, durability restored, is the same event: one event in the log and in memory.
    store.fail_sync.store(false, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(ledger.record(one.clone(), "op-1", &[]), Ok(RecordOutcome::Duplicate));
    assert_eq!(ledger.event_count(), 1);
    assert_eq!(Ledger::open(store.clone()).unwrap().event_count(), 1);

    // The other branch: the crash lost the append, so the retry on a reopened log writes the one event.
    store.truncate(0).unwrap();
    let mut reopened = Ledger::open(store.clone()).unwrap();
    assert_eq!(reopened.event_count(), 0);
    assert_eq!(reopened.record(one, "op-1", &[]), Ok(RecordOutcome::Recorded));
    assert_eq!(Ledger::open(store).unwrap().event_count(), 1);
}

#[test]
fn joins_and_splits_are_events_and_the_last_one_decides_the_association() {
    let mut ledger = ledger();
    let joined = DictionaryJoined {
        lineage: "lineage-a".into(),
        edition: "mdx-sha256-v1:aa".into(),
        name: "A".into(),
        language: "en".into(),
        at: 1_790_640_000.0,
        device: "test".into(),
    };
    assert_eq!(ledger.join_dictionary(joined.clone(), "join-1"), Ok(RecordOutcome::Recorded));
    assert_eq!(ledger.association("mdx-sha256-v1:aa"), Some("lineage-a"));
    // The same join under the same operation is a retry: one event.
    assert_eq!(ledger.join_dictionary(joined, "join-1"), Ok(RecordOutcome::Duplicate));

    let split = DictionarySplit {
        lineage: "lineage-a".into(),
        new_lineage: "lineage-b".into(),
        edition: "mdx-sha256-v1:aa".into(),
        name: "A".into(),
        at: 1_790_640_060.0,
        device: "test".into(),
    };
    assert_eq!(ledger.split_dictionary(split, "split-1"), Ok(RecordOutcome::Recorded));
    assert_eq!(ledger.association("mdx-sha256-v1:aa"), Some("lineage-b"));

    // A reopened log reaches the same association: the events are the truth, not the registry's cache.
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    ledger
        .join_dictionary(
            DictionaryJoined {
                lineage: "l1".into(),
                edition: "e1".into(),
                name: "A".into(),
                language: "".into(),
                at: 1_790_640_000.0,
                device: "test".into(),
            },
            "j",
        )
        .unwrap();
    drop(ledger);
    assert_eq!(Ledger::open(store).unwrap().association("e1"), Some("l1"));
}

#[test]
fn a_removal_hides_a_reading_and_a_restore_shows_it_again() {
    let mut ledger = ledger();
    let one = reading("hold", "They hold that view.", 1_790_640_000.0, "en");
    ledger.record(one.clone(), "a", &[]).unwrap();
    ledger.record(reading("keep", "They keep that view.", 1_790_640_060.0, "en"), "b", &[]).unwrap();
    let history = ledger.history(1_790_640_000.0, 0);
    let card = history.days[0].cards.iter().find(|card| card.reading.surface == "hold").unwrap();
    let events = card.events.clone();
    assert_eq!(events.len(), 1, "one reading, one event");

    let removal = Removal { event_ids: events.clone(), at: 1_790_640_100.0, device: "test".into() };
    assert_eq!(ledger.remove(removal.clone(), "remove-1"), Ok(RecordOutcome::Recorded));
    let after = ledger.history(1_790_640_000.0, 0);
    assert_eq!(after.days[0].cards.len(), 1);
    assert_eq!(after.days[0].cards[0].reading.surface, "keep");
    // The event is still in the log: a tombstone hides content, it does not drop it locally.
    assert_eq!(ledger.export().len(), 3);

    let restore = Removal { event_ids: events, at: 1_790_640_120.0, device: "test".into() };
    assert_eq!(ledger.restore(restore, "restore-1"), Ok(RecordOutcome::Recorded));
    let back = ledger.history(1_790_640_000.0, 0);
    assert_eq!(back.days[0].cards.len(), 2);
}

#[test]
fn retention_compaction_removes_bytes_and_keeps_every_kept_id() {
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    let now = 1_790_640_000.0;
    // One card past the bound, and one reading fifteen days old.
    for n in 0..=MAX_CARDS {
        ledger.record(reading(&format!("w{n}"), "A sentence.", now, "en"), &format!("op-{n}"), &[]).unwrap();
    }
    ledger.record(reading("old", "An old sentence.", now - 15.0 * 86_400.0, "en"), "old", &[]).unwrap();
    let before = store.load().unwrap().len();
    let ids_before: Vec<String> = ledger.entries.iter().map(|entry| entry.id.clone()).collect();

    let compaction = ledger.compact(now, 0).unwrap();
    assert_eq!(compaction.removed, 2, "one card past the bound and the old day");
    assert_eq!(compaction.kept, MAX_CARDS as u64);
    assert!(store.load().unwrap().len() < before, "retention removes bytes, not just query results");
    // Every kept event's id is its payload's own hash still: re-framing changed no identity.
    for entry in &ledger.entries {
        assert_eq!(entry.id, projection::id_of(&entry.stored).unwrap());
    }
    let kept: Vec<&String> = ledger.entries.iter().map(|entry| &entry.id).collect();
    assert!(kept.iter().all(|id| ids_before.contains(id)));
    // The oldest kept is the first of the newest 400, not the old day.
    let history = ledger.history(now, 0);
    assert_eq!(history.days.len(), 1);
    assert_eq!(history.days[0].cards.len(), MAX_CARDS);
}

#[test]
fn erase_rewrites_the_log_and_states_what_stays_recoverable() {
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    ledger
        .join_dictionary(
            DictionaryJoined {
                lineage: "l1".into(),
                edition: "e1".into(),
                name: "A".into(),
                language: "en".into(),
                at: 1_790_640_000.0,
                device: "test".into(),
            },
            "join",
        )
        .unwrap();
    ledger.record(reading("hold", "They hold that view.", 1_790_640_000.0, "en"), "a", &[]).unwrap();
    ledger.record(reading("keep", "They keep that view.", 1_790_640_060.0, "en"), "b", &[]).unwrap();

    let report = ledger.erase("erase-1", 1_790_640_120.0, "test").unwrap();
    assert_eq!(report.cleared_readings, 2);
    assert_eq!(report.recoverable, Recoverability::FreeBlocks);
    assert_eq!(ledger.history(1_790_640_000.0, 0).days.len(), 0);
    // The receipt carries no content, and the reader's dictionary is still associated: erasing a history does not unpair.
    let bytes = store.load().unwrap();
    let text = String::from_utf8_lossy(&bytes);
    assert!(!text.contains("They hold that view."));
    assert!(!text.contains("They keep that view."));
    assert_eq!(ledger.association("e1"), Some("l1"));
    let exported = ledger.export();
    assert_eq!(exported.len(), 2, "the join and the receipt");
    match &exported[1] {
        Event::Erased(receipt) => {
            assert_eq!(receipt.cleared_readings, 2);
            assert_eq!(receipt.frontier.events, 3);
        }
        other => panic!("expected an erase receipt, found {other:?}"),
    }
    // A reopened log holds the same: the receipt and the association.
    let reopened = Ledger::open(store).unwrap();
    assert_eq!(reopened.history(1_790_640_000.0, 0).days.len(), 0);
    assert_eq!(reopened.association("e1"), Some("l1"));
}

#[test]
fn a_snapshot_matching_its_frontier_projects_the_same_days() {
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    let day = 1_790_640_000.0;
    ledger.record(reading("hold", "They hold that view.", day + 10.0, "en"), "a", &[]).unwrap();
    ledger.record(reading("keep", "They keep that view.", day + 20.0, "en"), "b", &[]).unwrap();
    ledger.record(reading("run", "They run each day.", day + 86_400.0, "en"), "c", &[]).unwrap();
    ledger.record(reading("hold", "They hold that view.", day + 30.0, "en"), "d", &[]).unwrap();
    ledger.checkpoint().unwrap();

    let at = day + 3_600.0;
    let replayed = Ledger::open(store.clone()).unwrap();
    assert_eq!(replayed.history(at, 0), ledger.history(at, 0));

    // The snapshot is what the reopen read: a snapshot whose surface was changed changes the days, until the log moves.
    let bytes = store.load_snapshot().unwrap().unwrap();
    let (payload, _) = crate::frame::next_frame(&bytes, 0).unwrap();
    let mut snapshot: projection::Snapshot = serde_json::from_slice(payload).unwrap();
    snapshot.readings[0].reading.surface = "changed".into();
    let mutated = crate::frame::frame(&serde_json::to_vec(&snapshot).unwrap());
    store.save_snapshot(&mutated).unwrap();
    let cached = Ledger::open(store.clone()).unwrap();
    assert!(
        cached.history(at, 0).days[1].cards.iter().any(|card| card.reading.surface == "changed"),
        "the snapshot's projection was used"
    );

    // One more event moves the frontier, so the same snapshot is discarded and the log replays.
    let mut writer = Ledger::open(store.clone()).unwrap();
    writer.record(reading("walk", "They walk home.", day + 40.0, "en"), "e", &[]).unwrap();
    let fresh = Ledger::open(store).unwrap();
    assert!(
        !fresh.history(at, 0).days[1].cards.iter().any(|card| card.reading.surface == "changed"),
        "a stale snapshot is discarded, whatever its checksum says"
    );
    assert_eq!(fresh.event_count(), 5);
}

#[test]
fn causal_order_puts_a_child_after_its_parent_whatever_the_clocks_say() {
    let parent = StoredEvent {
        operation_id: "p".into(),
        parent: None,
        event: Event::Reading(reading("one", "First.", 100.0, "en")),
    };
    let parent_id = projection::id_of(&parent).unwrap();
    let child = StoredEvent {
        operation_id: "c".into(),
        parent: Some(parent_id.clone()),
        event: Event::Reading(reading("two", "Second.", 99.0, "en")),
    };
    let child_id = projection::id_of(&child).unwrap();
    // Written child first, parent second: the file's order is not the causal order.
    let ordered = projection::ordered(vec![(child_id, child), (parent_id, parent)]).unwrap();
    assert_eq!(ordered[0].stored.operation_id, "p");
    assert_eq!(ordered[1].stored.operation_id, "c");
}

#[cfg(not(target_family = "wasm"))]
#[test]
fn the_file_store_refuses_a_second_writer() {
    let dir = std::env::temp_dir().join(format!("xdict-ledger-test-{}", std::process::id()));
    let path = dir.join("ledger.log");
    let _ = std::fs::remove_dir_all(&dir);
    let first = FileStore::open(&path).expect("the first writer");
    assert!(matches!(FileStore::open(&path), Err(LedgerError::Busy)));
    drop(first);
    let _ = std::fs::remove_dir_all(&dir);
}

// MARK: - Study (plan-history-and-learning §5)

fn target(occurrence: u32) -> StudyTarget {
    StudyTarget {
        lineage: "lineage-a".into(),
        entry_key: "hold".into(),
        occurrence,
        kind: TargetKind::Entry,
        edition: "mdx-sha256-v1:aa".into(),
        definition_hash: definition_hash("to keep; to have"),
    }
}

fn note(text: &str, at: f64, occurrence: u32) -> Note {
    Note { target: target(occurrence), text: text.into(), at, device: "test".into() }
}

fn state(phase: StudyPhase, due: Option<f64>, last: Option<f64>) -> CardState {
    CardState { stability: last.map(|_| 1.5), difficulty: last.map(|_| 5.0), phase, last_review: last, due }
}

fn grade(revision: &str, before: CardState, after: CardState, at: f64, occurrence: u32) -> GradeRecord {
    GradeRecord {
        target: target(occurrence),
        revision: revision.into(),
        grade: StudyGrade::Good,
        before,
        after,
        configuration: ScheduleConfiguration {
            version: "fsrs6-py9446cb0-one10m-no-fuzz-v1".into(),
            retention: 0.9,
            maximum_days: 36_500,
            weights: vec![0.212, 1.2931],
        },
        at,
        device: "test".into(),
    }
}

#[test]
fn a_note_enrols_a_card_and_a_revision_names_the_note_it_revises() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    assert_eq!(ledger.save_note(note("my first note", at, 0), "note-1"), Ok(RecordOutcome::Recorded));
    let first = ledger.entries.last().unwrap().id.clone();
    assert_eq!(ledger.save_note(note("my better note", at + 60.0, 0), "note-2"), Ok(RecordOutcome::Recorded));
    let revised = ledger.entries.last().unwrap();
    assert_eq!(revised.stored.parent.as_deref(), Some(first.as_str()), "a revision names its parent");
    let notes = ledger.notes();
    assert_eq!(notes.len(), 1, "one note per target");
    assert_eq!(notes[0].text, "my better note");
    let card = ledger.card(&target(0).key()).expect("the note enrols a card");
    assert!(card.state.is_new());
    assert_eq!(card.note_head, revised.id);
    assert_eq!(ledger.queue(at, 10).len(), 1, "a new card is due at once");
}

#[test]
fn a_grade_schedules_the_card_and_an_undo_reverts_it() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    ledger.save_note(note("mine", at, 0), "note").unwrap();
    let after = state(StudyPhase::Learning, Some(at + 600.0), Some(at));
    assert_eq!(
        ledger.record_grade(grade("", CardState::new(), after, at, 0), "grade-1", true),
        Ok(RecordOutcome::Recorded)
    );
    let graded = ledger.card(&target(0).key()).unwrap();
    assert_eq!(graded.state, after);
    assert_eq!(graded.grades, 1);
    assert_eq!(ledger.queue(at, 10).len(), 0, "scheduled, not due yet");
    assert_eq!(ledger.queue(at + 600.0, 10).len(), 1, "due at its instant");
    assert_eq!(ledger.queue(at + 599.0, 10).len(), 0, "not due before it");
    let head = graded.head.clone();

    let undo = UndoRecord { target: target(0), grade_event: head, at: at + 60.0, device: "test".into() };
    assert_eq!(ledger.record_undo(undo, "undo-1", true), Ok(RecordOutcome::Recorded));
    let reverted = ledger.card(&target(0).key()).unwrap();
    assert!(reverted.state.is_new(), "the grade is voided and the card is new again");
    assert_eq!(reverted.head, "");
    assert_eq!(reverted.grades, 0);
    let grades = ledger.export().iter().filter(|event| matches!(event, Event::Graded(_))).count();
    assert_eq!(grades, 1, "the voided grade is still in the log: an undo is an event, not a rewrite");
}

#[test]
fn an_ineligible_grade_writes_nothing_and_a_retry_of_a_commit_is_a_duplicate() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    ledger.save_note(note("mine", at, 0), "note").unwrap();
    let after = state(StudyPhase::Learning, Some(at + 600.0), Some(at));
    assert_eq!(
        ledger.record_grade(grade("", CardState::new(), after, at, 0), "g", false),
        Ok(RecordOutcome::Ineligible)
    );
    assert_eq!(ledger.event_count(), 1, "nothing was written");

    assert_eq!(ledger.record_grade(grade("", CardState::new(), after, at, 0), "g", true), Ok(RecordOutcome::Recorded));
    let head = ledger.card(&target(0).key()).unwrap().head;
    let retry = grade(&head, after, after, at + 60.0, 0);
    assert_eq!(ledger.record_grade(retry, "g", false), Ok(RecordOutcome::Duplicate));
    assert_eq!(ledger.event_count(), 2, "one note, one grade");
}

#[test]
fn erase_clears_notes_and_grades_and_the_receipt_names_them() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    ledger.save_note(note("mine", at, 0), "note").unwrap();
    let after = state(StudyPhase::Learning, Some(at + 600.0), Some(at));
    ledger.record_grade(grade("", CardState::new(), after, at, 0), "grade", true).unwrap();
    let report = ledger.erase("erase", at + 60.0, "test").unwrap();
    assert_eq!(report.cleared_notes, 1);
    assert_eq!(report.cleared_grades, 1);
    assert_eq!(report.recoverable, Recoverability::FreeBlocks);
    assert!(ledger.notes().is_empty() && ledger.cards().is_empty());
    let exported = ledger.export();
    match exported.last() {
        Some(Event::Erased(receipt)) => {
            assert_eq!(receipt.cleared_notes, 1);
            assert_eq!(receipt.cleared_grades, 1);
        }
        other => panic!("expected an erase receipt, found {other:?}"),
    }
    assert!(!String::from_utf8_lossy(&ledger.store.load().unwrap()).contains("mine"));
}

#[test]
fn a_reanchor_moves_the_evidence_and_keeps_the_identity() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    ledger.save_note(note("mine", at, 0), "note").unwrap();
    let old = target(0);
    let moved = ReanchorRecord {
        target: old.clone(),
        to_edition: "mdx-sha256-v1:bb".into(),
        definition_hash: definition_hash("to keep; to have"),
        at: at + 60.0,
        device: "test".into(),
    };
    assert_eq!(ledger.record_reanchor(moved, "reanchor"), Ok(RecordOutcome::Recorded));
    let notes = ledger.notes();
    assert_eq!(notes[0].target.edition, "mdx-sha256-v1:bb");
    assert_eq!(notes[0].target.key(), old.key(), "the identity did not move");
    assert_eq!(ledger.card(&old.key()).unwrap().target.edition, "mdx-sha256-v1:bb");
}

#[test]
fn the_queue_and_summary_follow_the_due_instants() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    ledger.save_note(note("one", at, 0), "note-1").unwrap();
    let after = state(StudyPhase::Review, Some(at + 3.0 * 86_400.0), Some(at));
    ledger.record_grade(grade("", CardState::new(), after, at, 0), "grade", true).unwrap();
    let summary = ledger.summary(at + 60.0);
    assert_eq!(summary.due, 0);
    assert_eq!(summary.next_due, Some((at + 3.0 * 86_400.0) as u64));
    assert!(ledger.queue(at + 60.0, 10).is_empty());

    ledger.save_note(note("two", at + 60.0, 1), "note-2").unwrap();
    assert_eq!(ledger.queue(at + 60.0, 10).len(), 1, "the new card is due");
    assert_eq!(ledger.summary(at + 60.0).due, 1);
    assert_eq!(ledger.summary(at + 60.0).next_due, None);
    assert_eq!(ledger.queue(at + 3.0 * 86_400.0, 10).len(), 2, "the scheduled card falls due beside the still-new one");
}

#[test]
fn a_note_keeps_a_definition_hash_and_never_the_definition() {
    let definition = "a synthetic definition the ledger must never hold";
    let hash = definition_hash(definition);
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    let mut held = note("my own words", at, 0);
    held.target.definition_hash = hash.clone();
    ledger.save_note(held, "note").unwrap();
    let exported = serde_json::to_string(&ledger.export()).unwrap();
    assert!(exported.contains(&hash), "the evidence is the hash");
    assert!(!exported.contains(definition), "the definition itself never enters the log");
}

/// **Clearing a note** (UI49): an existing note may be revised to exactly empty text, through the same `NoteRevised`
/// write as any revision. The card stays enrolled, the earlier wording stays in the log and its export, a retry is one
/// event, and the cleared state survives a reopen.
#[test]
fn an_existing_note_revised_to_empty_keeps_its_card_and_its_history() {
    let store = Arc::new(MemoryStore::default());
    let mut ledger = Ledger::open(store.clone()).unwrap();
    let at = 1_790_640_000.0;
    ledger.save_note(note("earlier", at, 0), "note-1").unwrap();
    let first = ledger.entries.last().unwrap().id.clone();
    assert_eq!(ledger.save_note(note("", at + 60.0, 0), "clear-1"), Ok(RecordOutcome::Recorded));
    let cleared = ledger.entries.last().unwrap();
    assert!(matches!(cleared.stored.event, Event::NoteRevised(_)), "a clear is a revision, not a new event kind");
    assert_eq!(cleared.stored.parent.as_deref(), Some(first.as_str()), "it names the note it revises");
    let cleared_id = cleared.id.clone();
    assert_eq!(
        ledger.save_note(note("", at + 60.0, 0), "clear-1"),
        Ok(RecordOutcome::Duplicate),
        "a retry is one event"
    );
    assert_eq!(ledger.event_count(), 2);
    let notes = ledger.notes();
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0].text, "");
    let card = ledger.card(&target(0).key()).expect("the word stays in Review");
    assert_eq!(card.note_head, cleared_id);
    let exported = serde_json::to_string(&ledger.export()).unwrap();
    assert!(exported.contains("earlier"), "the earlier wording stays in the export until an erase");

    let mut reopened = Ledger::open(store).unwrap();
    assert_eq!(reopened.notes()[0].text, "", "the clear survives a reopen");
    assert!(reopened.card(&target(0).key()).is_some());
    // Undo of a clear: the earlier wording saved again, as one more revision.
    assert_eq!(reopened.save_note(note("earlier", at + 120.0, 0), "restore-1"), Ok(RecordOutcome::Recorded));
    assert_eq!(reopened.notes()[0].text, "earlier");
    assert_eq!(reopened.event_count(), 3);
}

/// A clear made on one device reaches another through the ordinary merge.
#[test]
fn an_empty_revision_merges_to_a_peer() {
    let mut a = ledger();
    let at = 1_790_640_000.0;
    a.save_note(note("earlier", at, 0), "note-1").unwrap();
    let mut b = peer(&a);
    a.save_note(note("", at + 60.0, 0), "clear-1").unwrap();
    assert_eq!(b.merge(&a.log_bytes().unwrap()).unwrap(), MergeReport { added: 1, skipped: 1 });
    assert_eq!(b.notes()[0].text, "", "the peer sees the cleared note");
    assert!(b.card(&target(0).key()).is_some(), "and still reviews the word");
}

/// **Only an existing note may be emptied**: a first empty note would enrol a card the reader never wrote anything
/// for, and whitespace is never a deliberate clear. Both write nothing.
#[test]
fn a_first_empty_note_and_whitespace_text_are_refused() {
    let mut ledger = ledger();
    let at = 1_790_640_000.0;
    assert_eq!(ledger.save_note(note("", at, 0), "first-empty"), Err(LedgerError::InvalidEvent));
    assert_eq!(ledger.save_note(note("  \n", at, 0), "first-blank"), Err(LedgerError::InvalidEvent));
    assert_eq!(ledger.event_count(), 0);
    assert!(ledger.card(&target(0).key()).is_none(), "no card was enrolled");
    ledger.save_note(note("mine", at, 0), "note-1").unwrap();
    assert_eq!(ledger.save_note(note(" \t\n", at + 60.0, 0), "blank"), Err(LedgerError::InvalidEvent));
    // Another target's existing note does not make this one's first empty note acceptable.
    assert_eq!(ledger.save_note(note("", at + 60.0, 1), "other-empty"), Err(LedgerError::InvalidEvent));
    // The ordinary checks still hold for an empty revision.
    assert_eq!(ledger.save_note(note("", f64::NAN, 0), "bad-time"), Err(LedgerError::InvalidEvent));
    assert_eq!(ledger.event_count(), 1);
    assert_eq!(ledger.notes()[0].text, "mine");
}

// MARK: - Sync and conflicts (plan §2.6, ADR-0027)

/// A second device: a log of its own that starts as a copy of `from`, the way a sync makes one.
fn peer(from: &Ledger) -> Ledger {
    let mut peer = ledger();
    peer.merge(&from.log_bytes().unwrap()).unwrap();
    peer
}

fn grade_by(device: &str, revision: &str, before: CardState, after: CardState, at: f64) -> GradeRecord {
    let mut record = grade(revision, before, after, at, 0);
    record.device = device.into();
    record
}

#[test]
fn history_sync_is_the_union_of_content_addressed_events() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    a.record(reading("hold", "They hold that view.", at, "en"), "a-1", &[]).unwrap();
    let mut b = ledger();
    b.record(reading("walk", "They walk there.", at, "en"), "b-1", &[]).unwrap();
    b.record(reading("hold", "They hold that view.", at, "en"), "b-2", &[]).unwrap();

    let merged = a.merge(&b.log_bytes().unwrap()).unwrap();
    assert_eq!(merged, MergeReport { added: 2, skipped: 0 });
    assert_eq!(a.history(at + 1.0, 0).days[0].cards.len(), 2, "both devices' readings are here");

    // The other direction converges: the same events, the same ids, nothing counted twice.
    let merged = b.merge(&a.log_bytes().unwrap()).unwrap();
    assert_eq!(merged, MergeReport { added: 1, skipped: 2 });
    assert_eq!(a.event_count(), b.event_count());
    // A merge of what is already held adds nothing, and a second pass is idempotent.
    assert_eq!(a.merge(&b.log_bytes().unwrap()).unwrap(), MergeReport { added: 0, skipped: 3 });
    assert_eq!(a.event_count(), 3);
}

#[test]
fn two_offline_grades_of_one_revision_are_a_conflict_the_reader_resolves() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    a.save_note(note("mine", at, 0), "note").unwrap();
    let mut b = peer(&a);

    let after_a = state(StudyPhase::Learning, Some(at + 600.0), Some(at + 10.0));
    let after_b = state(StudyPhase::Learning, Some(at + 86_400.0), Some(at + 20.0));
    a.record_grade(grade_by("a", "", CardState::new(), after_a, at + 10.0), "grade-a", true).unwrap();
    b.record_grade(grade_by("b", "", CardState::new(), after_b, at + 20.0), "grade-b", true).unwrap();
    let key = target(0).key();
    let head_a = a.card(&key).unwrap().head;

    a.merge(&b.log_bytes().unwrap()).unwrap();
    b.merge(&a.log_bytes().unwrap()).unwrap();
    for ledger in [&a, &b] {
        let conflict = ledger.conflict(&key).expect("two answers to one revision");
        assert_eq!(conflict.candidates.len(), 2);
        assert_eq!(conflict.candidates[0].device, "a", "oldest first");
        assert_eq!(conflict.candidates[1].device, "b");
        assert!(ledger.queue(at + 30.0, 10).is_empty(), "a conflicted card waits for the reader, not for time");
        assert_eq!(ledger.summary(at + 30.0), ReviewSummary { due: 0, next_due: None }, "nor is it counted due");
        assert_eq!(ledger.conflicts().len(), 1);
    }

    // The reader keeps device a's answer; replay voids b's, and both logs agree afterwards.
    let resolution = ResolutionRecord { target: target(0), keep: head_a.clone(), at: at + 40.0, device: "a".into() };
    assert_eq!(a.resolve(resolution, "resolve-1", true), Ok(RecordOutcome::Recorded));
    b.merge(&a.log_bytes().unwrap()).unwrap();
    for ledger in [&a, &b] {
        assert!(ledger.conflict(&key).is_none(), "resolved");
        let card = ledger.card(&key).unwrap();
        assert_eq!(card.head, head_a, "the kept branch stands");
        assert_eq!(card.state, after_a);
        assert_eq!(card.grades, 1, "the other answer is voided, not deleted");
    }
    assert_eq!(a.merge(&b.log_bytes().unwrap()).unwrap(), MergeReport { added: 0, skipped: a.event_count() as u64 });
}

#[test]
fn an_undo_on_one_branch_and_a_grade_on_the_other_are_a_conflict() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    a.save_note(note("mine", at, 0), "note").unwrap();
    let after_1 = state(StudyPhase::Learning, Some(at + 600.0), Some(at + 10.0));
    a.record_grade(grade_by("a", "", CardState::new(), after_1, at + 10.0), "grade-1", true).unwrap();
    let g1 = a.card(&target(0).key()).unwrap().head;
    let mut b = peer(&a);

    // Device b undoes the grade it saw; device a, offline, grades from it.
    let undo = UndoRecord { target: target(0), grade_event: g1.clone(), at: at + 20.0, device: "b".into() };
    b.record_undo(undo, "undo-b", true).unwrap();
    let after_2 = state(StudyPhase::Review, Some(at + 5.0 * 86_400.0), Some(at + 30.0));
    a.record_grade(grade_by("a", &g1, after_1, after_2, at + 30.0), "grade-2", true).unwrap();
    let g2 = a.card(&target(0).key()).unwrap().head;

    a.merge(&b.log_bytes().unwrap()).unwrap();
    let conflict = a.conflict(&target(0).key()).expect("the undo met the grade it never saw");
    let ids: Vec<&str> = conflict.candidates.iter().map(|candidate| candidate.id.as_str()).collect();
    assert_eq!(ids, vec![g1.as_str(), g2.as_str()]);

    // Keeping the branch that grew past the undo: the grade stands and the card continues from it.
    let resolution = ResolutionRecord { target: target(0), keep: g2.clone(), at: at + 40.0, device: "a".into() };
    a.resolve(resolution, "resolve", true).unwrap();
    assert!(a.conflict(&target(0).key()).is_none());
    assert_eq!(a.card(&target(0).key()).unwrap().state, after_2);
}

#[test]
fn a_clock_rollback_still_replays_a_grade_after_its_parent() {
    let at = 1_790_640_000.0;
    let mut first = ledger();
    first.save_note(note("mine", at, 0), "note").unwrap();
    let after_1 = state(StudyPhase::Learning, Some(at + 600.0), Some(at + 100.0));
    first.record_grade(grade_by("a", "", CardState::new(), after_1, at + 100.0), "grade-1", true).unwrap();
    let g1 = first.card(&target(0).key()).unwrap().head;
    // The second grade's clock is behind its parent's: causality, not wall time, orders it.
    let after_2 = state(StudyPhase::Review, Some(at + 90_000.0), Some(at + 99.0));
    first.record_grade(grade_by("a", &g1, after_1, after_2, at + 99.0), "grade-2", true).unwrap();
    let card = first.card(&target(0).key()).unwrap();
    assert_eq!(card.state, after_2);
    assert_ne!(card.head, g1, "the later event in causal order is the head");

    // The same order survives a merge: a peer that had only the first grade learns both.
    let mut second = ledger();
    second.save_note(note("mine", at, 0), "note").unwrap();
    let after_1_peer = state(StudyPhase::Learning, Some(at + 600.0), Some(at + 100.0));
    second.record_grade(grade_by("a", "", CardState::new(), after_1_peer, at + 100.0), "grade-1", true).unwrap();
    second.merge(&first.log_bytes().unwrap()).unwrap();
    assert_eq!(second.card(&target(0).key()).unwrap().state, after_2);
}

#[test]
fn equal_timestamps_across_devices_merge_without_reordering_a_card() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    a.save_note(note("mine", at, 0), "note").unwrap();
    let mut b = peer(&a);
    let after_a = state(StudyPhase::Learning, Some(at + 600.0), Some(at));
    let after_b = state(StudyPhase::Learning, Some(at + 1_200.0), Some(at));
    a.record_grade(grade_by("a", "", CardState::new(), after_a, at), "grade-a", true).unwrap();
    b.record_grade(grade_by("b", "", CardState::new(), after_b, at), "grade-b", true).unwrap();
    a.merge(&b.log_bytes().unwrap()).unwrap();
    // Equal instants are a conflict too: the reader decides, never the tie-break.
    assert!(a.conflict(&target(0).key()).is_some());
    let conflict = a.conflict(&target(0).key()).unwrap();
    assert_eq!(conflict.candidates.len(), 2);
}

#[test]
fn a_merge_after_an_erase_brings_the_other_devices_events_back() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    a.record(reading("hold", "They hold that view.", at, "en"), "a-1", &[]).unwrap();
    let untouched = peer(&a);
    a.erase("erase", at + 60.0, "test").unwrap();
    assert!(a.history(at, 0).days.is_empty(), "the erase rewrote this device's log");

    // ADR-0024: erasure is this device's. Another device's readings are its own, and a sync brings them — the reader is
    // told so where they erase, never silently.
    a.merge(&untouched.log_bytes().unwrap()).unwrap();
    assert_eq!(a.history(at, 0).days[0].cards.len(), 1);
}

// **A kept phrase is a note** (plan-context-tools WI-5; ADR-0034 d.1): these three tests hold the record's promises to the
// ledger's own rules — a note survives the reading bound, another device's note returns after an erase as its readings do,
// and a keep writes the phrase, never the sentence.

#[test]
fn a_kept_phrase_survives_compaction_past_the_reading_bound() {
    let at = 1_790_640_000.0;
    let mut ledger = ledger();
    let mut kept = note("take something into account", at, 0);
    kept.target.entry_key = "take something into account".into();
    assert_eq!(ledger.save_note(kept, "note-1"), Ok(RecordOutcome::Recorded));
    ledger.record(reading("hold", "They hold that view.", at, "en"), "read-1", &[]).unwrap();

    // Fifteen days on, the reading is past MAX_DAYS and leaves the log; the note is not a reading and stays.
    let later = at + 15.0 * 86_400.0;
    let report = ledger.compact(later, 0).unwrap();
    assert!(report.removed >= 1, "the old reading is compacted away");
    assert!(ledger.notes().iter().any(|held| held.target.entry_key == "take something into account"),
            "the kept phrase survives compaction");
    assert!(ledger.cards().iter().any(|card| card.target.entry_key == "take something into account"),
            "and it is still a card, because a card is its note");
}

#[test]
fn a_kept_phrase_from_another_device_returns_after_an_erase() {
    let at = 1_790_640_000.0;
    let mut a = ledger();
    let mut kept = note("take something into account", at, 0);
    kept.target.entry_key = "take something into account".into();
    a.save_note(kept, "note-1").unwrap();
    let untouched = peer(&a);

    a.erase("erase", at + 60.0, "test").unwrap();
    assert!(a.notes().is_empty(), "the erase rewrote this device's log");

    // ADR-0024: erasure is this device's; another device's notes are its own and a sync brings them, exactly as the
    // readings the neighbouring test follows.
    a.merge(&untouched.log_bytes().unwrap()).unwrap();
    assert!(a.notes().iter().any(|held| held.target.entry_key == "take something into account"),
            "the peer's kept phrase came back with its log");
}

#[test]
fn a_keep_writes_the_phrase_and_never_the_sentence() {
    let at = 1_790_640_000.0;
    let mut ledger = ledger();
    let mut kept = note("take something into account", at, 0);
    kept.target.entry_key = "take something into account".into();
    ledger.save_note(kept, "note-1").unwrap();

    // No reading was written, so a sentence in the export could only have come from the keep.
    let text = serde_json::to_string(&ledger.export()).unwrap();
    assert!(text.contains("take something into account"));
    assert!(!text.contains("\"sentence\""), "a keep writes no reading and no sentence: {text}");
    assert_eq!(ledger.notes()[0].text, "take something into account");
}
