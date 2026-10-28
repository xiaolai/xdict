//! MorphyNet's English TSVs: tagged inflections, and typed derivations kept only where their morpheme attaches.

use std::collections::BTreeMap;
use std::io::Read;

use crate::Emit;
use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::Value;
use crate::limits::{
    MORPHYNET_DERI_POS, MORPHYNET_INFL_KNOWN_MALFORMED, MORPHYNET_INFL_POS, MORPHYNET_KINDS,
    MORPHYNET_UNDOCUMENTED_POS, MORPHYNET_VOWELS, lookup,
};
use crate::record::RawRecord;
use crate::skips::{Skips, sample};
use crate::sources::Lines;
use crate::text::casefold;

/// The `index`th field of a row, or `""` when the row is short (which `tsv_lines` has already refused).
fn at<'a>(fields: &[&'a str], index: usize) -> &'a str {
    fields.get(index).copied().unwrap_or("")
}

/// A row of a source TSV that has been read from a line and split on tabs.
fn tsv_lines<R: Read>(
    reader: R,
    source: &str,
    columns: usize,
    mut each: impl FnMut(u64, Vec<&str>) -> PackResult<()>,
) -> PackResult<()> {
    let mut lines = Lines::new(reader, source);
    while let Some(line) = lines.next_line()? {
        let content = line.check(source)?;
        if content.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = content.split('\t').collect();
        if fields.len() != columns {
            return Err(PackError::at(
                PackErrorKind::Malformed,
                source,
                line.number,
                format!("{} fields, expected {columns}", fields.len()),
            ));
        }
        each(line.number, fields)?;
    }
    Ok(())
}

/// MorphyNet `lemma, form, features, segmentation` lines to form records.
///
/// The features' first item is the part of speech (`N`, `V`, `ADJ`, `ADV`); the rest, across `|`-separated
/// morphemes and `;`-joined features, are the tags, verbatim and in order. A form equal to its lemma (the `-`
/// segmentation rows) needs no record. A known malformed quoted row is counted in `skips`; an unknown part of
/// speech is counted in `unknown`.
pub fn parse_morphynet_inflection<R: Read>(
    reader: R,
    source: &str,
    unknown: &mut BTreeMap<String, u64>,
    skips: &mut Skips,
    emit: Emit<'_>,
) -> PackResult<()> {
    tsv_lines(reader, source, 4, |number, fields| {
        let known = MORPHYNET_INFL_KNOWN_MALFORMED
            .iter()
            .any(|row| row.iter().zip(fields.iter()).all(|(expected, actual)| expected == actual));
        if known {
            skips.record("known malformed quoted row", Some(sample(vec![("line", Value::Int(number))])));
            return Ok(());
        }
        let (lemma, form, features) = (at(&fields, 0), at(&fields, 1), at(&fields, 2));
        if lemma.is_empty() || form.is_empty() || features.is_empty() {
            return Err(PackError::at(PackErrorKind::Malformed, source, number, "an empty field"));
        }
        let items: Vec<&str> = features.split('|').flat_map(|part| part.split(';')).collect();
        let code = items.first().copied().unwrap_or("");
        let mut tags: Vec<String> = Vec::new();
        for tag in items.iter().skip(1) {
            if !tag.is_empty() && !tags.iter().any(|seen| seen == tag) {
                tags.push((*tag).to_string());
            }
        }
        let Some(pos) = lookup(&MORPHYNET_INFL_POS, code) else {
            *unknown.entry(format!("inflection POS {code}")).or_insert(0) += 1;
            return Ok(());
        };
        if form == lemma || tags.is_empty() {
            return Ok(());
        }
        emit(RawRecord::new(
            "form",
            vec![
                ("form", RawRecord::text(form)),
                ("lemma", RawRecord::text(lemma)),
                ("pos", RawRecord::text(pos)),
                ("tags", RawRecord::list(tags)),
                ("source", RawRecord::text(source)),
            ],
        ))
    })
}

