//! The one form query, catalog and pack meet in, and the fuzzy metric over it.

use unicode_normalization::UnicodeNormalization;

/// NFD, Unicode's lowercase mapping, then NFC: canonical equivalence and caseless comparison by lowercasing (not full
/// case folding: `ß` stays `ß`). Nothing is stripped: a mark is part of the spelling.
pub(super) fn normalize(text: &str) -> String {
    let lower = text.nfd().collect::<String>().to_lowercase();
    lower.nfc().collect()
}

/// NFC alone: canonical equivalence, case kept. What decides whether a pack word is spelled exactly as a headword.
pub(super) fn canonical(text: &str) -> String {
    text.nfc().collect()
}

/// **The distance itself is the lookup's** (2026-10-27): a reader's misspelling and the explorer's fuzzy mode are the
/// same question asked of the same words, so there is one implementation — `xdict_lookup::osa`, its own tests moved
/// with it — and not a second copy here.
pub(super) use xdict_lookup::osa;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_form_query_and_catalog_meet_in_is_nfd_lowered_nfc() {
        assert_eq!(normalize("CAFE\u{301}"), "caf\u{e9}");
        assert_eq!(canonical("caf\u{e9}"), "caf\u{e9}");
    }
}
