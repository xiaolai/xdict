//! **How far one spelling is from another** (2026-10-27). The metric a reader's misspelling is answered with, and the
//! one the word explorer's fuzzy mode already used — moved here so there is one implementation and not two. Measured on
//! the 24-dictionary corpus (`examples/nearest_bench.rs`): a miss answered inside the first letter's band costs 34 ms
//! (distance 1) or 42 ms (distance 2) across every dictionary, against 439–537 ms for a full scan.

/// A distance no answer reaches, with room to add 1 without overflow.
const FAR: usize = usize::MAX / 4;

/// Optimal string alignment distance between `a` and `b` (insertion, deletion, substitution and the transposition of
/// two adjacent scalars, each 1; no substring edited twice), or `None` once it must exceed `max`. Rows stop early when
/// every cell of one is past `max`.
pub fn osa(a: &[char], b: &[char], max: usize) -> Option<usize> {
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
    }
}
