//! **The log's order and its projections** (ADR-0024, ADR-0025): causal order by each event's parent, the live readings
//! a history shows, the dictionary associations the reader's joins and splits recorded, and the removal and erase
//! tombstones that hide content without carrying it.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::frame::next_frame;
use crate::{
    Card, CardConflict, ConflictCandidate, Day, DayLabel, Event, Frontier, GradeRecord, History, LedgerError,
    MAX_CARDS, MAX_DAYS, Note, Reading, ReviewSummary, StudyCard, StudyTarget,
};

/// The projection's own version: a change to what is projected discards every snapshot built before it. 3 adds the
/// reader's resolutions (ADR-0027).
pub(crate) const PROJECTION_VERSION: u32 = 3;
const SECONDS_PER_DAY: f64 = 86_400.0;

/// One event as the log stores it. The operation id is the caller's retry key; `parent` is the event this one saw, which
/// makes a per-card chain replay in causal order whatever the clocks say (ADR-0024).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StoredEvent {
    pub operation_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub event: Event,
}

/// A whole event: its id, and what it holds.
#[derive(Debug, Clone)]
pub(crate) struct Entry {
    pub id: String,
    pub stored: StoredEvent,
}

/// A reading and the id of the event that recorded it: what a card names when the reader removes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IdentifiedReading {
    pub id: String,
    pub reading: Reading,
}

/// What replay produces: the live readings in causal order, the dictionary associations, and the event ids a removal
/// hides.
#[derive(Debug, Clone, Default)]
pub(crate) struct Projection {
    pub readings: Vec<IdentifiedReading>,
    pub associations: BTreeMap<String, String>,
    pub removed: HashSet<String>,
    pub study: StudyProjection,
}

/// **The study projection** (plan-history-and-learning §5): the latest note per target, the grade chain in causal
/// order with its voids, and the evidence a re-anchor moved.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StudyProjection {
    pub notes: BTreeMap<String, NoteEntry>,
    pub grades: BTreeMap<String, Vec<GradeEntry>>,
    /// Each target's current evidence: what a re-anchor moved, else the note's own target.
    pub evidence: BTreeMap<String, StudyTarget>,
    /// The grades a resolution kept, per target: an undo the reader settled is not asked about again (ADR-0027).
    #[serde(default)]
    pub resolved: BTreeMap<String, HashSet<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NoteEntry {
    pub note: Note,
    /// The note event's id: a revision's parent and the card's `noteHead`.
    pub head: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GradeEntry {
    pub id: String,
    pub record: GradeRecord,
    pub voided: bool,
}

/// A snapshot: the projection, and the log's frontier it was built from (ADR-0024). A snapshot whose frontier is not
/// the log's is discarded, whatever its checksum says.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub version: u32,
    pub projection: u32,
    pub frontier: Frontier,
    pub readings: Vec<IdentifiedReading>,
    pub associations: BTreeMap<String, String>,
    pub removed: Vec<String>,
    pub study: StudyProjection,
}

/// The log's frontier: how many events it holds, the last one, and a digest of the whole set — so a snapshot cannot
/// match a log whose events differ, however equal their count and head.
pub(crate) fn frontier(ids: &[String]) -> Frontier {
    let mut hasher = sha2::Sha256::new();
    use sha2::Digest;
    for id in ids {
        hasher.update(id.as_bytes());
        hasher.update(b"\n");
    }
    let mut digest = String::with_capacity(64);
    for byte in hasher.finalize() {
        digest.push_str(&format!("{byte:02x}"));
    }
    Frontier { events: ids.len() as u64, head: ids.last().cloned().unwrap_or_default(), digest }
}

