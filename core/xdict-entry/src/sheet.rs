//! MDict's compact styles (`core-api.md` finding 14: 30 of the 330 real files): a header `StyleSheet` of
//! numbered pairs of opening and closing text, and records that mark runs with `` `n` ``. A marker opens style
//! `n`, closing the style before it; the last style closes at the end of the record.

use std::borrow::Cow;
use std::collections::HashMap;

/// A header's `StyleSheet`: lines in threes, a number, the text that opens the style, the text that closes it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct StyleSheet(HashMap<u32, (String, String)>);

impl StyleSheet {
    pub fn parse(text: &str) -> Self {
        // Split on every newline, keeping a last empty line: `lines()` drops it, and with it an empty closing text.
        let lines: Vec<&str> = text.split('\n').map(|l| l.trim_end_matches('\r')).collect();
        let mut styles = HashMap::new();
        for group in lines.chunks(3) {
            if let [number, open, close] = group
                && let Ok(n) = number.trim().parse()
            {
                styles.insert(n, ((*open).to_owned(), (*close).to_owned()));
            }
        }
        Self(styles)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// How many styles it holds.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// `record` with its markers replaced. A marker naming no style is left as it is.
    pub fn apply<'a>(&self, record: &'a str) -> Cow<'a, str> {
        // No text passes `usize::MAX`, so this is never `Exceeded`.
        self.apply_within(record, usize::MAX).unwrap_or(Cow::Borrowed(record))
    }

    /// [`apply`](Self::apply) held to `max` bytes: `Exceeded` as soon as the expansion would pass it, before it
    /// is all written. A record of many markers can expand far past its own size.
    pub fn apply_within<'a>(&self, record: &'a str, max: usize) -> Result<Cow<'a, str>, crate::Exceeded> {
        if self.is_empty() || !record.contains('`') {
            return if record.len() <= max { Ok(Cow::Borrowed(record)) } else { Err(crate::Exceeded) };
        }
        let mut out = Within { text: String::with_capacity(record.len().saturating_mul(2).min(max)), max };
        let mut open: Option<&str> = None;
        let mut rest = record;
        while let Some(at) = rest.find('`') {
            crate::work::scanned(at + 1);
            out.push_str(rest.get(..at).unwrap_or(""))?;
            let after = rest.get(at + 1..).unwrap_or("");
            // A marker is digits between backticks; one naming no style, a number too large for any among them, is
            // kept whole, both backticks.
            let closing = after.find('`');
            crate::work::scanned(closing.map_or(after.len(), |e| e + 1));
            let marker = closing.and_then(|end| {
                let digits = after.get(..end)?;
                if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                Some((digits.parse::<u32>().ok().and_then(|n| self.0.get(&n)), end))
            });
            match marker {
                Some((Some((begin, end_text)), end)) => {
                    if let Some(close) = open.take() {
                        out.push_str(close)?;
                    }
                    out.push_str(begin)?;
                    open = Some(end_text);
                    rest = after.get(end + 1..).unwrap_or("");
                }
                Some((None, end)) => {
                    out.push_str(rest.get(at..at + end + 2).unwrap_or(""))?;
                    rest = after.get(end + 1..).unwrap_or("");
                }
                None => {
                    out.push_str("`")?;
                    rest = after;
                }
            }
        }
        out.push_str(rest)?;
        if let Some(close) = open {
            out.push_str(close)?;
        }
        Ok(Cow::Owned(out.text))
    }
}

/// An expansion held to `max` bytes.
struct Within {
    text: String,
    max: usize,
}

impl Within {
    fn push_str(&mut self, s: &str) -> Result<(), crate::Exceeded> {
        if self.text.len().saturating_add(s.len()) > self.max {
            return Err(crate::Exceeded);
        }
        self.text.push_str(s);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers_open_and_close_styles() {
        let sheet = StyleSheet::parse("1\n<b>\n</b>\r\n2\n<i>\n</i>\n");
        assert_eq!(sheet.apply("`1`run`2`to move"), "<b>run</b><i>to move</i>");
        assert_eq!(sheet.apply("plain `1`bold"), "plain <b>bold</b>");
        assert_eq!(sheet.apply("`9`x and `a` b"), "`9`x and `a` b", "unknown markers stay");
        assert!(matches!(sheet.apply("no markers"), Cow::Borrowed(_)));
        assert!(StyleSheet::parse("").is_empty());
    }

    /// A record of many markers expands each into its style's text; held to `max`, the expansion stops as soon as
    /// it would pass it, so a small record cannot grow without bound. Under `max` it is what `apply` gives.
    #[test]
    fn an_expansion_past_its_ceiling_is_refused_early() {
        let sheet = StyleSheet::parse(&format!("1\n{}\n\n", "x".repeat(1000)));
        let record = "`1`".repeat(1_000_000);
        // Refused early: read about as far as its first MiB of expansion (some 3 KiB of record), not to the end.
        let (refused, read) = crate::work::counting(|| sheet.apply_within(&record, 1 << 20));
        assert_eq!(refused, Err(crate::Exceeded));
        assert!((1..=64 << 10).contains(&read), "read {read} of the record's {} bytes", record.len());
        let ordinary = "`1`run and `2`more";
        let whole = sheet.apply(ordinary);
        assert_eq!(sheet.apply_within(ordinary, whole.len()).as_deref(), Ok(whole.as_ref()));
        assert_eq!(sheet.apply_within(ordinary, whole.len() - 1), Err(crate::Exceeded));
        assert!(matches!(sheet.apply_within("no markers", 0), Err(crate::Exceeded)));
        assert!(matches!(sheet.apply_within("no markers", 10), Ok(Cow::Borrowed(_))));
    }

    /// A style whose closing text is empty is a style: the last line, empty, is its closing text.
    #[test]
    fn an_empty_closing_line_at_the_end_is_kept() {
        let sheet = StyleSheet::parse("1\n<b>\n");
        assert_eq!(sheet.apply("`1`x"), "<b>x");
        let sheet = StyleSheet::parse("1\r\n<b>\r\n\r\n2\r\n<i>\r\n</i>\r\n");
        assert_eq!(sheet.apply("`1`a`2`b"), "<b>a<i>b</i>");
    }

    /// An unknown numeric marker is kept whole: its closing backtick opens nothing.
    #[test]
    fn an_unknown_marker_keeps_both_backticks() {
        let sheet = StyleSheet::parse("1\n<b>\n</b>\n");
        assert_eq!(sheet.apply("`9`1`x"), "`9`1`x");
        assert_eq!(sheet.apply("`9``1`x"), "`9`<b>x</b>");
        // A number too large for any style is as unknown as `9`, not a lone backtick.
        assert_eq!(sheet.apply("`99999999999`1`x"), "`99999999999`1`x");
        assert_eq!(sheet.apply("`99999999999``1`x"), "`99999999999`<b>x</b>");
    }
}
