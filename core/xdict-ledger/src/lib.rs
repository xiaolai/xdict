//! **The reading history**: an append-only log of what the reader read, the dictionary associations they made, and the
//! removals that hide content without carrying it.
//!
//! ADR-0024 is the storage contract this implements: one writer, durable acknowledgement, an operation id as the retry
//! key, a torn tail truncated on open, retention as compaction, erase as a rewrite, and the logic — never the bytes — in
//! Rust. ADR-0025 is why dictionary joins and splits are events here: the ledger owns the association the registry
//! caches. ADR-0023 is why a sentence is here at all: local only, behind the reader's switch, erased on request.
//!
//! The log is a sequence of frames ([`frame`]): `magic`, payload length, an xxh3 checksum, then a JSON `StoredEvent`.
//! An event id is the SHA-256 of that payload, so a retry with the same operation id and the same event is one event.
//! Replay orders events causally (`projection::ordered`) and projects them into readings, associations and removals.

#[cfg(not(target_family = "wasm"))]
pub use store::FileStore;
pub use store::{MemoryStore, Store};

use std::collections::HashSet;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

mod frame;
mod projection;
mod store;
#[cfg(test)]
mod tests;

use frame::{event_id, frame as frame_bytes, next_frame};
use projection::{Entry, Projection, StoredEvent};

/// How far back the drawer looks, and how many cards it holds. Both bounded: the drawer is opened often.
pub const MAX_DAYS: i64 = 14;
pub const MAX_CARDS: usize = 400;

/// A range of the sentence, in UTF-16 code units — the unit the capture contract uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadingSpan {
    pub start: u32,
    pub len: u32,
}

/// **One reading**, as the card shows it: the word, the sentence and where the word sits in it, the capture's own
/// doubts, the dictionary by its content hash, and the moment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reading {
    /// The word exactly as it was on screen.
    pub surface: String,
    /// The dictionary's form where it is known; the surface otherwise.
    pub lemma: String,
    pub sentence: String,
    pub span: Option<ReadingSpan>,
    /// Which ends of the sentence the capture may have cut: bit 0 the start, bit 1 the end.
    pub cut: u8,
    /// The capture's quality word (`complete`, `mayBeCut`, `missing`); empty when unknown.
    pub quality: String,
    /// The dictionary's **edition** hash — content identity, never the reader's lineage (ADR-0025).
    pub edition: String,
    pub entry_key: String,
    pub occurrence: u32,
    /// The dictionary's name at the time; a reading outlives a rename.
    pub dictionary_name: String,
    /// The dictionary's declared search-side language; empty when none is declared.
    pub language: String,
    /// Whole epoch seconds.
    pub at: f64,
    /// Which device recorded it (the lineage mints per device).
    pub device: String,
}

/// **The reader's association of an edition with a dictionary lineage** (ADR-0025): a join is their act, and it is the
/// ledger's event, so two devices agree which lineage is which dictionary once the event syncs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryJoined {
    pub lineage: String,
    pub edition: String,
    /// The dictionary's name at the time.
    pub name: String,
    /// Its declared search-side language; empty when none.
    pub language: String,
    pub at: f64,
    pub device: String,
}

/// An edition leaving its lineage for `new_lineage` (ADR-0002's reversible split, ADR-0025): the association changes
/// from this event on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionarySplit {
    /// The lineage the edition had when the reader split it.
    pub lineage: String,
    pub new_lineage: String,
    pub edition: String,
    pub name: String,
    pub at: f64,
    pub device: String,
}

/// A tombstone: the event ids it hides (a removal) or shows again (a restore). It carries **no content**, so it can
/// travel (ADR-0024).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Removal {
    pub event_ids: Vec<String>,
    pub at: f64,
    pub device: String,
}

/// What an erase left behind: how many readings it cleared, and the log's frontier before the rewrite. It carries no
/// content, so it can travel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EraseReceipt {
    pub cleared_readings: u64,
    #[serde(default)]
    pub cleared_notes: u64,
    #[serde(default)]
    pub cleared_grades: u64,
    pub frontier: Frontier,
    pub at: f64,
    pub device: String,
}

// MARK: - Study (plan-history-and-learning §5)