/// **Causal order**: a child after its parent, whatever the clocks say; unrelated events keep the file's order, which is
/// the order they were written. A cycle cannot come from this writer and is refused, not papered over.
pub(crate) fn ordered(entries: Vec<(String, StoredEvent)>) -> Result<Vec<Entry>, LedgerError> {
    let mut unique: Vec<(String, StoredEvent)> = Vec::new();
    let mut seen = HashSet::new();
    for (id, stored) in entries {
        if seen.insert(id.clone()) {
            unique.push((id, stored));
        }
    }
    let position: HashMap<&str, usize> = unique.iter().enumerate().map(|(i, (id, _))| (id.as_str(), i)).collect();
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); unique.len()];
    let mut parents = vec![0usize; unique.len()];
    for (index, (_, stored)) in unique.iter().enumerate() {
        if let Some(parent) = stored.parent.as_deref()
            && let Some(&at) = position.get(parent)
        {
            if let Some(list) = children.get_mut(at) {
                list.push(index);
            }
            if let Some(count) = parents.get_mut(index) {
                *count += 1;
            }
        }
    }
    let mut ready: std::collections::BTreeSet<usize> =
        (0..unique.len()).filter(|&i| parents.get(i) == Some(&0)).collect();
    let mut order = Vec::with_capacity(unique.len());
    while let Some(index) = ready.pop_first() {
        order.push(index);
        if let Some(list) = children.get(index) {
            for &child in list {
                if let Some(count) = parents.get_mut(child) {
                    *count -= 1;
                    if *count == 0 {
                        ready.insert(child);
                    }
                }
            }
        }
    }
    if order.len() != unique.len() {
        return Err(LedgerError::Corrupt("a parent chain cycles".into()));
    }
    let mut by_index: HashMap<usize, Entry> = HashMap::with_capacity(unique.len());
    for (index, (id, stored)) in unique.into_iter().enumerate() {
        by_index.insert(index, Entry { id, stored });
    }
    let mut rebuilt = Vec::with_capacity(order.len());
    for index in order {
        rebuilt.push(by_index.remove(&index).ok_or_else(|| LedgerError::Corrupt("an event went missing".into()))?);
    }
    Ok(rebuilt)
}

/// Replays the events into the projection. Readings a removal hides are dropped here; a later restore brings them back,
/// because the removal set is applied once, at the end.
pub(crate) fn project(entries: &[Entry]) -> Projection {
    let mut projection = Projection::default();
    for entry in entries {
        match &entry.stored.event {
            Event::Reading(reading) => {
                projection.readings.push(IdentifiedReading { id: entry.id.clone(), reading: reading.clone() });
            }
            Event::DictionaryJoined(joined) => {
                projection.associations.insert(joined.edition.clone(), joined.lineage.clone());
            }
            Event::DictionarySplit(split) => {
                projection.associations.insert(split.edition.clone(), split.new_lineage.clone());
            }
            Event::Removed(removal) => {
                for id in &removal.event_ids {
                    projection.removed.insert(id.clone());
                }
            }
            Event::Restored(restore) => {
                for id in &restore.event_ids {
                    projection.removed.remove(id);
                }
            }
            Event::Erased(_) => {}
            Event::NoteSaved(note) | Event::NoteRevised(note) => {
                let key = note.target.key();
                projection.study.evidence.entry(key.clone()).or_insert_with(|| note.target.clone());
                projection.study.notes.insert(key, NoteEntry { note: note.clone(), head: entry.id.clone() });
            }
            Event::Graded(record) => {
                let key = record.target.key();
                projection.study.evidence.entry(key.clone()).or_insert_with(|| record.target.clone());
                projection.study.grades.entry(key).or_default().push(GradeEntry {
                    id: entry.id.clone(),
                    record: record.clone(),
                    voided: false,
                });
            }
            Event::Undone(undo) => {
                let key = undo.target.key();
                if let Some(list) = projection.study.grades.get_mut(&key)
                    && let Some(grade) = list.iter_mut().find(|grade| grade.id == undo.grade_event)
                {
                    grade.voided = true;
                }
            }
            Event::Reanchored(moved) => {
                let key = moved.target.key();
                let mut target = moved.target.clone();
                target.edition = moved.to_edition.clone();
                target.definition_hash = moved.definition_hash.clone();
                projection.study.evidence.insert(key, target);
            }
            Event::Resolved(resolution) => {
                // **The reader chose a branch** (ADR-0027): every other candidate is voided, and so is everything that
                // descended from one — a branch is kept or dropped whole, never spliced.
                let key = resolution.target.key();
                projection.study.resolved.entry(key.clone()).or_default().insert(resolution.keep.clone());
                if let Some(list) = projection.study.grades.get_mut(&key) {
                    let keep = resolution.keep.clone();
                    let revision =
                        list.iter().find(|grade| grade.id == keep).map(|grade| grade.record.revision.clone());
                    if let Some(revision) = revision {
                        let mut doomed: Vec<String> = list
                            .iter()
                            .filter(|grade| grade.id != keep && !grade.voided && grade.record.revision == revision)
                            .map(|grade| grade.id.clone())
                            .collect();
                        let mut pending = doomed.clone();
                        while let Some(id) = pending.pop() {
                            for grade in list.iter() {
                                let descends = grade.record.revision == id;
                                if descends && !grade.voided && !doomed.contains(&grade.id) && grade.id != keep {
                                    doomed.push(grade.id.clone());
                                    pending.push(grade.id.clone());
                                }
                            }
                        }
                        for grade in list.iter_mut() {
                            if doomed.contains(&grade.id) {
                                grade.voided = true;
                            }
                        }
                    }
                }
            }
        }
    }
    projection.readings.retain(|reading| !projection.removed.contains(&reading.id));
    projection
}