/// MorphyNet `source, target, source POS, target POS, morpheme, type` lines to derivation records.
///
/// POS codes `N V J R` become noun, verb, adj, adv; `type` is prefix or suffix, and the morpheme is written as an
/// affix of that type (`im` prefix becomes `im-`, `ly` suffix becomes `-ly`). A row is kept only when its morpheme
/// attaches to its base.
pub fn parse_morphynet_derivation<R: Read>(
    reader: R,
    source: &str,
    unknown: &mut BTreeMap<String, u64>,
    skips: &mut Skips,
    emit: Emit<'_>,
) -> PackResult<()> {
    tsv_lines(reader, source, 6, |number, fields| {
        let (base, derived, base_code, derived_code, morpheme, kind) =
            (at(&fields, 0), at(&fields, 1), at(&fields, 2), at(&fields, 3), at(&fields, 4), at(&fields, 5));
        if base.is_empty() || derived.is_empty() {
            return Err(PackError::at(PackErrorKind::Malformed, source, number, "an empty word"));
        }
        let this_sample = || {
            sample(vec![
                ("line", Value::Int(number)),
                ("base", Value::str(base)),
                ("derived", Value::str(derived)),
                ("basePos", Value::str(base_code)),
                ("derivedPos", Value::str(derived_code)),
                ("affix", Value::str(morpheme)),
                ("kind", Value::str(kind)),
            ])
        };
        let codes = [base_code, derived_code];
        let mut problems: Vec<String> = Vec::new();
        for code in codes {
            if lookup(&MORPHYNET_DERI_POS, code).is_none() && !MORPHYNET_UNDOCUMENTED_POS.contains(&code) {
                problems.push(format!("derivation POS {code}"));
            }
        }
        if !MORPHYNET_KINDS.contains(&kind) {
            problems.push(format!("derivation type {kind}"));
        }
        if !problems.is_empty() {
            for problem in problems {
                *unknown.entry(problem).or_insert(0) += 1;
            }
            return Ok(());
        }
        if codes.iter().any(|code| MORPHYNET_UNDOCUMENTED_POS.contains(code)) {
            skips.record("undocumented POS U", Some(this_sample()));
            return Ok(());
        }
        if base == derived {
            skips.record("derived word equals its base", Some(this_sample()));
            return Ok(());
        }
        let affix = morpheme.trim().trim_matches('-');
        if affix.is_empty() {
            skips.record("empty morpheme", Some(this_sample()));
            return Ok(());
        }
        if !attaches(base, derived, affix, kind) {
            skips.record(&format!("{kind} spelling change not modelled"), Some(this_sample()));
            return Ok(());
        }
        let written = if kind == "prefix" { format!("{affix}-") } else { format!("-{affix}") };
        let base_pos = lookup(&MORPHYNET_DERI_POS, base_code).unwrap_or("noun");
        let derived_pos = lookup(&MORPHYNET_DERI_POS, derived_code).unwrap_or("noun");
        emit(RawRecord::new(
            "derivation",
            vec![
                ("base", RawRecord::text(base)),
                ("basePos", RawRecord::text(base_pos)),
                ("derived", RawRecord::text(derived)),
                ("derivedPos", RawRecord::text(derived_pos)),
                ("kind", RawRecord::text(kind)),
                ("source", RawRecord::text(source)),
                ("affix", RawRecord::text(written)),
            ],
        ))
    })
}

/// Whether `derived` is `base` with `affix` attached, compared case-folded.
///
/// The rules are deliberately conservative: ordinary allomorphy is not modelled and gives `false`, as does a
/// nonsense row. A prefix attaches as `affix + base` or `affix + "-" + base`. A suffix attaches literally, or
/// through silent-e drop, y to i after a consonant (unless the suffix starts with `i`), or a doubled final
/// consonant (not w, x or y) after a single vowel before a suffix starting with a vowel or `y`.
pub fn attaches(base: &str, derived: &str, affix: &str, kind: &str) -> bool {
    let base = casefold(base);
    let derived = casefold(derived);
    let affix = casefold(affix);
    if base.is_empty() || affix.is_empty() {
        return false;
    }
    if kind == "prefix" {
        return derived == format!("{affix}{base}") || derived == format!("{affix}-{base}");
    }
    if derived == format!("{base}{affix}") {
        return true;
    }
    let letters: Vec<char> = base.chars().collect();
    let count = letters.len();
    // The base with its last `cut` characters dropped.
    let shorter = |cut: usize| -> String { letters.iter().take(count.saturating_sub(cut)).collect() };
    let at = |from_end: usize| -> Option<char> { letters.get(count.checked_sub(from_end)?).copied() };
    if base.ends_with('e') && derived == format!("{}{affix}", shorter(1)) {
        return true;
    }
    if base.ends_with("le") && affix.starts_with('l') && derived == format!("{}{affix}", shorter(2)) {
        return true;
    }
    if count >= 2
        && at(1) == Some('y')
        && at(2).is_some_and(|ch| !is_vowel(ch))
        && !affix.starts_with('i')
        && derived == format!("{}i{affix}", shorter(1))
    {
        return true;
    }
    let Some(last) = at(1) else { return false };
    let penultimate = at(2);
    let antepenultimate = at(3);
    count >= 2
        && last.is_alphabetic()
        && !is_vowel(last)
        && !matches!(last, 'w' | 'x' | 'y')
        && penultimate.is_some_and(is_vowel)
        && (count == 2 || antepenultimate.is_some_and(|ch| !is_vowel(ch)))
        && affix.chars().next().is_some_and(|first| is_vowel(first) || first == 'y')
        && derived == format!("{base}{last}{affix}")
}

