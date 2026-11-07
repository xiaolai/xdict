//! The per-edition inventory store: a round trip, and every reason to refuse one.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_phrase::{EXTRACTOR, FORMAT, Inventory, Refused, Separation, Slots, Versions, forms};

const EDITION: &str = "mdx-sha256-v1:abababababababababababababababababababababababababababababababab";

fn versions() -> Versions {
    Versions { policy: 7, folding: 3 }
}

fn slots() -> Slots {
    Slots::english().with_abbreviations()
}

fn inventory() -> Inventory {
    Inventory::from_keys(
        [
            "purple passage".to_string(),
            "take something into account".to_string(),
            "give up".to_string(),
            "give up".to_string(),
            "take".to_string(),
            "take something".to_string(),
        ],
        slots(),
    )
}

#[test]
fn a_store_round_trips_its_phrases_and_its_slots() {
    let store = inventory();
    let bytes = store.encode(EDITION, versions()).unwrap();
    let decoded = Inventory::decode(&bytes, EDITION, versions(), &slots()).expect("the store does not decode");
    assert_eq!(decoded.phrases(), store.phrases());
    assert_eq!(decoded.slots(), store.slots());
    assert_eq!(decoded.phrases(), ["give up", "purple passage", "take something into account"]);
    assert!(decoded.slots().is_slot("sth"), "the abbreviation class survives the store");
    assert!(decoded.slots().is_slot("something"));
}

#[test]
fn a_store_of_another_edition_or_other_versions_is_refused() {
    let bytes = inventory().encode(EDITION, versions()).unwrap();
    let other_edition = "mdx-sha256-v1:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    assert!(Inventory::decode(&bytes, other_edition, versions(), &slots()).is_err());
    for changed in [Versions { policy: 8, folding: 3 }, Versions { policy: 7, folding: 4 }] {
        assert!(Inventory::decode(&bytes, EDITION, changed, &slots()).is_err(), "{changed:?} was read");
    }
    let mut altered = bytes.clone();
    if let Some(byte) = altered.get_mut(4) {
        *byte ^= 1;
    }
    assert!(Inventory::decode(&altered, EDITION, versions(), &slots()).is_err(), "a changed format byte was read");
    assert_eq!(FORMAT, 1);
    assert_eq!(EXTRACTOR, 1);
}

#[test]
fn a_truncated_or_corrupt_store_is_refused() {
    let bytes = inventory().encode(EDITION, versions()).unwrap();
    for cut in [0, 3, bytes.len() / 2, bytes.len() - 1] {
        let decoded = Inventory::decode(&bytes[..cut], EDITION, versions(), &slots());
        assert!(decoded.is_err(), "truncated at {cut} was read");
    }
    let mut flipped = bytes.clone();
    let middle = flipped.len() / 2;
    if let Some(byte) = flipped.get_mut(middle) {
        *byte ^= 0x40;
    }
    assert!(Inventory::decode(&flipped, EDITION, versions(), &slots()).is_err(), "a corrupt store was read");
}

#[test]
fn the_builder_keeps_templates_only_and_one_of_each_spelling() {
    let store = inventory();
    assert!(!store.phrases().iter().any(|phrase| phrase == "take"), "a single word is not a phrase");
    assert!(!store.phrases().iter().any(|phrase| phrase == "take something"), "one literal word is not a phrase");
    assert_eq!(store.phrases().iter().filter(|phrase| phrase.as_str() == "give up").count(), 1);
}

#[test]
fn a_decoded_store_still_finds_the_phrase() {
    let bytes = inventory().encode(EDITION, versions()).unwrap();
    let decoded = Inventory::decode(&bytes, EDITION, versions(), &slots()).expect("decode");
    let matcher = decoded.matcher();
    let words: Vec<Vec<String>> =
        "the review was full of purple passage nobody could follow".split_whitespace().map(forms).collect();
    let found = matcher.matches(&words, 5, 12, 3);
    assert_eq!(found.first().map(|m| m.phrase.as_str()), Some("purple passage"));
    assert_eq!(found.first().map(|m| m.separation), Some(Separation::None));
}