impl Projection {
    /// The live note for an identity key, its target carrying the current evidence.
    pub(crate) fn note(&self, key: &str) -> Option<Note> {
        let entry = self.study.notes.get(key)?;
        let mut note = entry.note.clone();
        if let Some(target) = self.study.evidence.get(key) {
            note.target = target.clone();
        }
        Some(note)
    }

    /// The card a target's note enrols, with the state the latest non-void grade left.
    pub(crate) fn card(&self, key: &str) -> Option<StudyCard> {
        let entry = self.study.notes.get(key)?;
        let mut target = entry.note.target.clone();
        if let Some(evidence) = self.study.evidence.get(key) {
            target = evidence.clone();
        }
        let mut note = entry.note.clone();
        note.target = target.clone();
        let grades = self.study.grades.get(key);
        let last = grades.and_then(|list| list.iter().rev().find(|grade| !grade.voided));
        Some(StudyCard {
            target,
            note,
            state: last.map(|grade| grade.record.after).unwrap_or_default(),
            head: last.map(|grade| grade.id.clone()).unwrap_or_default(),
            note_head: entry.head.clone(),
            grades: grades.map_or(0, |list| list.iter().filter(|grade| !grade.voided).count() as u64),
        })
    }

    pub(crate) fn cards(&self) -> Vec<StudyCard> {
        self.study.notes.keys().filter_map(|key| self.card(key)).collect()
    }

    /// The cards due now — a new card is due at once — soonest first, new cards before scheduled ones. **A conflicted
    /// card is not in the queue** (ADR-0027): it waits for the reader's choice, not for time.
    pub(crate) fn queue(&self, now: f64, limit: usize) -> Vec<StudyCard> {
        let conflicted: HashSet<String> = self.conflicts().into_iter().map(|conflict| conflict.target.key()).collect();
        let mut due: Vec<StudyCard> = self
            .cards()
            .into_iter()
            .filter(|card| !conflicted.contains(&card.target.key()))
            .filter(|card| is_due(card, now))
            .collect();
        due.sort_by(|left, right| {
            let when = |card: &StudyCard| card.state.due.unwrap_or(f64::NEG_INFINITY);
            when(left)
                .partial_cmp(&when(right))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(left.target.key().cmp(&right.target.key()))
        });
        due.truncate(limit);
        due
    }

    /// **The cards two branches left in two states** (ADR-0027): two live grades that extend the same revision, or a live
    /// grade whose parent another device undid. Oldest candidate first, so the reader reads the story in order.
    pub(crate) fn conflicts(&self) -> Vec<CardConflict> {
        self.study.notes.keys().filter_map(|key| self.conflict(key)).collect()
    }

    pub(crate) fn conflict(&self, key: &str) -> Option<CardConflict> {
        let grades = self.study.grades.get(key)?;
        let live: Vec<&GradeEntry> = grades.iter().filter(|grade| !grade.voided).collect();
        let mut candidates: Vec<&GradeEntry> = Vec::new();
        let mut by_revision: BTreeMap<&str, Vec<&GradeEntry>> = BTreeMap::new();
        for grade in &live {
            by_revision.entry(grade.record.revision.as_str()).or_default().push(grade);
        }
        for group in by_revision.values() {
            if group.len() > 1 {
                for grade in group {
                    if !candidates.iter().any(|seen| seen.id == grade.id) {
                        candidates.push(grade);
                    }
                }
            }
        }
        // **An undo met a grade it never saw**: device B undid revision 7 while device A graded from it. The undo stands
        // or the branch does, and both answers are the reader's.
        for grade in &live {
            // A keep that left the branch standing answered this question already.
            let settled = self.study.resolved.get(key).is_some_and(|kept| kept.contains(&grade.id));
            if grade.record.revision.is_empty() || settled {
                continue;
            }
            if let Some(parent) = grades.iter().find(|parent| parent.id == grade.record.revision)
                && parent.voided
            {
                for candidate in [parent, grade] {
                    if !candidates.iter().any(|seen| seen.id == candidate.id) {
                        candidates.push(candidate);
                    }
                }
            }
        }
        if candidates.is_empty() {
            return None;
        }
        let entry = self.study.notes.get(key)?;
        let mut target = entry.note.target.clone();
        if let Some(evidence) = self.study.evidence.get(key) {
            target = evidence.clone();
        }
        let mut note = entry.note.clone();
        note.target = target.clone();
        candidates.sort_by(|left, right| {
            left.record
                .at
                .partial_cmp(&right.record.at)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(left.id.cmp(&right.id))
        });
        Some(CardConflict {
            target,
            note,
            candidates: candidates
                .into_iter()
                .map(|grade| ConflictCandidate {
                    id: grade.id.clone(),
                    grade: grade.record.grade,
                    at: grade.record.at,
                    device: grade.record.device.clone(),
                    after: grade.record.after,
                })
                .collect(),
        })
    }

