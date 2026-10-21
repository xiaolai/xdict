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