fn is_vowel(ch: char) -> bool {
    MORPHYNET_VOWELS.contains(&ch)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    fn inflection(text: &str) -> PackResult<(Vec<RawRecord>, BTreeMap<String, u64>, Skips)> {
        let mut out = Vec::new();
        let mut unknown = BTreeMap::new();
        let mut skips = Skips::new();
        {
            let mut emit = |record: RawRecord| {
                out.push(record);
                Ok(())
            };
            parse_morphynet_inflection(text.as_bytes(), "morphynet-infl", &mut unknown, &mut skips, &mut emit)?;
        }
        Ok((out, unknown, skips))
    }

    fn derivation(text: &str) -> PackResult<(Vec<RawRecord>, BTreeMap<String, u64>, Skips)> {
        let mut out = Vec::new();
        let mut unknown = BTreeMap::new();
        let mut skips = Skips::new();
        {
            let mut emit = |record: RawRecord| {
                out.push(record);
                Ok(())
            };
            parse_morphynet_derivation(text.as_bytes(), "morphynet-deri", &mut unknown, &mut skips, &mut emit)?;
        }
        Ok((out, unknown, skips))
    }

    #[test]
    fn an_inflection_is_a_form_with_its_tags() {
        let (records, _, _) = inflection("cat\tcats\tN;pl\tcat|s\n").unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].kind(), Some("form"));
    }

    #[test]
    fn a_form_equal_to_its_lemma_needs_no_record() {
        let (records, _, _) = derivation("cat\tcats\tN\tN\ts\tsuffix\n").unwrap();
        assert_eq!(records.len(), 1);
        let (nothing, _, _) = inflection("cat\tcat\tN;sg\t-\n").unwrap();
        assert!(nothing.is_empty());
    }

    #[test]
    fn an_unknown_inflection_pos_is_counted() {
        let (records, unknown, _) = inflection("cat\tcats\tX;pl\t-\n").unwrap();
        assert!(records.is_empty());
        assert_eq!(unknown.get("inflection POS X"), Some(&1));
    }

    #[test]
    fn the_two_known_malformed_rows_are_skipped_and_counted() {
        let (records, _, skips) =
            inflection("\"softly\t softly\"\t\"|\t\"softly|\"\n\"softly\t softly\"\tcomparable\t-\n").unwrap();
        assert!(records.is_empty());
        assert_eq!(skips.counts().get("known malformed quoted row"), Some(&2));
    }

    #[test]
    fn an_undocumented_pos_u_is_skipped() {
        let (records, _, skips) = derivation("cat\tcats\tU\tN\t-\tsuffix\n").unwrap();
        assert!(records.is_empty());
        assert_eq!(skips.counts().get("undocumented POS U"), Some(&1));
    }

    #[test]
    fn a_spelling_change_not_modelled_is_skipped() {
        let (records, _, skips) = derivation("run\tember\tN\tN\tumb\tprefix\n").unwrap();
        assert!(records.is_empty());
        assert_eq!(skips.counts().get("prefix spelling change not modelled"), Some(&1));
    }

    /// **The fold is Python's**, at every code point where a plain lowercase would disagree: a final sigma, `ß`, the
    /// long s, a ligature, and Georgian Mtavruli, which no Unicode 9 table folds.
    #[test]
    fn the_case_fold_is_the_reference_implementations() {
        assert_eq!(crate::text::casefold("ΣΟΦΟΣ"), "σοφοσ");
        assert_eq!(crate::text::casefold("Straße"), "strasse");
        assert_eq!(crate::text::casefold("ſun"), "sun");
        assert_eq!(crate::text::casefold("ﬀ"), "ff");
        assert_eq!(crate::text::casefold("Ა"), "ა");
        assert_eq!(crate::text::casefold("Æ"), "æ");
        assert_eq!(crate::text::casefold("Run"), "run");
    }

    #[test]
    fn the_attachment_rules_are_the_ones_the_reference_proves() {
        assert!(attaches("run", "runner", "er", "suffix"));
        assert!(attaches("run", "runny", "y", "suffix"));
        assert!(attaches("happy", "happiness", "ness", "suffix"));
        assert!(attaches("possible", "possibly", "ly", "suffix"));
        assert!(attaches("record", "recordable", "able", "suffix"));
        assert!(attaches("record", "rerecord", "re", "prefix"));
        assert!(attaches("record", "re-record", "re", "prefix"));
        assert!(!attaches("possible", "possibility", "ity", "suffix"));
        assert!(!attaches("run", "ember", "umb", "prefix"));
        assert!(!attaches("run", "runs", "-", "suffix"));
    }
}