/// A study target's kind; v1 has entry-level targets, and the tagged enum leaves a sense kind as an addition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TargetKind {
    Entry,
}

/// **What a note is about** (ADR-0025, plan §5.1): the lineage the ledger owns, the entry's key and occurrence, and
/// evidence — the edition it was written in and a hash of the definition, **never the definition's text**.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudyTarget {
    pub lineage: String,
    pub entry_key: String,
    pub occurrence: u32,
    pub kind: TargetKind,
    /// Evidence: the edition the note was made in.
    pub edition: String,
    /// Evidence: the SHA-256 of the definition text the reader saw, in hex. The text never travels.
    pub definition_hash: String,
}

impl StudyTarget {
    /// The target's identity: everything but its evidence. Two editions of one dictionary share it.
    pub fn key(&self) -> String {
        format!("{}\u{1f}{}\u{1f}{}\u{1f}{}", self.lineage, self.entry_key, self.occurrence, self.kind.as_str())
    }
}

impl TargetKind {
    pub fn as_str(self) -> &'static str {
        match self {
            TargetKind::Entry => "entry",
        }
    }
}

/// **The reader's own words about an entry** (plan §5.3): the note travels, and carries no dictionary content.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub target: StudyTarget,
    pub text: String,
    pub at: f64,
    pub device: String,
}

/// The reader's answer to a card.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StudyGrade {
    Again,
    Hard,
    Good,
    Easy,
}

impl StudyGrade {
    /// The scheduler's rating, 1...4.
    pub fn number(self) -> u8 {
        match self {
            StudyGrade::Again => 1,
            StudyGrade::Hard => 2,
            StudyGrade::Good => 3,
            StudyGrade::Easy => 4,
        }
    }
}

/// The stage the scheduler put a card in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StudyPhase {
    New,
    Learning,
    Review,
    Relearning,
}

/// A card's state as the scheduler left it: what the next grade and the queue read.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardState {
    pub stability: Option<f64>,
    pub difficulty: Option<f64>,
    pub phase: StudyPhase,
    pub last_review: Option<f64>,
    pub due: Option<f64>,
}

impl CardState {
    pub fn new() -> Self {
        CardState { stability: None, difficulty: None, phase: StudyPhase::New, last_review: None, due: None }
    }

    /// A card that has never been graded.
    pub fn is_new(&self) -> bool {
        self.phase == StudyPhase::New
    }
}

impl Default for CardState {
    fn default() -> Self {
        Self::new()
    }
}

/// **The scheduler configuration a grade was made under** (plan §5.3), kept with the grade so the transition is
/// replayable even after the reader changes a setting.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleConfiguration {
    /// The scheduler's version string; a change to its rules must change this (xdict-schedule's `VERSION`).
    pub version: String,
    pub retention: f64,
    pub maximum_days: i64,
    pub weights: Vec<f64>,
}

/// **One grade** (plan §5.3): the revision it saw, the transition it made, and the configuration that made it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GradeRecord {
    pub target: StudyTarget,
    /// The card's head when the reader graded: the event id of the grade it extends; empty for a new card.
    pub revision: String,
    pub grade: StudyGrade,
    pub before: CardState,
    pub after: CardState,
    pub configuration: ScheduleConfiguration,
    pub at: f64,
    pub device: String,
}

/// **A voided grade** (plan §5.3): only the latest non-void grade, and only while the card is still in the state that
/// grade produced. Replay takes the latest non-void grade per target as the card.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoRecord {
    pub target: StudyTarget,
    /// The grade event this voids.
    pub grade_event: String,
    pub at: f64,
    pub device: String,
}

/// **A note moved to a new edition's evidence** (plan §5.1): the key and occurrence matched and the definition's hash
/// matched, so the note is the same note.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReanchorRecord {
    pub target: StudyTarget,
    pub to_edition: String,
    pub definition_hash: String,
    pub at: f64,
    pub device: String,
}

