//! What the index keeps for lookup (ADR-0007 decisions 15 and 16): each key's tier-2 form, and which keys are
//! internal.

use std::borrow::Cow;

use unicode_normalization::UnicodeNormalization;
use xdict_mdx::Error;
use xdict_mdx::index::{Derive, Growth, KeyList};

/// The tier-2 algorithm and internal-key rule together, stored in every index built under them: raised by any
/// change to either, so indexes built before are rebuilt.
pub const NORMALIZATION: u32 = 1;

/// XDict's lookup policy, as the index builds and searches it.
pub struct Policy;

impl Derive for Policy {
    fn version(&self) -> u32 {
        NORMALIZATION
    }

    fn unmark<'a>(&self, text: &'a str) -> Cow<'a, str> {
        unmark(text)
    }

    /// The NFKD text, collected by doubling, up to twice its length; the NFKC text collected from it, up to three
    /// times its length while it grows, its old and its new buffer at once; each text at most [`NFKD_GROWTH`]
    /// times the key. Short keys hold more than their share, in least capacities and normalization's buffers:
    /// [`UNMARK_FIXED`]. Both measured by an allocator (`tests/unmark_memory.rs`).
    fn growth(&self) -> Growth {
        Growth { per_byte: 5 * NFKD_GROWTH, fixed: UNMARK_FIXED }
    }

    fn internal(&self, keys: &dyn KeyList) -> Result<Vec<bool>, Error> {
        internal(keys)
    }
}

/// The most NFKD lengthens text, in UTF-8 bytes per byte: U+FDFA (ARABIC LIGATURE SALLALLAHOU ALAYHE
/// WASALLAM, 3 bytes) decomposes to 18 characters, 33 bytes. Measured over every scalar value by a test.
const NFKD_GROWTH: u64 = 11;

/// What `unmark` holds of a key beyond five times [`NFKD_GROWTH`] a byte, at most. Measured over every scalar
/// value, alone and in runs, by `tests/unmark_memory.rs`, which fails when it moves.
const UNMARK_FIXED: u64 = 219;

/// Superscript digits: at the end of a key, a homograph number (YHDCD `AAA²`).
const SUPERSCRIPT_DIGITS: [char; 10] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

/// Printed in a headword but not part of the word: stress marks (OED `ˌblue-ˈblood`), which Unicode calls
/// letters, and syllable dots (LDOCE `re‧cap`, MW `base·ment·less`).
const NOT_THE_WORD: [char; 4] = ['ˈ', 'ˌ', '·', '‧'];

/// A key or query without what a reader cannot type, in this order (decision 15): trailing superscript digits
/// (a homograph number; NFKC alone would make `AAA²` `AAA2`), then NFKD, the diacritics removed, stress marks
/// and syllable dots removed, NFKC. The file's own folding follows, in the index.
///
/// Diacritics are the combining marks of the blocks Unicode names for them (`U+0300`–`U+036F` and its
/// supplements), not every combining mark: a kana voicing mark (`が` is `か` and `U+3099`) or an Indic vowel
/// sign is part of the letter, and removing it would make different words match.
pub fn unmark(text: &str) -> Cow<'_, str> {
    if text.is_ascii() || is_plain(text) {
        return Cow::Borrowed(text);
    }
    let body = text.trim_end_matches(SUPERSCRIPT_DIGITS);
    let body = if body.is_empty() { text } else { body };
    let plain: String =
        body.nfkd().filter(|&c| !is_diacritic(c) && !NOT_THE_WORD.contains(&c)).collect::<String>().nfkc().collect();
    if plain == text { Cow::Borrowed(text) } else { Cow::Owned(plain) }
}

/// Text [`unmark`] returns as it is, known without normalising it: already in NFKD and in NFKC (so both are the
/// identity), and with nothing to remove. Most non-ASCII keys (CJK, Cyrillic) are; checking costs one pass.
fn is_plain(text: &str) -> bool {
    use unicode_normalization::{IsNormalized, is_nfkc_quick, is_nfkd_quick};
    !text.ends_with(SUPERSCRIPT_DIGITS)
        && !text.chars().any(|c| is_diacritic(c) || NOT_THE_WORD.contains(&c))
        && is_nfkd_quick(text.chars()) == IsNormalized::Yes
        && is_nfkc_quick(text.chars()) == IsNormalized::Yes
}

/// A combining mark from one of the blocks of diacritics.
fn is_diacritic(c: char) -> bool {
    matches!(c, '\u{0300}'..='\u{036F}' | '\u{1AB0}'..='\u{1AFF}' | '\u{1DC0}'..='\u{1DFF}' | '\u{20D0}'..='\u{20FF}' | '\u{FE20}'..='\u{FE2F}')
}

