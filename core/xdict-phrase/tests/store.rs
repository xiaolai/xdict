//! The per-edition inventory store: a round trip, and every reason to refuse one.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use xdict_phrase::{EXTRACTOR, FORMAT, Inventory, Separation, Slots, Versions, forms};

const EDITION: &str = "mdx-sha256-v1:abababababababababababababababababababababababababababababababab";

fn versions() -> Versions {
    Versions { policy: 7, folding: 3 }
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
        Slots::english().with_abbreviations(),
    )
}

#[test]
fn a_store_round_trips_its_phrases_and_its_slots() {
    let store = inventory();
    let bytes = store.encode(EDITION, versions()).unwrap();
    let decoded = Inventory::decode(&bytes, EDITION, versions()).expect("the store does not decode");
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
    assert!(Inventory::decode(&bytes, other_edition, versions()).is_none());
    for changed in [Versions { policy: 8, folding: 3 }, Versions { policy: 7, folding: 4 }] {
        assert!(Inventory::decode(&bytes, EDITION, changed).is_none(), "{changed:?} was read");
    }
    let mut altered = bytes.clone();
    if let Some(byte) = altered.get_mut(4) {
        *byte ^= 1;
    }
    assert!(Inventory::decode(&altered, EDITION, versions()).is_none(), "a changed format byte was read");
    assert_eq!(FORMAT, 1);
    assert_eq!(EXTRACTOR, 1);
}

#[test]
fn a_truncated_or_corrupt_store_is_refused() {
    let bytes = inventory().encode(EDITION, versions()).unwrap();
    for cut in [0, 3, bytes.len() / 2, bytes.len() - 1] {
        assert!(Inventory::decode(&bytes[..cut], EDITION, versions()).is_none(), "truncated at {cut} was read");
    }
    let mut flipped = bytes.clone();
    let middle = flipped.len() / 2;
    if let Some(byte) = flipped.get_mut(middle) {
        *byte ^= 0x40;
    }
    assert!(Inventory::decode(&flipped, EDITION, versions()).is_none(), "a corrupt store was read");
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
    let decoded = Inventory::decode(&inventory().encode(EDITION, versions()).unwrap(), EDITION, versions()).expect("decode");
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
    assert!(Inventory::decode(&altered, EDITION, versions()).is_none(), "a count past the bytes was read");
}