/// **One card the review queue shows**: the target with its current evidence, the reader's note, and the state the next
/// grade extends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudyCard {
    pub target: StudyTarget,
    pub note: Note,
    pub state: CardState,
    /// The head event a grade extends: the latest non-void grade's id, empty for a new card.
    pub head: String,
    /// The note event's own id: a revision names it as its parent.
    pub note_head: String,
    /// How many grades of this card are not voided.
    pub grades: u64,
}

/// What the reader has to do now, and when the next card falls due.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewSummary {
    pub due: u64,
    /// The earliest future due instant, when no card is due now.
    pub next_due: Option<u64>,
}

/// The SHA-256 of an entry's definition text, in hex: the evidence a note keeps instead of the text.
pub fn definition_hash(text: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(text.as_bytes());
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// A log's summary: how many events it holds, its last one, and a digest of all its ids.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frontier {
    pub events: u64,
    /// The last event's id in the file's order; empty for an empty log.
    pub head: String,
    pub digest: String,
}

/// One event in the log. A tag/content pair so a later kind is an addition, not a migration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload", rename_all = "camelCase")]
pub enum Event {
    Reading(Reading),
    DictionaryJoined(DictionaryJoined),
    DictionarySplit(DictionarySplit),
    Removed(Removal),
    Restored(Removal),
    Erased(EraseReceipt),
    NoteSaved(Note),
    NoteRevised(Note),
    Graded(GradeRecord),
    Undone(UndoRecord),
    Reanchored(ReanchorRecord),
}

/// What a record call did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordOutcome {
    Recorded,
    /// The same operation is already in the log.
    Duplicate,
    /// **The append happened; its durability did not.** The bytes were handed to the store but the sync failed, so a
    /// crash may or may not keep them. The event is in this process's history either way; a retry with the same
    /// operation id settles it — it answers [`Duplicate`](RecordOutcome::Duplicate) and the log holds one event,
    /// whether this append's bytes survived or the retry's did.
    Uncertain,
    /// A reading outside the reader's target languages: **nothing was written**, not even the sentence.
    SkippedLanguage,
    /// **The card was not in the state the caller saw**: its head moved, or it is not due. Nothing was written; the
    /// caller reads the card again. A retry of a committed operation answers `Duplicate` before this is ever reached.
    Ineligible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DayLabel {
    Today,
    Yesterday,
    Weekday,
    Date,
}

/// One card: a reading, how many times it was met that day, and the events it is made of.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub reading: Reading,
    pub times: u32,
    /// The ids of every reading event the card collapses, newest first: what a removal names.
    pub events: Vec<String>,
}

/// One calendar day's readings, newest first.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Day {
    /// `yyyy-MM-dd` in the reader's own zone: stable across relaunches.
    pub id: String,
    /// The day's start, as whole epoch seconds.
    pub start: f64,
    pub label: DayLabel,
    pub cards: Vec<Card>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub days: Vec<Day>,
}

/// What compaction kept and dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Compaction {
    pub kept: u64,
    pub removed: u64,
}

/// What may remain of erased bytes after the log is rewritten. A shell words it for the reader.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Recoverability {
    /// The log's bytes were overwritten or truncated; copies may remain in free blocks, snapshots and backups, which
    /// only the platform can reclaim.
    FreeBlocks,
}

/// What an erase did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EraseReport {
    pub cleared_readings: u64,
    pub cleared_notes: u64,
    pub cleared_grades: u64,
    pub recoverable: Recoverability,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LedgerError {
    #[error("the ledger's storage refused: {0}")]
    Storage(String),
    /// Another process holds the writer lock (ADR-0024's one writer).
    #[error("the ledger is open in another process")]
    Busy,
    #[error("an unreadable event: {0}")]
    Corrupt(String),
    #[error("a reading with no word, no sentence or an unrepresentable time")]
    InvalidReading,
    #[error("an event with no identity or an unrepresentable time")]
    InvalidEvent,
}

/// **The reader's history**, replayed from the log.
pub struct Ledger {
    store: Arc<dyn Store>,
    /// Every event, in causal order (what the projections read).
    entries: Vec<Entry>,
    /// The events' ids in the file's order, duplicates included: the frontier a snapshot must match.
    file_ids: Vec<String>,
    /// Every event id in the log (exact-duplicate identity).
    ids: HashSet<String>,
    /// Every operation id in the log: the caller's retry key, which answers `Duplicate` before eligibility is read.
    operations: HashSet<String>,
    projection: Projection,
}