/// The shapes internal keys take in the 25 (`core-api.md` finding 8): LDOCE's 95,162 and OALD's 548 `@…`, OED's
/// 52,401 composite `a--b--c`, CALD's 2,153 `♯…` and 1,942 `↑…`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Shape {
    At,
    Composite,
    Sharp,
    Up,
}

const SHAPES: [Shape; 4] = [Shape::At, Shape::Composite, Shape::Sharp, Shape::Up];

fn shape(key: &str) -> Option<Shape> {
    match key.chars().next()? {
        '@' => Some(Shape::At),
        '♯' => Some(Shape::Sharp),
        '↑' => Some(Shape::Up),
        _ if key.contains("--") => Some(Shape::Composite),
        _ => None,
    }
}

/// Keys of a shape are internal only where the shape is a pattern of the file: at least this many keys…
const PATTERN_KEYS: usize = 100;
/// …and at least this share of them, in parts per thousand (0.5 %). A lone `@home` stays public.
const PATTERN_PER_MILLE: usize = 5;

/// Which keys of a file are internal (decision 16): those of a shape the file uses as a pattern.
pub fn internal(keys: &dyn KeyList) -> Result<Vec<bool>, Error> {
    let mut shapes = Vec::with_capacity(keys.len());
    let mut counts = [0usize; SHAPES.len()];
    for i in 0..keys.len() {
        let found = shape(keys.key(i)?);
        if let Some(count) = found.and_then(|s| SHAPES.iter().position(|&t| t == s)).and_then(|p| counts.get_mut(p)) {
            *count += 1;
        }
        shapes.push(found);
    }
    let pattern = |s: Shape| {
        let count = SHAPES.iter().position(|&t| t == s).and_then(|p| counts.get(p)).copied().unwrap_or(0);
        is_pattern(count, keys.len())
    };
    Ok(shapes.into_iter().map(|s| s.is_some_and(pattern)).collect())
}

