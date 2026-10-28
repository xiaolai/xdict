//! CMUdict: stressed ARPAbet, every variant, no part of speech.

use std::io::Read;

use crate::Emit;
use crate::error::{PackError, PackErrorKind, PackResult};
use crate::record::{RawRecord, check_arpabet};
use crate::sources::Lines;
use crate::text::has_control;

/// CMUdict lines to ARPAbet pronunciation records, one per variant, with no part of speech.
///
/// `word(2)` names a variant of `word`; `;;;` lines and `#` comments are dropped. An unknown phone, a misplaced
/// stress digit, a variant index under 2, a control character or a line with no phones is `malformed`.
pub fn parse_cmudict<R: Read>(reader: R, source: &str, emit: Emit<'_>) -> PackResult<()> {
    let mut lines = Lines::new(reader, source);
    while let Some(line) = lines.next_line()? {
        let content = line.check(source)?;
        if content.starts_with(";;;") {
            continue;
        }
        let text = content.split('#').next().unwrap_or("").trim();
        if text.is_empty() {
            continue;
        }
        let mut parts = text.split_whitespace();
        let Some(first) = parts.next() else {
            return Err(PackError::at(PackErrorKind::Malformed, source, line.number, "a word with no phones"));
        };
        let phones: Vec<&str> = parts.collect();
        if phones.is_empty() {
            return Err(PackError::at(PackErrorKind::Malformed, source, line.number, "a word with no phones"));
        }
        let word = match variant_index(first) {
            Some((base, index)) => {
                if index < 2 {
                    return Err(PackError::at(
                        PackErrorKind::Malformed,
                        source,
                        line.number,
                        format!("variant index under 2 in '{first}'"),
                    ));
                }
                base
            }
            None => first,
        };
        if has_control(word) {
            return Err(PackError::at(PackErrorKind::Malformed, source, line.number, "control character in a word"));
        }
        let owned: Vec<String> = phones.iter().map(|phone| phone.to_string()).collect();
        if let Some(problem) = check_arpabet(&owned) {
            return Err(PackError::at(PackErrorKind::Malformed, source, line.number, problem));
        }
        emit(RawRecord::new(
            "pronunciation",
            vec![
                ("word", RawRecord::text(word)),
                ("system", RawRecord::text("arpabet")),
                ("phonemes", RawRecord::list(owned)),
                ("source", RawRecord::text(source)),
            ],
        ))?;
    }
    Ok(())
}

/// `word(2)` as `(word, 2)`: the reference matches `(.+)\((\d+)\)` whole, so the last `(` is the one that counts.
fn variant_index(text: &str) -> Option<(&str, u64)> {
    let inner = text.strip_suffix(')')?;
    let open = inner.rfind('(')?;
    let (base, rest) = inner.split_at_checked(open)?;
    let digits = rest.strip_prefix('(')?;
    if base.is_empty() || digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    // A number too large for `u64` is certainly over the floor of 2.
    Some((base, digits.parse::<u64>().unwrap_or(u64::MAX)))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    fn parse(text: &str) -> PackResult<Vec<RawRecord>> {
        let mut out = Vec::new();
        let mut emit = |record: RawRecord| {
            out.push(record);
            Ok(())
        };
        parse_cmudict(text.as_bytes(), "cmu", &mut emit)?;
        Ok(out)
    }

    #[test]
    fn a_line_becomes_a_pronunciation_and_comments_are_dropped() {
        let records = parse(";;; a comment\nhello HH AH0 L OW1\nworld W ER1 L D # a note\n").unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].kind(), Some("pronunciation"));
        assert_eq!(records[0].fields.get(1).map(|(key, _)| key.as_str()), Some("word"));
    }

    #[test]
    fn a_variant_is_its_base_word() {
        let records = parse("talk T AO1 K\ntalk(2) T AO2 K\n").unwrap();
        assert_eq!(records.len(), 2);
    }

    #[test]
    fn a_variant_index_under_two_is_refused() {
        let error = parse("talk(1) T AO1 K\n").unwrap_err();
        assert_eq!(error.kind(), PackErrorKind::Malformed);
        assert!(error.to_string().contains("variant index under 2"));
    }

    #[test]
    fn a_bad_phone_is_refused_with_its_line() {
        let error = parse("a AA1\ntalk XX\n").unwrap_err();
        assert_eq!(error.line(), Some(2));
        assert!(error.to_string().contains("unknown phone"));
    }

    #[test]
    fn a_word_with_no_phones_is_refused() {
        assert!(parse("hello\n").unwrap_err().to_string().contains("a word with no phones"));
    }
}