impl Ledger {
    /// Replays the log. A torn tail is cut off at the last whole frame; when the snapshot's frontier is this log's, its
    /// projection is used and the events are not projected again.
    pub fn open(store: Arc<dyn Store>) -> Result<Self, LedgerError> {
        let bytes = store.load()?;
        let mut parsed: Vec<(String, StoredEvent)> = Vec::new();
        let mut file_ids: Vec<String> = Vec::new();
        let mut offset = 0;
        while let Some((payload, next)) = next_frame(&bytes, offset) {
            let id = event_id(payload);
            match serde_json::from_slice::<StoredEvent>(payload) {
                Ok(stored) => {
                    parsed.push((id.clone(), stored));
                    file_ids.push(id);
                }
                Err(error) => return Err(LedgerError::Corrupt(error.to_string())),
            }
            offset = next;
        }
        if offset < bytes.len() {
            // A frame the writer never finished (or whose checksum fails): the log ends at the last whole frame.
            store.truncate(offset as u64)?;
        }
        let entries = projection::ordered(parsed)?;
        let frontier = projection::frontier(&file_ids);
        let snapshot =
            store.load_snapshot().ok().flatten().and_then(|bytes| projection::snapshot_projection(&bytes, &frontier));
        let projection = snapshot.unwrap_or_else(|| projection::project(&entries));
        let ids = file_ids.iter().cloned().collect();
        let operations = entries.iter().map(|entry| entry.stored.operation_id.clone()).collect();
        Ok(Ledger { store, entries, file_ids, ids, operations, projection })
    }

    /// **Records a reading.** The language filter is applied **before** anything is written: a reading outside the
    /// reader's target languages leaves no bytes, sentence included. A retry (the same operation id and reading) is
    /// `Duplicate` and leaves one event; a meeting of the same reading again is a second event, which the day collapses
    /// into one card with `times`.
    pub fn record(
        &mut self,
        reading: Reading,
        operation_id: &str,
        target_languages: &[String],
    ) -> Result<RecordOutcome, LedgerError> {
        if reading.surface.is_empty() || reading.sentence.is_empty() || !valid_instant(reading.at) {
            return Err(LedgerError::InvalidReading);
        }
        if !target_languages.is_empty() && !target_languages.contains(&reading.language) {
            return Ok(RecordOutcome::SkippedLanguage);
        }
        self.append(operation_id, None, Event::Reading(reading), true)
    }

    /// **The reader joined an edition to a dictionary lineage** (ADR-0025): the association changes from this event on.
    pub fn join_dictionary(
        &mut self,
        joined: DictionaryJoined,
        operation_id: &str,
    ) -> Result<RecordOutcome, LedgerError> {
        if joined.edition.is_empty() || joined.lineage.is_empty() || !valid_instant(joined.at) {
            return Err(LedgerError::InvalidEvent);
        }
        self.append(operation_id, None, Event::DictionaryJoined(joined), true)
    }

    /// **The reader split an edition into a lineage of its own** (ADR-0025): the association changes from this event on.
    pub fn split_dictionary(
        &mut self,
        split: DictionarySplit,
        operation_id: &str,
    ) -> Result<RecordOutcome, LedgerError> {
        if split.edition.is_empty()
            || split.lineage.is_empty()
            || split.new_lineage.is_empty()
            || !valid_instant(split.at)
        {
            return Err(LedgerError::InvalidEvent);
        }
        self.append(operation_id, None, Event::DictionarySplit(split), true)
    }

    /// **Hides readings without dropping their events**: a tombstone that names them and carries no content, so it can
    /// travel. A removal naming an event not in this log is kept all the same; the event may arrive from another
    /// device.
    pub fn remove(&mut self, removal: Removal, operation_id: &str) -> Result<RecordOutcome, LedgerError> {
        if removal.event_ids.is_empty() || !valid_instant(removal.at) {
            return Err(LedgerError::InvalidEvent);
        }
        self.append(operation_id, None, Event::Removed(removal), true)
    }

