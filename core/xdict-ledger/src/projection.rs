//! **The log's order and its projections** (ADR-0024, ADR-0025): causal order by each event's parent, the live readings
//! a history shows, the dictionary associations the reader's joins and splits recorded, and the removal and erase
//! tombstones that hide content without carrying it.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::frame::next_frame;
use crate::{Card, Day, DayLabel, Event, Frontier, History, LedgerError, MAX_CARDS, MAX_DAYS, Reading};

/// The projection's own version: a change to what is projected discards every snapshot built before it.
pub(crate) const PROJECTION_VERSION: u32 = 1;
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
        }
    }
    projection.readings.retain(|reading| !projection.removed.contains(&reading.id));
    projection
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