/// Whether `count` keys of one shape among `total` make it a pattern. Compared in `u128`: in `usize`,
/// `count * 1000` overflowed on wasm32 past 4,294,967 keys of a shape.
fn is_pattern(count: usize, total: usize) -> bool {
    count >= PATTERN_KEYS && count as u128 * 1000 >= total as u128 * PATTERN_PER_MILLE as u128
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]
    use super::*;

    /// Codex objection 19's fixtures: a trailing superscript is a homograph number; one inside a key is a
    /// character of it, which NFKC makes a digit.
    /// The share is compared without overflow, whatever the counts: on wasm32 `usize` is 32 bits, and a file
    /// may hold 10 million keys.
    #[test]
    fn a_pattern_share_does_not_overflow() {
        let huge = usize::MAX / 100;
        assert!(is_pattern(huge, huge));
        assert!(!is_pattern(PATTERN_KEYS, huge));
        assert!(is_pattern(PATTERN_KEYS, PATTERN_KEYS * 200));
        assert!(!is_pattern(PATTERN_KEYS, PATTERN_KEYS * 200 + 1));
    }

    #[test]
    fn superscript_homographs_and_formulas() {
        assert_eq!(unmark("AAA²"), "AAA");
        assert_eq!(unmark("AAA¹²"), "AAA");
        assert_eq!(unmark("AAA2"), "AAA2");
        assert_eq!(unmark("H²O"), "H2O");
        assert_eq!(unmark("²"), "2", "a key that is only a superscript keeps it");
    }

    #[test]
    fn accents_stress_marks_and_syllable_dots() {
        assert_eq!(unmark("café"), "cafe");
        assert_eq!(unmark("cafe\u{301}"), "cafe", "decomposed as precomposed");
        assert_eq!(unmark("ˌblue-ˈblood"), "blue-blood");
        assert_eq!(unmark("22--lipoˈchondria"), "22--lipochondria");
        assert_eq!(unmark("re‧cap"), "recap");
        assert_eq!(unmark("base·ment·less"), "basementless");
        assert_eq!(unmark("ﬁne"), "fine", "compatibility characters");
    }

    /// Marks that are part of a letter stay.
    #[test]
    fn letters_keep_their_own_marks() {
        assert_eq!(unmark("が"), "が");
        assert_ne!(unmark("が"), unmark("か"));
        assert_eq!(unmark("हिंदी"), "हिंदी");
        assert_eq!(unmark("词典"), "词典");
    }

    #[test]
    fn plain_text_is_borrowed() {
        assert!(matches!(unmark("run"), Cow::Borrowed(_)));
        assert!(matches!(unmark("词典"), Cow::Borrowed(_)));
    }

    /// The quick check never says "plain" of text the full algorithm would change: every code point of the
    /// BMP's letters and marks alone, and after a letter.
    #[test]
    fn the_quick_check_agrees_with_the_algorithm() {
        let full = |text: &str| -> String {
            let body = text.trim_end_matches(SUPERSCRIPT_DIGITS);
            let body = if body.is_empty() { text } else { body };
            body.nfkd().filter(|&c| !is_diacritic(c) && !NOT_THE_WORD.contains(&c)).collect::<String>().nfkc().collect()
        };
        let mut checked = 0;
        for c in (0x80u32..0x3_0000).filter_map(char::from_u32) {
            for text in [c.to_string(), format!("a{c}"), format!("{c}b")] {
                if is_plain(&text) {
                    assert_eq!(full(&text), text, "{:04X}", c as u32);
                    checked += 1;
                }
            }
        }
        assert!(checked > 100_000, "{checked}");
    }

    struct Keys(Vec<String>);
    impl KeyList for Keys {
        fn len(&self) -> usize {
            self.0.len()
        }
        fn key(&self, i: usize) -> Result<&str, Error> {
            Ok(&self.0[i])
        }
    }

    fn keys(words: usize, shaped: &[(&str, usize)]) -> Keys {
        let mut keys: Vec<String> = (0..words).map(|i| format!("word{i}")).collect();
        for (prefix, n) in shaped {
            keys.extend((0..*n).map(|i| format!("{prefix}{i}")));
        }
        Keys(keys)
    }

    /// [`NFKD_GROWTH`] is measured, not guessed: no scalar value's NFKD is longer in UTF-8 than that many times
    /// its own length, and one is exactly that long (U+FDFA, 3 bytes to 33). A Unicode update that lengthens a
    /// decomposition fails here, and with it the index build's memory account (`Derive::growth`).
    #[test]
    fn nfkd_growth_is_measured_over_every_scalar_value() {
        let mut most = (0u64, 1u64, '\0');
        for c in (0..=0x10FFFFu32).filter_map(char::from_u32) {
            let (from, to) = (c.len_utf8() as u64, c.nfkd().map(char::len_utf8).sum::<usize>() as u64);
            assert!(to <= NFKD_GROWTH * from, "U+{:04X}: {from} bytes to {to}", c as u32);
            if to * most.1 > most.0 * from {
                most = (to, from, c);
            }
        }
        assert_eq!(
            most.0.div_ceil(most.1),
            NFKD_GROWTH,
            "U+{:04X} is the most: the constant is not tight",
            most.2 as u32
        );
    }

    /// The lengths [`Policy::growth`] rests on: the NFKC text is no longer than the NFKD text it is made from,
    /// since a primary composite is no longer in UTF-8 than what it replaces, and both are within it. Every
    /// scalar value alone, and runs of the longest decomposition; the allocator's measure is
    /// `tests/unmark_memory.rs`.
    #[test]
    fn unmark_texts_are_within_their_growth() {
        for c in (0..=0x10FFFFu32).filter_map(char::from_u32) {
            let nfd: String = c.to_string().nfd().collect();
            if nfd.chars().count() > 1 && nfd.nfc().eq(std::iter::once(c)) {
                assert!(c.len_utf8() <= nfd.len(), "U+{:04X} composes longer than its parts", c as u32);
            }
            let text = c.to_string();
            let nfkd: String = text.nfkd().collect();
            assert!(unmark(&text).len() <= nfkd.len(), "U+{:04X}", c as u32);
        }
        for text in ["\u{FDFA}".repeat(1000), "\u{FDFA}é²".repeat(300), "Å\u{301}\u{FDFA}".repeat(200)] {
            let nfkd: String = text.nfkd().collect();
            assert!(nfkd.len() as u64 <= NFKD_GROWTH * text.len() as u64);
            assert!(unmark(&text).len() <= nfkd.len());
            assert!((nfkd.len() + unmark(&text).len()) as u64 <= Policy.growth().of(text.len() as u64));
        }
    }

    /// Codex objection 21: a shape is internal where the file uses it as a pattern, not wherever it appears.
    #[test]
    fn a_shape_is_internal_only_as_a_pattern_of_the_file() {
        let lone = keys(1000, &[("@home", 1), ("a--b--c", 1)]);
        assert!(internal(&lone).unwrap().iter().all(|&i| !i), "a lone @home and a--b--c stay public");
        let ldoce = keys(1000, &[("@collocations_", 150)]);
        assert_eq!(internal(&ldoce).unwrap().iter().filter(|&&i| i).count(), 150);
        let few = keys(100_000, &[("@x", 120)]);
        assert!(internal(&few).unwrap().iter().all(|&i| !i), "120 of 100,120 is under 0.5 %");
        let oed = keys(1000, &[("12--", 100), ("↑", 99)]);
        let marked = internal(&oed).unwrap();
        assert_eq!(marked.iter().filter(|&&i| i).count(), 100, "each shape is judged alone");
        assert!(!internal(&keys(1000, &[("*ad-", 300)])).unwrap().iter().any(|&i| i), "Etymonline's roots are words");
    }
}
