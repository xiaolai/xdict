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

/// A distance no answer reaches, with room to add 1 without overflow.
const FAR: usize = usize::MAX / 4;

/// Optimal string alignment distance between `a` and `b` (insertion, deletion, substitution and the transposition of
/// two adjacent scalars, each 1; no substring edited twice), or `None` once it must exceed `max`. Rows stop early when
/// every cell of one is past `max`.
pub(super) fn osa(a: &[char], b: &[char], max: usize) -> Option<usize> {
    if a.len().abs_diff(b.len()) > max {
        return None;
    }
    let width = b.len() + 1;
    let mut before: Vec<usize> = vec![FAR; width];
    let mut previous: Vec<usize> = (0..width).collect();
    let mut current: Vec<usize> = vec![FAR; width];
    let at = |row: &[usize], j: usize| row.get(j).copied().unwrap_or(FAR);
    for (i, ai) in a.iter().enumerate() {
        let i = i + 1;
        if let Some(first) = current.first_mut() {
            *first = i;
        }
        let mut row_min = i;
        for (j, bj) in b.iter().enumerate() {
            let j = j + 1;
            let cost = usize::from(ai != bj);
            let mut value = (at(&previous, j) + 1).min(at(&current, j - 1) + 1).min(at(&previous, j - 1) + cost);
            if i > 1 && j > 1 {
                let a_before = a.get(i - 2);
                let b_before = b.get(j - 2);
                if a_before == Some(bj) && b_before == Some(ai) {
                    value = value.min(at(&before, j - 2) + 1);
                }
            }
            if let Some(cell) = current.get_mut(j) {
                *cell = value;
            }
            row_min = row_min.min(value);
        }
        if row_min > max {
            return None;
        }
        std::mem::swap(&mut before, &mut previous);
        std::mem::swap(&mut previous, &mut current);
    }
    let distance = at(&previous, b.len());
    (distance <= max).then_some(distance)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(a: &str, b: &str) -> Option<usize> {
        let a: Vec<char> = a.chars().collect();
        let b: Vec<char> = b.chars().collect();
        osa(&a, &b, 3)
    }

    #[test]
    fn osa_counts_transpositions_once_and_never_edits_twice() {
        assert_eq!(d("form", "form"), Some(0));
        assert_eq!(d("form", "from"), Some(1));
        assert_eq!(d("form", "fro"), Some(2));
        assert_eq!(d("ca", "abc"), Some(3));
        assert_eq!(d("", "abc"), Some(3));
        assert_eq!(d("abcd", ""), None);
        assert_eq!(normalize("CAFE\u{301}"), "caf\u{e9}");
    }
}
