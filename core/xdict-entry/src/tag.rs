//! A tag's attributes as HTML's tokenizer reads them (its attribute name, value and after-value states). This is the
//! crate's one reader of attributes and of where a tag ends (audit 2026-11-05): the rewrite that writes an entry and
//! every rule that reads one agree on what is an attribute, so a `>` or a `name=` quoted in a value is that value's
//! text to all of them, as it is to a browser.

/// One attribute as written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Attribute<'a> {
    pub(crate) name: &'a str,
    /// What stands between the name and the value: `=` and the spaces around it; empty without a value.
    pub(crate) eq: &'a str,
    pub(crate) value: Option<Value<'a>>,
}

/// An attribute's value as written, without its quotes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Value<'a> {
    pub(crate) quote: Option<char>,
    pub(crate) text: &'a str,
    /// False for a quoted value that never closes: a browser takes the rest of the document into it.
    pub(crate) closed: bool,
}

/// The attribute at the start of `rest`, which starts with neither a space, `/` nor `>`, and what follows it. A name
/// takes its first character whatever it is (`=` and quotes included) and runs to a space, `/`, `>` or `=`; a value
/// follows `=` (spaces around it allowed) and is quoted, or runs to a space or `>`.
pub(crate) fn attribute(rest: &str) -> (Attribute<'_>, &str) {
    let first = rest.chars().next().map_or(0, char::len_utf8);
    let len = rest
        .get(first..)
        .and_then(|r| r.find(|c: char| c.is_ascii_whitespace() || matches!(c, '/' | '>' | '=')))
        .map_or(rest.len(), |e| first + e);
    let name = rest.get(..len).unwrap_or(rest);
    let after = rest.get(len..).unwrap_or("");
    let Some(v) = after.trim_ascii_start().strip_prefix('=') else {
        return (Attribute { name, eq: "", value: None }, after);
    };
    let v = v.trim_ascii_start();
    let eq = after.get(..after.len() - v.len()).unwrap_or("");
    let (value, next) = match v.chars().next() {
        Some(q @ ('"' | '\'')) => {
            let body = v.get(1..).unwrap_or("");
            let end = body.find(q);
            let text = body.get(..end.unwrap_or(body.len())).unwrap_or(body);
            let next = end.and_then(|e| body.get(e + 1..)).unwrap_or("");
            (Value { quote: Some(q), text, closed: end.is_some() }, next)
        }
        _ => {
            let end = v.find(|c: char| c.is_ascii_whitespace() || c == '>').unwrap_or(v.len());
            (Value { quote: None, text: v.get(..end).unwrap_or(v), closed: true }, v.get(end..).unwrap_or(""))
        }
    };
    (Attribute { name, eq, value: Some(value) }, next)
}

/// What follows a tag's name, `tag` written from its `<` or `</`, from its name, or from anywhere after it.
fn past_name(tag: &str) -> &str {
    let inner = tag.strip_prefix("</").or_else(|| tag.strip_prefix('<')).unwrap_or(tag);
    let len = inner.find(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>').unwrap_or(inner.len());
    inner.get(len..).unwrap_or("")
}

/// A tag's attributes in order, as written, up to its `>`.
pub(crate) fn attributes(tag: &str) -> impl Iterator<Item = Attribute<'_>> {
    let mut rest = past_name(tag);
    std::iter::from_fn(move || {
        rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == '/');
        if rest.is_empty() || rest.starts_with('>') {
            return None;
        }
        let (found, next) = attribute(rest);
        rest = next;
        Some(found)
    })
}

/// The value of a tag's attribute `name` (ASCII, any case) as written, empty for one without a value; the first of
/// that name, which is the one a browser keeps.
pub(crate) fn value_of<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    attributes(tag).find(|a| a.name.eq_ignore_ascii_case(name)).map(|a| a.value.map_or("", |v| v.text))
}

/// Where a tag's `>` is (`tag` as [`past_name`] takes it): `None` when it never ends, or ends inside a quoted value
/// that never closes, where a browser takes the rest of the document into the tag.
pub(crate) fn end(tag: &str) -> Option<usize> {
    let mut rest = past_name(tag);
    loop {
        rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == '/');
        if rest.starts_with('>') {
            return Some(tag.len() - rest.len());
        }
        if rest.is_empty() {
            return None;
        }
        let (found, next) = attribute(rest);
        if found.value.is_some_and(|v| !v.closed) {
            return None;
        }
        rest = next;
    }
}

/// A tag's length from its `<` through its `>`; the rest of `from` when it never ends.
pub(crate) fn source_len(from: &str) -> usize {
    end(from).map_or(from.len(), |e| e + 1)
}

/// A tag's source from its `<` through its `>`; the rest of `from` when it never ends.
pub(crate) fn source(from: &str) -> &str {
    from.get(..source_len(from)).unwrap_or(from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(tag: &str) -> Vec<(&str, Option<&str>)> {
        attributes(tag).map(|a| (a.name, a.value.map(|v| v.text))).collect()
    }

    #[test]
    fn a_value_holds_what_is_quoted_in_it() {
        let tag = r#"<img title="a>b c=d" alt='x"y' src=u.png data-x ="1" =odd checked>"#;
        assert_eq!(
            names(tag),
            [
                ("title", Some("a>b c=d")),
                ("alt", Some("x\"y")),
                ("src", Some("u.png")),
                ("data-x", Some("1")),
                ("=odd", None),
                ("checked", None),
            ]
        );
        assert_eq!(value_of(tag, "C"), None, "a name in a value is no attribute");
        assert_eq!(value_of(tag, "SRC"), Some("u.png"));
        assert_eq!(value_of(tag, "checked"), Some(""));
        assert_eq!(value_of(r#"<a href=x href=y>"#, "href"), Some("x"), "the first is the one kept");
        assert_eq!(source(tag), tag);
        assert_eq!(end(r#"<p title="a>b">x"#), Some(14));
        assert_eq!(end(r#"<p title="a>b"#), None, "a value that never closes");
        assert_eq!(end("<p"), None);
        assert_eq!(end(r#"</p a=">">"#), Some(9), "an end tag the same way");
        assert_eq!(end(r#" src="a>b">"#), Some(10), "read from after the name");
        assert_eq!(names(r#"<p a"b=c d/e>"#), [("a\"b", Some("c")), ("d", None), ("e", None)]);
        assert_eq!(attribute("a = 'v' b").0.eq, " = ");
    }
}