    /// Shows removed readings again: the same tombstone's shape, applied in reverse.
    pub fn restore(&mut self, restore: Removal, operation_id: &str) -> Result<RecordOutcome, LedgerError> {
        if restore.event_ids.is_empty() || !valid_instant(restore.at) {
            return Err(LedgerError::InvalidEvent);
        }
        self.append(operation_id, None, Event::Restored(restore), true)
    }

    /// **Saves the reader's note** and enrols its target for review: a first note is `NoteSaved`, a later one
    /// `NoteRevised` with the previous note as its parent (plan §5.1). The threshold is the operation id, as everywhere.
    pub fn save_note(&mut self, note: Note, operation_id: &str) -> Result<RecordOutcome, LedgerError> {
        valid_target(&note.target)?;
        if note.text.trim().is_empty() || !valid_instant(note.at) {
            return Err(LedgerError::InvalidEvent);
        }
        let key = note.target.key();
        let (event, parent) = match self.projection.study.notes.get(&key) {
            Some(existing) => (Event::NoteRevised(note), Some(existing.head.clone())),
            None => (Event::NoteSaved(note), None),
        };
        self.append(operation_id, parent, event, true)
    }

    /// **Records one grade** (plan §5.3): `eligible` is the caller's verdict that the card is still at the revision
    /// the reader saw and is due — read only when the operation is new to the log.
    pub fn record_grade(
        &mut self,
        record: GradeRecord,
        operation_id: &str,
        eligible: bool,
    ) -> Result<RecordOutcome, LedgerError> {
        valid_target(&record.target)?;
        if !valid_instant(record.at)
            || !valid_state(&record.before)
            || !valid_state(&record.after)
            || !valid_configuration(&record.configuration)
        {
            return Err(LedgerError::InvalidEvent);
        }
        let parent = if record.revision.is_empty() { None } else { Some(record.revision.clone()) };
        self.append(operation_id, parent, Event::Graded(record), eligible)
    }

    /// **Voids a grade** (plan §5.3): only the card's latest non-void grade, and only while the card is still in the
    /// state that grade produced — the caller checks both and passes `eligible`.
    pub fn record_undo(
        &mut self,
        undo: UndoRecord,
        operation_id: &str,
        eligible: bool,
    ) -> Result<RecordOutcome, LedgerError> {
        valid_target(&undo.target)?;
        if undo.grade_event.is_empty() || !valid_instant(undo.at) {
            return Err(LedgerError::InvalidEvent);
        }
        let parent = Some(undo.grade_event.clone());
        self.append(operation_id, parent, Event::Undone(undo), eligible)
    }

    /// **Re-anchors a note to a new edition's evidence** (plan §5.1): the caller matched the entry's key, occurrence and
    /// definition hash; a record here says the note is the same note.
    pub fn record_reanchor(&mut self, moved: ReanchorRecord, operation_id: &str) -> Result<RecordOutcome, LedgerError> {
        valid_target(&moved.target)?;
        if moved.to_edition.is_empty() || moved.definition_hash.is_empty() || !valid_instant(moved.at) {
            return Err(LedgerError::InvalidEvent);
        }
        self.append(operation_id, None, Event::Reanchored(moved), true)
    }

    /// The reader's notes, latest per target, each carrying the target's current evidence.
    pub fn notes(&self) -> Vec<Note> {
        self.projection.study.notes.keys().filter_map(|key| self.projection.note(key)).collect()
    }

    /// Every card the notes enrol, with its state.
    pub fn cards(&self) -> Vec<StudyCard> {
        self.projection.cards()
    }

    pub fn card(&self, key: &str) -> Option<StudyCard> {
        self.projection.card(key)
    }

    /// **The review queue**: cards due now, soonest first, a new card at once; at most `limit`.
    pub fn queue(&self, now: f64, limit: usize) -> Vec<StudyCard> {
        self.projection.queue(now, limit)
    }

    /// How many cards are due, and when the next falls due while none is.
    pub fn summary(&self, now: f64) -> ReviewSummary {
        self.projection.summary(now)
    }

    /// The live notes, for the report and the erase receipt.
    pub fn note_count(&self) -> u64 {
        self.projection.study.notes.len() as u64
    }