    /// How many cards are due, and the earliest future due instant when none is. **A conflicted card is counted
    /// nowhere** (ADR-0027): it is not a card the queue will show, so saying it is due would send the reader to an empty
    /// review window.
    pub(crate) fn summary(&self, now: f64) -> ReviewSummary {
        let conflicted: HashSet<String> = self.conflicts().into_iter().map(|conflict| conflict.target.key()).collect();
        let cards: Vec<StudyCard> =
            self.cards().into_iter().filter(|card| !conflicted.contains(&card.target.key())).collect();
        let due = cards.iter().filter(|card| is_due(card, now)).count() as u64;
        let next_due = if due > 0 {
            None
        } else {
            cards
                .iter()
                .filter_map(|card| card.state.due)
                .filter(|when| when.is_finite() && *when > now)
                .min_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal))
                .map(|when| when as u64)
        };
        ReviewSummary { due, next_due }
    }
}

/// A new card is due at once; a scheduled one at its due instant.
pub(crate) fn is_due(card: &StudyCard, now: f64) -> bool {
    card.state.is_new() || card.state.due.is_some_and(|when| when <= now)
}

/// **The days the drawer shows.** Newest card first within a day; days newest first, at most [`MAX_DAYS`] back and
/// [`MAX_CARDS`] cards in all. A day is a calendar day in the reader's zone, not a 24-hour window.
pub(crate) fn history(readings: &[IdentifiedReading], now: f64, utc_offset_seconds: i32) -> History {
    if !now.is_finite() {
        return History { days: Vec::new() };
    }
    let offset = f64::from(utc_offset_seconds);
    let today = local_day(now + offset);
    let mut days: BTreeMap<i64, Vec<IdentifiedReading>> = BTreeMap::new();
    let mut cards = 0usize;
    let mut counted: HashSet<String> = HashSet::new();
    for index in newest_first(readings) {
        let Some(held) = readings.get(index) else { continue };
        if !held.reading.at.is_finite() {
            continue;
        }
        let day = local_day(held.reading.at + offset);
        if today - day >= MAX_DAYS {
            continue;
        }
        let key = format!("{day}\u{1f}{}", card_key(&held.reading));
        if !counted.contains(&key) {
            if cards >= MAX_CARDS {
                continue;
            }
            cards += 1;
            counted.insert(key);
        }
        days.entry(day).or_default().push(held.clone());
    }
    let days = days
        .into_iter()
        .rev()
        .map(|(day, list)| Day {
            id: day_identifier(day),
            start: day as f64 * SECONDS_PER_DAY - offset,
            label: day_label(day, today),
            cards: collapse(list),
        })
        .collect();
    History { days }
}

/// The readings' indices, newest `at` first; a tie goes to the later causal position, the one recorded last.
fn newest_first(readings: &[IdentifiedReading]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..readings.len()).collect();
    order.sort_by(|a, b| {
        let left = readings.get(*a).map(|held| held.reading.at);
        let right = readings.get(*b).map(|held| held.reading.at);
        match (left, right) {
            (Some(left), Some(right)) => right.partial_cmp(&left).unwrap_or(std::cmp::Ordering::Equal).then(b.cmp(a)),
            _ => a.cmp(b),
        }
    });
    order
}

