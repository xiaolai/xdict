//! WI-12's repairs at render (`dev-docs/measurements/2026-10-15-mdx-health/`, "Disposition"), applied to an entry's
//! text between tags, never to a tag, an attribute, a script or a style:
//! - C0 control characters other than tab, line feed and carriage return go, as do DEL and a byte-order mark past
//!   the record's first character: none renders as anything a reader wants;
//! - a C1 control character is a Windows-1252 byte its maker read as Latin-1 (in the 25: a dash lost between two words,
//!   curly quotes around one): it is read as Windows-1252, unless that character follows it already (a dash written
//!   twice), when it goes, as do the five bytes Windows-1252 leaves undefined. Dropped, they would join words;
//! - a literal `\n` becomes a line break when no backslash precedes it and the run's end (a tag, or the record's
//!   end) or whitespace follows it; any other (`\n\t\ta`, `\\n`, MWU's `\t\` notation) is left as written.
//!
//! One pass over the run, so linear in it. Nothing here writes `<` or `&`: a removal can join a `<` the rewriter
//! has already written `&lt;` only to text, never into a tag.

use std::borrow::Cow;

/// Whether `c` is a character the repair removes or replaces, the byte-order mark aside.
fn stray(c: char) -> bool {
    matches!(c, '\u{0}'..='\u{8}' | '\u{b}' | '\u{c}' | '\u{e}'..='\u{1f}' | '\u{7f}'..='\u{9f}')
}

/// Windows-1252's characters for bytes 0x80 to 0x9F; `None` where it defines none.
const WINDOWS_1252: [Option<char>; 32] = [
    Some('€'),
    None,
    Some('‚'),
    Some('ƒ'),
    Some('„'),
    Some('…'),
    Some('†'),
    Some('‡'),
    Some('ˆ'),
    Some('‰'),
    Some('Š'),
    Some('‹'),
    Some('Œ'),
    None,
    Some('Ž'),
    None,
    None,
    Some('‘'),
    Some('’'),
    Some('“'),
    Some('”'),
    Some('•'),
    Some('–'),
    Some('—'),
    Some('˜'),
    Some('™'),
    Some('š'),
    Some('›'),
    Some('œ'),
    None,
    Some('ž'),
    Some('Ÿ'),
];

/// The Windows-1252 character a C1 control stands for.
fn windows_1252(c: char) -> Option<char> {
    let at = (c as u32).checked_sub(0x80)?;
    WINDOWS_1252.get(at as usize).copied().flatten()
}

/// `run` repaired, and how many repairs were made. `at_start` says the run begins the record, where a byte-order
/// mark is the encoder's and stays.
pub(crate) fn text(run: &str, at_start: bool) -> (Cow<'_, str>, u64) {
    if !run.chars().any(|c| stray(c) || c == '\u{feff}') && !run.contains("\\n") {
        return (Cow::Borrowed(run), 0);
    }
    let mut out = String::with_capacity(run.len());
    let mut repairs = 0u64;
    let mut prev: Option<char> = None;
    let mut chars = run.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if stray(c) || (c == '\u{feff}' && !(at_start && at == 0)) {
            repairs += 1;
            if let Some(read) = windows_1252(c)
                && chars.peek().is_none_or(|&(_, n)| n != read)
            {
                out.push(read);
                prev = Some(read);
            }
            continue;
        }
        if c == '\\' && prev != Some('\\') && chars.peek().is_some_and(|&(_, n)| n == 'n') {
            let after = run.get(at + 2..).and_then(|r| r.chars().next());
            if after.is_none_or(char::is_whitespace) {
                chars.next();
                out.push('\n');
                repairs += 1;
                prev = Some('\n');
                continue;
            }
        }
        out.push(c);
        prev = Some(c);
    }
    (Cow::Owned(out), repairs)
}