    /// The grades not voided, for the report and the erase receipt.
    pub fn grade_count(&self) -> u64 {
        self.projection.study.grades.values().flatten().filter(|grade| !grade.voided).count() as u64
    }

    /// The days the drawer shows, newest first: at most [`MAX_DAYS`] back, at most [`MAX_CARDS`] cards.
    ///
    /// `utc_offset_seconds` is the reader's zone at the moment of the query; a day is a calendar day there, never a
    /// 24-hour window, so a lookup at 23:59 and one at 00:01 are two days.
    pub fn history(&self, now: f64, utc_offset_seconds: i32) -> History {
        projection::history(&self.projection.readings, now, utc_offset_seconds)
    }

    /// The lineage the ledger associates with an edition, as its last join or split left it (ADR-0025).
    pub fn association(&self, edition: &str) -> Option<&str> {
        self.projection.associations.get(edition).map(String::as_str)
    }

    /// How many events the log holds, replay included.
    pub fn event_count(&self) -> usize {
        self.entries.len()
    }

    /// Every event the log holds, in causal order: what an export writes (ADR-0023's promise).
    pub fn export(&self) -> Vec<Event> {
        self.entries.iter().map(|entry| entry.stored.event.clone()).collect()
    }

    /// The log's frontier: what a snapshot must match, and what an erase receipt records.
    pub fn frontier(&self) -> Frontier {
        projection::frontier(&self.file_ids)
    }

    /// **Retention is compaction** (ADR-0024): readings past the drawer's bound are removed from the log, not only from
    /// a query. Dictionary associations, erase receipts and the tombstones of kept readings stay; a tombstone whose
    /// targets all went goes with them. The kept events are re-framed from the same stored values, so their ids do not
    /// change, and a snapshot is written for the next open.
    pub fn compact(&mut self, now: f64, utc_offset_seconds: i32) -> Result<Compaction, LedgerError> {
        let kept_readings = projection::kept(&self.projection.readings, now, utc_offset_seconds);
        let mut kept: Vec<Entry> = Vec::new();
        let mut removed = 0u64;
        for entry in &self.entries {
            let keep = match &entry.stored.event {
                Event::Reading(_) => kept_readings.contains(&entry.id),
                Event::DictionaryJoined(_)
                | Event::DictionarySplit(_)
                | Event::Erased(_)
                | Event::NoteSaved(_)
                | Event::NoteRevised(_)
                | Event::Graded(_)
                | Event::Undone(_)
                | Event::Reanchored(_) => true,
                Event::Removed(tombstone) | Event::Restored(tombstone) => {
                    tombstone.event_ids.iter().any(|id| kept_readings.contains(id))
                }
            };
            if keep {
                kept.push(entry.clone());
            } else {
                removed += 1;
            }
        }
        if removed > 0 {
            self.rewrite(kept)?;
        }
        self.checkpoint()?;
        Ok(Compaction { kept: self.entries.len() as u64, removed })
    }

    /// **Erase is a rewrite** (ADR-0024): the reading events and their tombstones leave the log, a receipt that carries
    /// no content takes their place, and the dictionary associations stay — erasing a history does not unpair the
    /// reader's dictionaries. What remains physically recoverable is stated, never guessed at by the shell.
    pub fn erase(&mut self, operation_id: &str, at: f64, device: &str) -> Result<EraseReport, LedgerError> {
        if !valid_instant(at) {
            return Err(LedgerError::InvalidEvent);
        }
        let cleared = self.projection.readings.len() as u64;
        let cleared_notes = self.note_count();
        let cleared_grades = self.grade_count();
        let receipt = EraseReceipt {
            cleared_readings: cleared,
            cleared_notes,
            cleared_grades,
            frontier: self.frontier(),
            at,
            device: device.to_string(),
        };
        let stored =
            StoredEvent { operation_id: operation_id.to_string(), parent: None, event: Event::Erased(receipt) };
        let payload = serde_json::to_vec(&stored).map_err(|error| LedgerError::Corrupt(error.to_string()))?;
        let id = event_id(&payload);
        let mut kept: Vec<Entry> = self
            .entries
            .iter()
            .filter(|entry| matches!(&entry.stored.event, Event::DictionaryJoined(_) | Event::DictionarySplit(_)))
            .cloned()
            .collect();
        kept.push(Entry { id, stored });
        self.rewrite(kept)?;
        self.checkpoint()?;
        Ok(EraseReport {
            cleared_readings: cleared,
            cleared_notes,
            cleared_grades,
            recoverable: Recoverability::FreeBlocks,
        })
    }