/// **A header can lie within its checksum** (audit round 1, 2026-10-26): a phrase count larger than the offsets that
/// follow is refused before anything is reserved for it, so a corrupt store cannot make the decoder allocate.
#[test]
fn a_store_naming_more_phrases_than_its_offsets_hold_is_refused() {
    let store = inventory();
    let bytes = store.encode(EDITION, versions()).unwrap();
    let slot_lens: Vec<usize> = store.slots().words().iter().map(String::len).collect();
    // magic, format, extractor, policy, folding; the edition; the slot count; each slot; then the phrase count.
    let count_at = 20 + 4 + EDITION.len() + 4 + slot_lens.iter().map(|len| 4 + len).sum::<usize>();
    let mut altered = bytes[..bytes.len() - 8].to_vec();
    altered[count_at..count_at + 8].copy_from_slice(&u64::MAX.to_le_bytes());
    let checksum = xxhash_rust::xxh3::xxh3_64(&altered);
    altered.extend_from_slice(&checksum.to_le_bytes());
    assert!(Inventory::decode(&altered, EDITION, versions(), &slots()).is_err(), "a count past the bytes was read");
}

/// **Offsets that leave the arena uncovered or name an empty phrase are refused** (audit round 2): the first must be
/// zero, the last the arena's length, and each pair strictly increasing.
#[test]
fn offsets_that_do_not_cover_the_arena_are_refused() {
    let store = inventory();
    let bytes = store.encode(EDITION, versions()).unwrap();
    let slot_lens: Vec<usize> = store.slots().words().iter().map(String::len).collect();
    let count_at = 20 + 4 + EDITION.len() + 4 + slot_lens.iter().map(|len| 4 + len).sum::<usize>();
    let offsets_at = count_at + 8;
    let mut altered = bytes[..bytes.len() - 8].to_vec();
    // The first phrase's end set to its start: an empty phrase over a nonempty arena.
    let start = u32::from_le_bytes(altered[offsets_at..offsets_at + 4].try_into().unwrap());
    altered[offsets_at + 4..offsets_at + 8].copy_from_slice(&start.to_le_bytes());
    let checksum = xxhash_rust::xxh3::xxh3_64(&altered);
    altered.extend_from_slice(&checksum.to_le_bytes());
    assert!(Inventory::decode(&altered, EDITION, versions(), &slots()).is_err(), "an empty phrase was read");
}

/// **A store read under another slot vocabulary is refused** (audit 2026-11-05, G9): the slots decide which keys are
/// templates and how each one matches, so a store written before a slot was added or removed holds the wrong phrases
/// and would be read as current; the stored list must equal the one this build reads with.
#[test]
fn a_store_written_under_other_slots_is_refused() {
    let bytes = inventory().encode(EDITION, versions()).unwrap();
    let fewer = Slots::english();
    assert!(Inventory::decode(&bytes, EDITION, versions(), &fewer).is_err(), "a store of a wider vocabulary was read");
    let more = slots().with(["something or other"]);
    let narrower = Inventory::decode(&bytes, EDITION, versions(), &more);
    assert!(narrower.is_err(), "a store of a narrower vocabulary was read");
    assert!(Inventory::decode(&bytes, EDITION, versions(), &slots()).is_ok(), "the store's own vocabulary is read");
    let refused = Inventory::decode(&bytes, EDITION, versions(), &fewer).unwrap_err();
    assert_eq!(refused, Refused::Slots);
    assert_eq!(refused.to_string(), "the phrase store was made under another slot vocabulary");
}

/// **A store of an older format is refused with a sentence that names it** (audit 2026-11-05, G9): the layout's
/// version is checked on open, checksum-valid or not, so a store written by an earlier build is built again.
#[test]
fn a_store_of_an_older_format_is_refused_with_its_sentence() {
    let mut bytes = inventory().encode(EDITION, versions()).unwrap();
    let body = bytes.len() - 8;
    bytes[4..8].copy_from_slice(&(FORMAT - 1).to_le_bytes());
    let checksum = xxhash_rust::xxh3::xxh3_64(&bytes[..body]).to_le_bytes();
    bytes[body..].copy_from_slice(&checksum);
    let refused = Inventory::decode(&bytes, EDITION, versions(), &slots()).unwrap_err();
    assert_eq!(refused, Refused::Format(FORMAT - 1));
    let sentence = format!("the phrase store is format {}; this build reads format {FORMAT}", FORMAT - 1);
    assert_eq!(refused.to_string(), sentence);
}
