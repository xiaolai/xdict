//! The two JSON writings a pack needs, both exactly as the reference implementation writes them:
//!
//! - the pack's lines, `json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))`;
//! - the report, `json.dumps(obj, indent=2, sort_keys=True)` plus a newline, which escapes non-ASCII.

use std::fmt::Write as _;

/// A JSON value as this crate writes one. Objects are held as pairs and written in key order, so a caller never
/// has to sort them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Str(String),
    Bool(bool),
    Int(u64),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    /// A string value.
    pub fn str(text: impl Into<String>) -> Self {
        Self::Str(text.into())
    }

    /// An object of the given pairs.
    pub fn obj(pairs: Vec<(&str, Value)>) -> Self {
        Self::Obj(pairs.into_iter().map(|(key, value)| (key.to_string(), value)).collect())
    }
}

/// One line of a pack, no newline: keys sorted, no spaces, non-ASCII kept as is.
pub fn canonical(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, false, None, 0, &mut out);
    out
}

/// The report, `indent = 2`, non-ASCII escaped, with a trailing newline.
pub fn report(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, true, Some(2), 0, &mut out);
    out.push('\n');
    out
}

fn write_value(value: &Value, ascii_only: bool, indent: Option<usize>, level: usize, out: &mut String) {
    match value {
        Value::Str(text) => write_str(text, ascii_only, out),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Int(number) => {
            let _ = write!(out, "{number}");
        }
        Value::Arr(items) => {
            write_items(items.iter().map(|item| (None, item)), ascii_only, indent, level, '[', ']', out)
        }
        Value::Obj(pairs) => {
            let mut sorted: Vec<&(String, Value)> = pairs.iter().collect();
            sorted.sort_by(|left, right| left.0.cmp(&right.0));
            write_items(
                sorted.into_iter().map(|(key, item)| (Some(key.as_str()), item)),
                ascii_only,
                indent,
                level,
                '{',
                '}',
                out,
            )
        }
    }
}

/// Arrays and objects share one writer: `level` is the indentation of the enclosing line.
fn write_items<'a>(
    items: impl Iterator<Item = (Option<&'a str>, &'a Value)>,
    ascii_only: bool,
    indent: Option<usize>,
    level: usize,
    open: char,
    close: char,
    out: &mut String,
) {
    let mut peekable = items.peekable();
    let empty = peekable.peek().is_none();
    out.push(open);
    if empty {
        out.push(close);
        return;
    }
    let mut first = true;
    for (key, value) in peekable {
        if first {
            first = false;
        } else {
            out.push(',');
        }
        match indent {
            None => {}
            Some(width) => {
                out.push('\n');
                out.extend(std::iter::repeat_n(' ', width * (level + 1)));
            }
        }
        if let Some(key) = key {
            write_str(key, ascii_only, out);
            out.push(':');
            if indent.is_some() {
                out.push(' ');
            }
        }
        write_value(value, ascii_only, indent, level + 1, out);
    }
    if let Some(width) = indent {
        out.push('\n');
        out.extend(std::iter::repeat_n(' ', width * level));
    }
    out.push(close);
}

/// A JSON string, escaped as Python's `json` escapes one: the five short escapes, `\u00xx` for the other control
/// characters, and — when `ascii_only` — `\uXXXX` for everything above ASCII, a surrogate pair past the BMP.
fn write_str(text: &str, ascii_only: bool, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            ch if (ch as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", ch as u32);
            }
            ch if ascii_only && !ch.is_ascii() => {
                let code = ch as u32;
                if code > 0xFFFF {
                    let offset = code - 0x1_0000;
                    let high = 0xD800 + (offset >> 10);
                    let low = 0xDC00 + (offset & 0x3FF);
                    let _ = write!(out, "\\u{high:04x}\\u{low:04x}");
                } else {
                    let _ = write!(out, "\\u{code:04x}");
                }
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

/// A byte string's SHA-256, lowercase hex.
pub fn hex(digest: &[u8]) -> String {
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    #[test]
    fn a_pack_line_sorts_its_keys_and_keeps_non_ascii() {
        let value = Value::obj(vec![
            ("type", Value::str("origin")),
            ("form", Value::str("caf\u{e9}")),
            ("uncertain", Value::Bool(false)),
        ]);
        assert_eq!(canonical(&value), r#"{"form":"café","type":"origin","uncertain":false}"#);
    }

    #[test]
    fn a_pack_line_escapes_as_python_does() {
        let value = Value::obj(vec![("quote", Value::str("a\"b\\c\nd\u{1}e\u{2028}"))]);
        assert_eq!(canonical(&value), "{\"quote\":\"a\\\"b\\\\c\\nd\\u0001e\u{2028}\"}");
    }

    #[test]
    fn the_report_indents_and_escapes_non_ascii() {
        let value = Value::obj(vec![
            ("b", Value::Arr(vec![Value::Int(1), Value::Int(2)])),
            ("a", Value::str("caf\u{e9}")),
            ("c", Value::Obj(Vec::new())),
            ("d", Value::Arr(Vec::new())),
            ("e", Value::str("\u{1F600}")),
        ]);
        let expected = concat!(
            "{\n",
            "  \"a\": \"caf\\u00e9\",\n",
            "  \"b\": [\n",
            "    1,\n",
            "    2\n",
            "  ],\n",
            "  \"c\": {},\n",
            "  \"d\": [],\n",
            "  \"e\": \"\\ud83d\\ude00\"\n",
            "}\n",
        );
        assert_eq!(report(&value), expected);
    }

    #[test]
    fn hex_is_lowercase_two_digits_a_byte() {
        assert_eq!(hex(&[0x00, 0x7f, 0xff]), "007fff");
    }
}
