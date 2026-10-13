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
        let lines: Vec<&str> = text.lines().map(|l| l.trim_end_matches('\r')).collect();
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
        if self.is_empty() || !record.contains('`') {
            return Cow::Borrowed(record);
        }
        let mut out = String::with_capacity(record.len() * 2);
        let mut open: Option<&str> = None;
        let mut rest = record;
        while let Some(at) = rest.find('`') {
            out.push_str(rest.get(..at).unwrap_or(""));
            let after = rest.get(at + 1..).unwrap_or("");
            // A marker is digits between backticks; one naming no style, a number too large for any among them, is
            // kept whole, both backticks.
            let marker = after.find('`').and_then(|end| {
                let digits = after.get(..end)?;
                if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                Some((digits.parse::<u32>().ok().and_then(|n| self.0.get(&n)), end))
            });
            match marker {
                Some((Some((begin, end_text)), end)) => {
                    if let Some(close) = open.take() {
                        out.push_str(close);
                    }
                    out.push_str(begin);
                    open = Some(end_text);
                    rest = after.get(end + 1..).unwrap_or("");
                }
                Some((None, end)) => {
                    out.push_str(rest.get(at..at + end + 2).unwrap_or(""));
                    rest = after.get(end + 1..).unwrap_or("");
                }
                None => {
                    out.push('`');
                    rest = after;
                }
            }
        }
        out.push_str(rest);
        if let Some(close) = open {
            out.push_str(close);
        }
        Cow::Owned(out)
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