/// The event ids the reader's history keeps under the same rule: what compaction may keep and what it may drop.
pub(crate) fn kept(readings: &[IdentifiedReading], now: f64, utc_offset_seconds: i32) -> HashSet<String> {
    let offset = f64::from(utc_offset_seconds);
    let today = local_day(now + offset);
    let mut cards = 0usize;
    let mut counted: HashSet<String> = HashSet::new();
    let mut kept = HashSet::new();
    for index in newest_first(readings) {
        let Some(held) = readings.get(index) else { continue };
        if !held.reading.at.is_finite() {
            continue;
        }
        let day = local_day(held.reading.at + offset);
        if today - day >= MAX_DAYS {
            continue;
        }
        let key = format!("{day}\u{1f}{}", card_key(&held.reading));
        if !counted.contains(&key) {
            if cards >= MAX_CARDS {
                continue;
            }
            cards += 1;
            counted.insert(key);
        }
        kept.insert(held.id.clone());
    }
    kept
}

/// The snapshot's bytes: the projection, framed so a torn snapshot is recognised.
pub(crate) fn snapshot_bytes(projection: &Projection, frontier: &Frontier) -> Result<Vec<u8>, LedgerError> {
    let snapshot = Snapshot {
        version: 1,
        projection: PROJECTION_VERSION,
        frontier: frontier.clone(),
        readings: projection.readings.clone(),
        associations: projection.associations.clone(),
        removed: projection.removed.iter().cloned().collect(),
        study: projection.study.clone(),
    };
    let payload = serde_json::to_vec(&snapshot).map_err(|error| LedgerError::Corrupt(error.to_string()))?;
    Ok(crate::frame::frame(&payload))
}

/// The snapshot's projection, when it is whole and its frontier is the log's; otherwise `None`, and the log is replayed.
pub(crate) fn snapshot_projection(bytes: &[u8], frontier: &Frontier) -> Option<Projection> {
    let (payload, end) = next_frame(bytes, 0)?;
    if end != bytes.len() {
        return None;
    }
    let snapshot: Snapshot = serde_json::from_slice(payload).ok()?;
    if snapshot.version != 1 || snapshot.projection != PROJECTION_VERSION || &snapshot.frontier != frontier {
        return None;
    }
    Some(Projection {
        readings: snapshot.readings,
        associations: snapshot.associations,
        removed: snapshot.removed.into_iter().collect(),
        study: snapshot.study,
    })
}

/// The id of a stored event's payload, as the log computes it. The tests' check that re-framing keeps an id.
#[cfg(test)]
pub(crate) fn id_of(stored: &StoredEvent) -> Result<String, LedgerError> {
    let payload = serde_json::to_vec(stored).map_err(|error| LedgerError::Corrupt(error.to_string()))?;
    Ok(crate::frame::event_id(&payload))
}

/// One card per reading the reader cannot tell apart: the word, the sentence, the edition, the entry and its
/// occurrence. The newest fronts it, `times` says how often it was met, and `events` names every event it is made of.
fn collapse(newest_first: Vec<IdentifiedReading>) -> Vec<Card> {
    let mut order: Vec<(Reading, Vec<String>)> = Vec::new();
    let mut at: HashMap<String, usize> = HashMap::new();
    for held in newest_first {
        let key = card_key(&held.reading);
        match at.get(&key) {
            Some(&index) => {
                if let Some(card) = order.get_mut(index) {
                    card.1.push(held.id);
                }
            }
            None => {
                at.insert(key, order.len());
                order.push((held.reading, vec![held.id]));
            }
        }
    }
    order.into_iter().map(|(reading, events)| Card { reading, times: events.len() as u32, events }).collect()
}

pub(crate) fn card_key(reading: &Reading) -> String {
    format!(
        "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
        reading.surface, reading.sentence, reading.edition, reading.entry_key, reading.occurrence
    )
}

/// The local calendar day as a whole number of days since the epoch: floor((t + offset) / 86400).
fn local_day(seconds: f64) -> i64 {
    (seconds / SECONDS_PER_DAY).floor() as i64
}

fn day_label(day: i64, today: i64) -> DayLabel {
    match today - day {
        0 => DayLabel::Today,
        1 => DayLabel::Yesterday,
        2..=6 => DayLabel::Weekday,
        _ => DayLabel::Date,
    }
}

/// `yyyy-MM-dd` from a day count, built from components so the identifier is the same in every language.
fn day_identifier(day: i64) -> String {
    let (year, month, date) = civil_from_days(day);
    format!("{year:04}-{month:02}-{date:02}")
}

/// Howard Hinnant's `civil_from_days`: days since 1970-01-01 to a proleptic Gregorian date.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }), m, d)
}