    /// Writes the projection's snapshot for the log as it stands. `compact` and `erase` do this themselves.
    pub fn checkpoint(&self) -> Result<(), LedgerError> {
        let bytes = projection::snapshot_bytes(&self.projection, &self.frontier())?;
        self.store.save_snapshot(&bytes)
    }

    /// The one writer. **The operation id is checked first**, so a retry of a committed operation answers `Duplicate`
    /// even when its event would now compute differently; `accept` is the caller's eligibility verdict and is read only
    /// for an operation the log does not already hold.
    fn append(
        &mut self,
        operation_id: &str,
        parent: Option<String>,
        event: Event,
        accept: bool,
    ) -> Result<RecordOutcome, LedgerError> {
        if self.operations.contains(operation_id) {
            return Ok(RecordOutcome::Duplicate);
        }
        if !accept {
            return Ok(RecordOutcome::Ineligible);
        }
        let stored = StoredEvent { operation_id: operation_id.to_string(), parent, event };
        let payload = serde_json::to_vec(&stored).map_err(|error| LedgerError::Corrupt(error.to_string()))?;
        let id = event_id(&payload);
        if self.ids.contains(&id) {
            return Ok(RecordOutcome::Duplicate);
        }
        self.store.append(&frame_bytes(&payload))?;
        let durable = self.store.sync().is_ok();
        self.ids.insert(id.clone());
        self.operations.insert(operation_id.to_string());
        self.file_ids.push(id.clone());
        self.entries.push(Entry { id, stored });
        // The projection is small and rebuilt here: removals, restores and associations change other events' visibility.
        self.projection = projection::project(&self.entries);
        Ok(if durable { RecordOutcome::Recorded } else { RecordOutcome::Uncertain })
    }

    fn rewrite(&mut self, entries: Vec<Entry>) -> Result<(), LedgerError> {
        let mut bytes = Vec::new();
        for entry in &entries {
            let payload = serde_json::to_vec(&entry.stored).map_err(|error| LedgerError::Corrupt(error.to_string()))?;
            bytes.extend_from_slice(&frame_bytes(&payload));
        }
        self.store.rewrite(&bytes)?;
        self.file_ids = entries.iter().map(|entry| entry.id.clone()).collect();
        self.ids = self.file_ids.iter().cloned().collect();
        self.operations = entries.iter().map(|entry| entry.stored.operation_id.clone()).collect();
        self.entries = entries;
        self.projection = projection::project(&self.entries);
        Ok(())
    }
}

/// A target with identity and evidence: a note about nothing is refused.
fn valid_target(target: &StudyTarget) -> Result<(), LedgerError> {
    if target.lineage.is_empty()
        || target.entry_key.is_empty()
        || target.edition.is_empty()
        || target.definition_hash.is_empty()
    {
        return Err(LedgerError::InvalidEvent);
    }
    Ok(())
}

/// A card state the scheduler could have produced: every instant finite.
fn valid_state(state: &CardState) -> bool {
    let optional = |value: Option<f64>| value.is_none_or(|number| number.is_finite());
    optional(state.stability) && optional(state.difficulty) && optional(state.last_review) && optional(state.due)
}

/// A configuration the scheduler accepts, as xdict-schedule validates it.
fn valid_configuration(config: &ScheduleConfiguration) -> bool {
    !config.version.is_empty()
        && config.retention.is_finite()
        && config.retention > 0.0
        && config.retention < 1.0
        && config.maximum_days >= 1
        && !config.weights.is_empty()
        && config.weights.iter().all(|weight| weight.is_finite())
}

/// A whole, representable epoch second: the ledger's times are evidence, never fractions.
fn valid_instant(at: f64) -> bool {
    at.is_finite() && at.fract() == 0.0
}
