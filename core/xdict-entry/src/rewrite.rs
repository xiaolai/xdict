//! Every URL of an entry, and of the stylesheets and scripts it loads, rewritten under the view's base (ADR-0007
//! decisions 6, 8 and 14), so that each shell serves one space of URLs and nothing else loads.
//!
//! An entry is not parsed into a tree: a tag scanner finds attributes, `<script>` and `<style>`, and copies
//! everything else unchanged. Scripts are rewritten by prefix only (`entry://` and its kin), which is best effort
//! by construction: a URL a script builds from pieces (`'entry' + '://'`) is not seen, so each shell still
//! intercepts navigations.

use crate::url::{
    BLOCKED, Block, ENTRY, Link, Path, RESOURCE, SOUND, encode, is_oxford_lookup, is_remote_scheme, names_a_host,
    preprocess, scheme, tts,
};

/// A URL written in a dictionary, and what it means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Written {
    pub url: String,
    pub link: Link,
}

/// Rewritten text, and every URL that was met in it (not those a script builds).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Rewritten {
    pub text: String,
    pub links: Vec<Written>,
}

/// Rewritten text as it is written, and the URLs met, when the caller wants them: a view needs only the text,
/// and an entry of a million links would otherwise hold a million `Written`s it never reads.
struct Out {
    text: String,
    links: Option<Vec<Written>>,
}

impl Out {
    fn new(capacity: usize, collect: bool) -> Self {
        Self { text: String::with_capacity(capacity), links: collect.then(Vec::new) }
    }

    fn collects(&self) -> bool {
        self.links.is_some()
    }

    fn link(&mut self, url: impl Into<String>, link: Link) {
        if let Some(links) = &mut self.links {
            links.push(Written { url: url.into(), link });
        }
    }

    fn append(&mut self, other: Out) {
        self.text.push_str(&other.text);
        if let (Some(links), Some(more)) = (&mut self.links, other.links) {
            links.extend(more);
        }
    }

    fn done(self) -> Rewritten {
        Rewritten { text: self.text, links: self.links.unwrap_or_default() }
    }
}

/// What a literal URL becomes: its new text (`None`: kept as it is), and its meaning (`None`: not a link, as
/// `data:` is not).
fn literal(url: &str, base: &str, dir: &str) -> (Option<String>, Option<Link>) {
    let clean = preprocess(url);
    if clean.is_empty() {
        return (None, None);
    }
    if let Some(name) = clean.strip_prefix('#') {
        return (None, Some(Link::Anchor { name: name.to_owned() }));
    }
    if let Some((scheme, rest)) = scheme(&clean) {
        let body = rest.strip_prefix("//").unwrap_or(rest);
        return match scheme.as_str() {
            "entry" | "bword" => {
                let (query, anchor) = match body.split_once('#') {
                    Some((q, a)) => (q, Some(a)),
                    None => (body, None),
                };
                let mut to = format!("{base}{ENTRY}{}", encode(query));
                if let Some(a) = anchor {
                    to.push('#');
                    to.push_str(&encode(a));
                }
                (Some(to), Some(Link::Lookup { query: query.to_owned(), anchor: anchor.map(str::to_owned) }))
            }
            "sound" | "gdau" => match tts(body) {
                Some(text) => {
                    (Some(format!("{base}{SOUND}{}.tts", encode(text))), Some(Link::Speak { text: text.to_owned() }))
                }
                None => {
                    let path = Path::resolve("", body).travel();
                    (Some(format!("{base}{SOUND}{path}")), Some(Link::Sound { path }))
                }
            },
            s if is_oxford_lookup(s) => (
                Some(format!("{base}{ENTRY}{}", encode(rest))),
                Some(Link::Lookup { query: rest.to_owned(), anchor: None }),
            ),
            "file" | "mdd" => resource(body, base, ""),
            "javascript" => (None, Some(Link::Blocked(Block::Script))),
            "data" => (None, None),
            s if is_remote_scheme(s) => blocked(&clean, base),
            _ => (None, Some(Link::Blocked(Block::UnknownScheme { scheme }))),
        };
    }
    if names_a_host(&clean) {
        return blocked(&clean, base);
    }
    resource(&clean, base, dir)
}

fn resource(path: &str, base: &str, dir: &str) -> (Option<String>, Option<Link>) {
    let path = Path::resolve(dir, path).travel();
    (Some(format!("{base}{RESOURCE}{path}")), Some(Link::Resource { path }))
}

fn blocked(url: &str, base: &str) -> (Option<String>, Option<Link>) {
    (Some(format!("{base}{BLOCKED}{}", encode(url))), Some(Link::Blocked(Block::Remote { url: url.to_owned() })))
}

/// Attributes whose value is a URL, on any element.
const URL_ATTRIBUTES: [&str; 8] = ["src", "background", "poster", "data", "action", "formaction", "xlink:href", "cite"];
/// The elements whose `href` is a URL. Dictionaries put `href` on others as data for their scripts (OALD's
/// `<span class="topic" href="l2:people:feelings">`, `<span class="xr-g" href="pg_e">`): not links.
const HREF_ELEMENTS: [&str; 6] = ["a", "area", "link", "base", "image", "use"];

/// An entry's HTML, its URLs rewritten, and the URLs met. Inline styles and scripts are rewritten as stylesheets
/// and scripts are.
pub fn html(text: &str, base: &str) -> Rewritten {
    html_out(text, base, true).done()
}

/// An entry's HTML, its URLs rewritten, as a view shows it: [`html`] without the URLs met.
pub fn html_text(text: &str, base: &str) -> String {
    html_out(text, base, false).text
}

fn html_out(text: &str, base: &str, collect: bool) -> Out {
    let mut out = Out::new(text.len() + text.len() / 8, collect);
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        let (before, from) = rest.split_at(at);
        out.text.push_str(before);
        if let Some(comment) = from.strip_prefix("<!--") {
            // `<!-->` and `<!--->` close at once, as a browser reads them.
            let end = if comment.starts_with('>') {
                1
            } else if comment.starts_with("->") {
                2
            } else {
                comment.find("-->").map_or(comment.len(), |e| e + 3)
            };
            out.text.push_str("<!--");
            out.text.push_str(comment.get(..end).unwrap_or(comment));
            rest = comment.get(end..).unwrap_or("");
            continue;
        }
        match tag(from, base, &mut out) {
            Some((name, after)) => {
                rest = after;
                for (raw, script) in [("script", true), ("style", false)] {
                    if name.eq_ignore_ascii_case(raw) {
                        let close = find_ignore_case(rest, &format!("</{raw}")).unwrap_or(rest.len());
                        let (body, after) = rest.split_at(close);
                        if script {
                            out.text.push_str(&self::script(body, base).text);
                        } else {
                            let sheet = css_out(body, base, "", out.collects());
                            out.append(sheet);
                        }
                        rest = after;
                    }
                }
            }
            None => {
                out.text.push('<');
                rest = from.get(1..).unwrap_or("");
            }
        }
    }
    out.text.push_str(rest);
    out
}

/// One start tag at the start of `from`, written to `out` with its attributes rewritten: the tag's name and
/// what follows it. `None` if `from` does not start a tag (`a < b`, an end tag is copied as text).
fn tag<'a>(from: &'a str, base: &str, out: &mut Out) -> Option<(String, &'a str)> {
    let inner = from.strip_prefix('<')?;
    if inner.starts_with('/') {
        return None;
    }
    let name_len = inner.find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == ':')).unwrap_or(inner.len());
    if name_len == 0 || !inner.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    let name = inner.get(..name_len)?.to_owned();
    out.text.push('<');
    out.text.push_str(&name);
    let mut rest = inner.get(name_len..)?;
    loop {
        let spaces = rest.len() - rest.trim_start().len();
        out.text.push_str(rest.get(..spaces)?);
        rest = rest.get(spaces..)?;
        if rest.is_empty() {
            return Some((name, rest));
        }
        if let Some(after) = rest.strip_prefix('>') {
            out.text.push('>');
            return Some((name, after));
        }
        if let Some(after) = rest.strip_prefix('/') {
            out.text.push('/');
            rest = after;
            continue;
        }
        let attr_len = rest.find(|c: char| c.is_whitespace() || matches!(c, '=' | '>' | '/')).unwrap_or(rest.len());
        let attr = rest.get(..attr_len)?;
        out.text.push_str(attr);
        rest = rest.get(attr_len..)?;
        let before_eq = rest.len() - rest.trim_start().len();
        let Some(after_eq) = rest.trim_start().strip_prefix('=') else { continue };
        out.text.push_str(rest.get(..before_eq)?);
        out.text.push('=');
        let value_from = after_eq.trim_start();
        out.text.push_str(after_eq.get(..after_eq.len() - value_from.len())?);
        let (quote, value, after) = attribute_value(value_from)?;
        let new = attribute(&name, attr, value, quote, base, out);
        // Written as found unless it changed; a changed value is quoted.
        let q = if new == value { quote } else { Some(quote.unwrap_or('"')) };
        out.text.extend(q);
        out.text.push_str(&new);
        out.text.extend(q);
        rest = after;
    }
}

/// An attribute's value as HTML delimits it: its quote, the value as written, and what follows it.
fn attribute_value(from: &str) -> Option<(Option<char>, &str, &str)> {
    match from.chars().next() {
        Some(q @ ('"' | '\'')) => {
            let body = from.get(1..)?;
            let end = body.find(q).unwrap_or(body.len());
            Some((Some(q), body.get(..end)?, body.get(end + 1..).unwrap_or("")))
        }
        _ => {
            let end = from.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(from.len());
            Some((None, from.get(..end)?, from.get(end..)?))
        }
    }
}

/// An attribute's value, rewritten if it holds URLs. The value is written back as it was unless it changes; a
/// changed URL holds only characters that need no escaping, and changed text is escaped for `quote` (an unquoted
/// value is quoted with `"` when it changes).
fn attribute(element: &str, name: &str, value: &str, quote: Option<char>, base: &str, out: &mut Out) -> String {
    let lower = name.to_ascii_lowercase();
    let local = element.rsplit(':').next().unwrap_or(element).to_ascii_lowercase();
    if (lower == "srcset" && matches!(local.as_str(), "img" | "source")) || (lower == "imagesrcset" && local == "link")
    {
        let decoded = unescape(value);
        let rewritten = srcset(&decoded, base, out);
        return if rewritten == decoded { value.to_owned() } else { escaped(&rewritten, quote.unwrap_or('"')) };
    }
    let href = lower == "href" && HREF_ELEMENTS.contains(&local.as_str());
    if href || URL_ATTRIBUTES.contains(&lower.as_str()) {
        let url = unescape(value);
        let (to, link) = literal(&url, base, "");
        if let Some(link) = link {
            out.link(url, link);
        }
        return to.unwrap_or_else(|| value.to_owned());
    }
    match lower.as_str() {
        "style" => {
            let decoded = unescape(value);
            let Out { text, links } = css_out(&decoded, base, "", out.collects());
            if let (Some(all), Some(more)) = (&mut out.links, links) {
                all.extend(more);
            }
            if text == decoded { value.to_owned() } else { escaped(&text, quote.unwrap_or('"')) }
        }
        _ if lower.starts_with("on") => script(value, base).text,
        _ => value.to_owned(),
    }
}

/// `text` as an attribute value delimited by `quote`: `&` and the quote escaped.
fn escaped(text: &str, quote: char) -> String {
    let as_reference = if quote == '"' { "&quot;" } else { "&#39;" };
    text.replace('&', "&amp;").replace(quote, as_reference)
}

/// A `srcset`'s candidates (HTML's "parse a srcset attribute": a URL is a run of non-space, trailing commas end
/// it; a descriptor runs to the next comma), each URL rewritten, written back `url descriptor, …`.
fn srcset(value: &str, base: &str, out: &mut Out) -> String {
    let mut candidates = Vec::new();
    let mut rest = value;
    loop {
        rest = rest.trim_start_matches(|c: char| c.is_whitespace() || c == ',');
        if rest.is_empty() {
            break;
        }
        let url_end = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let (url, after) = rest.split_at(url_end);
        let (url, descriptor, after) = match url.strip_suffix(',') {
            Some(url) => (url.trim_end_matches(','), "", after),
            None => {
                let end = after.find(',').unwrap_or(after.len());
                let (descriptor, after) = after.split_at(end);
                (url, descriptor.trim(), after)
            }
        };
        rest = after;
        let (to, link) = literal(url, base, "");
        if let Some(link) = link {
            out.link(url, link);
        }
        let url = to.unwrap_or_else(|| url.to_owned());
        candidates.push(if descriptor.is_empty() { url } else { format!("{url} {descriptor}") });
    }
    candidates.join(", ")
}

/// The character references a URL in an attribute is likely to hold: HTML 4's named ones and numeric ones.
fn unescape(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(rest.get(..at).unwrap_or(""));
        let from = rest.get(at..).unwrap_or("");
        // The longest reference is ten bytes (`&#x10FFFF;`, `&thetasym;`): no search past it.
        let end = from.bytes().take(11).position(|b| b == b';');
        let decoded = end.and_then(|e| {
            let name = from.get(1..e)?;
            let c = match name.strip_prefix('#') {
                Some(n) => {
                    let code = match n.strip_prefix(['x', 'X']) {
                        Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                        None => n.parse().ok()?,
                    };
                    char::from_u32(code)?
                }
                None if name == "apos" => '\'',
                None => crate::entities::named(name)?,
            };
            Some((c, e + 1))
        });
        match decoded {
            Some((c, len)) => {
                out.push(c);
                rest = from.get(len..).unwrap_or("");
            }
            None => {
                out.push('&');
                rest = from.get(1..).unwrap_or("");
            }
        }
    }
    out.push_str(rest);
    out
}

/// A stylesheet's `url(…)` and `@import "…"` rewritten, and the URLs met; `dir` is the stylesheet's own directory.
pub fn css(text: &str, base: &str, dir: &str) -> Rewritten {
    css_out(text, base, dir, true).done()
}

/// A stylesheet rewritten, as a view loads it: [`css`] without the URLs met.
pub fn css_text(text: &str, base: &str, dir: &str) -> String {
    css_out(text, base, dir, false).text
}

fn css_out(text: &str, base: &str, dir: &str, collect: bool) -> Out {
    let mut out = Out::new(text.len(), collect);
    let bytes = text.as_bytes();
    // Read as CSS's tokeniser reads it (css-syntax §4), so that what is a URL here is what a browser fetches:
    // comments and strings are text, an escaped character is part of a name, `url(` is a function whose name
    // decodes to `url`, and an image function's strings are images. `copied` is how much of `text` is written.
    let (mut i, mut copied) = (0, 0);
    // For each open parenthesis, whether its function fetches its strings.
    let mut parens: Vec<bool> = Vec::new();
    // Since `@import`, until its next token: a string there is the imported sheet.
    let mut importing = false;
    while let Some(&b) = bytes.get(i) {
        match b {
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i = text.get(i + 2..).and_then(|r| r.find("*/")).map_or(text.len(), |e| i + 2 + e + 2);
            }
            b'"' | b'\'' => {
                let body = text.get(i + 1..).unwrap_or("");
                let end = string_end(body, char::from(b));
                let next = (i + 1 + end + 1).min(text.len());
                if importing || parens.last() == Some(&true) {
                    out.text.push_str(text.get(copied..i).unwrap_or(""));
                    write_url(&mut out, body.get(..end).unwrap_or(""), char::from(b), base, dir);
                    copied = next;
                }
                importing = false;
                i = next;
            }
            b'(' => {
                parens.push(false);
                importing = false;
                i += 1;
            }
            b')' => {
                parens.pop();
                importing = false;
                i += 1;
            }
            b'@' => {
                let (name, len) = name_at(text, i + 1);
                importing = name.eq_ignore_ascii_case("import");
                i += 1 + len;
            }
            _ if b.is_ascii_digit() || starts_name(text, i) => {
                importing = false;
                let (name, len) = name_at(text, i);
                let open = i + len.max(1);
                i = open;
                if b.is_ascii_digit() || bytes.get(open) != Some(&b'(') {
                    continue;
                }
                if !name.eq_ignore_ascii_case("url") {
                    parens.push(IMAGE_FUNCTIONS.iter().any(|f| name.eq_ignore_ascii_case(f)));
                    i = open + 1;
                    continue;
                }
                // `url(`: whitespace, then a string or an unquoted URL; its `)` is met as any other.
                parens.push(false);
                let inner = text.get(open + 1..).unwrap_or("");
                let value_from = inner.trim_start();
                let start = open + 1 + (inner.len() - value_from.len());
                out.text.push_str(text.get(copied..start).unwrap_or(""));
                match value_from.chars().next() {
                    Some(q @ ('"' | '\'')) => {
                        let body = value_from.get(1..).unwrap_or("");
                        let end = string_end(body, q);
                        write_url(&mut out, body.get(..end).unwrap_or(""), q, base, dir);
                        copied = (start + 1 + end + 1).min(text.len());
                    }
                    _ => {
                        // Unquoted, it runs to `)`; the spaces before it are dropped with the quotes added.
                        let end = string_end(value_from, ')');
                        write_url(&mut out, value_from.get(..end).unwrap_or("").trim_end(), '"', base, dir);
                        copied = start + end;
                    }
                }
                i = copied;
            }
            _ => {
                importing &= b.is_ascii_whitespace();
                i += 1;
            }
        }
    }
    out.text.push_str(text.get(copied..).unwrap_or(""));
    out
}

/// The functions whose string arguments a browser fetches as images (css-images-4).
const IMAGE_FUNCTIONS: [&str; 3] = ["image-set", "-webkit-image-set", "image"];

/// A URL a stylesheet wrote (`written`, its escapes undecoded), rewritten and written between `quote`s.
fn write_url(out: &mut Out, written: &str, quote: char, base: &str, dir: &str) {
    let value = css_unescape(written);
    let (to, link) = literal(&value, base, dir);
    if let Some(link) = link {
        out.link(value, link);
    }
    out.text.push(quote);
    out.text.push_str(to.as_deref().unwrap_or(written));
    out.text.push(quote);
}

/// Whether a CSS name starts at `at`: a letter, `_`, `-`, any non-ASCII character, or an escape.
fn starts_name(text: &str, at: usize) -> bool {
    let bytes = text.as_bytes();
    match bytes.get(at) {
        Some(b'\\') => bytes.get(at + 1).is_some_and(|&b| b != b'\n'),
        Some(&b) => b.is_ascii_alphabetic() || b == b'_' || b == b'-' || b >= 0x80,
        None => false,
    }
}

/// The name starting at `at`, decoded, and how many bytes it is written in: name characters (letters, digits,
/// `_`, `-`, non-ASCII) and escapes.
fn name_at(text: &str, at: usize) -> (String, usize) {
    let rest = text.get(at..).unwrap_or("");
    let mut chars = rest.char_indices().peekable();
    let mut len = 0;
    while let Some((i, c)) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some((_, '\n')) | None => break,
                Some((j, e)) if e.is_ascii_hexdigit() => {
                    let mut end = j + 1;
                    let mut digits = 1;
                    while digits < 6 && chars.peek().is_some_and(|(_, h)| h.is_ascii_hexdigit()) {
                        end += 1;
                        digits += 1;
                        chars.next();
                    }
                    if chars.peek().is_some_and(|(_, w)| w.is_ascii_whitespace()) {
                        end += 1;
                        chars.next();
                    }
                    len = end;
                }
                Some((j, e)) => len = j + e.len_utf8(),
            }
            continue;
        }
        if !(c.is_ascii_alphanumeric() || c == '_' || c == '-' || !c.is_ascii()) {
            break;
        }
        len = i + c.len_utf8();
    }
    (css_unescape(rest.get(..len).unwrap_or("")), len)
}

/// Where `close` ends `body`, a backslash escaping the character after it; the end of `body` if nothing does. A
/// quoted string also ends at an unescaped newline, as CSS tokenises a string left open.
fn string_end(body: &str, close: char) -> usize {
    let mut escaped = false;
    for (i, c) in body.char_indices() {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            '\n' if close != ')' => return i,
            _ if c == close => return i,
            _ => {}
        }
    }
    body.len()
}

/// CSS's escapes decoded: `\` and one to six hex digits (and one space after them) is that code point, `\`
/// before a newline is nothing, `\` before anything else is that character.
fn css_unescape(written: &str) -> String {
    if !written.contains('\\') {
        return written.to_owned();
    }
    let mut out = String::with_capacity(written.len());
    let mut chars = written.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let mut hex = String::new();
        while hex.len() < 6 && chars.peek().is_some_and(char::is_ascii_hexdigit) {
            hex.extend(chars.next());
        }
        if hex.is_empty() {
            match chars.next() {
                Some('\n') | None => {}
                Some(other) => out.push(other),
            }
            continue;
        }
        if chars.peek().is_some_and(|c| c.is_ascii_whitespace()) {
            chars.next();
        }
        let code = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32).unwrap_or('\u{fffd}');
        out.push(if code == '\0' { '\u{fffd}' } else { code });
    }
    out
}

/// A script's dictionary schemes rewritten to the view's routes, by prefix: `entry://` and `bword://` to
/// lookups, `sound://` and `gdau://` to sounds. What follows the prefix is left as the script builds it.
pub fn script(text: &str, base: &str) -> Rewritten {
    const PREFIXES: [(&str, &str); 4] =
        [("entry://", ENTRY), ("bword://", ENTRY), ("sound://", SOUND), ("gdau://", SOUND)];
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((at, which)) = first_of(rest, &PREFIXES.map(|(p, _)| p)) {
        let Some(&(prefix, route)) = PREFIXES.get(which) else { break };
        out.push_str(rest.get(..at).unwrap_or(""));
        out.push_str(base);
        out.push_str(route);
        rest = rest.get(at + prefix.len()..).unwrap_or("");
    }
    out.push_str(rest);
    Rewritten { text: out, links: Vec::new() }
}

fn find_ignore_case(haystack: &str, needle: &str) -> Option<usize> {
    first_of(haystack, &[needle]).map(|(at, _)| at)
}

/// The first place any of `needles` (ASCII, compared ignoring case) starts, and which one. One forward pass that
/// stops there, so a caller resuming after each match reads its text once in all.
fn first_of(haystack: &str, needles: &[&str]) -> Option<(usize, usize)> {
    let h = haystack.as_bytes();
    (0..h.len()).find_map(|i| {
        let tail = h.get(i..)?;
        needles
            .iter()
            .position(|n| tail.get(..n.len()).is_some_and(|w| !n.is_empty() && w.eq_ignore_ascii_case(n.as_bytes())))
            .map(|which| (i, which))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "xdict://d/";

    #[test]
    fn every_link_form_is_rewritten_under_the_base() {
        let entry = concat!(
            r#"<link rel="stylesheet" href="LDOCE6.css"><a href="entry://run#n1">run</a>"#,
            r#"<a href=bword://caf&#233;>x</a><img src='\img\a b.png'><a href="sound://run.mp3">play</a>"#,
            r##"<a href="sound://hello.tts">say</a><a href="https://example.com/x">out</a><a href="#top">top</a>"##,
            r#"<a href="javascript:void(0)">j</a><img src="data:image/png;base64,AAAA"><a href="file://f.css">f</a>"#,
        );
        let r = html(entry, BASE);
        for expected in [
            r#"href="xdict://d/r/LDOCE6.css""#,
            r#"href="xdict://d/entry/run#n1""#,
            r#"href="xdict://d/entry/caf%C3%A9""#,
            r#"src='xdict://d/r/img/a%20b.png'"#,
            r#"href="xdict://d/sound/run.mp3""#,
            r#"href="xdict://d/sound/hello.tts""#,
            r#"href="xdict://d/blocked/https%3A%2F%2Fexample.com%2Fx""#,
            r##"href="#top""##,
            r#"href="javascript:void(0)""#,
            r#"src="data:image/png;base64,AAAA""#,
            r#"href="xdict://d/r/f.css""#,
        ] {
            assert!(r.text.contains(expected), "{expected} not in {}", r.text);
        }
        assert_eq!(r.links.len(), 10, "{:?}", r.links);
        assert!(!r.links.iter().any(|w| matches!(w.link, Link::Blocked(Block::UnknownScheme { .. }))));
    }

    /// Text, comments, end tags and attributes that are not URLs pass through byte for byte; so does an `href`
    /// on an element that is not a link (OALD's spans).
    #[test]
    fn everything_else_is_untouched() {
        let text = concat!(
            r#"<p class="x" data-id=7>a < b &amp; c<!-- <a href="x"> --></p><br/><hr />"#,
            r#"<span class="topic" href="l2:people:feelings?cefr=c2">t</span><span class="xr-g" href="pg_e">"#,
        );
        let r = html(text, BASE);
        assert_eq!(r.text, text);
        assert!(r.links.is_empty(), "{:?}", r.links);
    }

    #[test]
    fn scripts_styles_and_handlers() {
        let entry = concat!(
            r#"<script>location.href='entry://'+t; var s = "SOUND://"+w+".tts";</script>"#,
            r#"<style>@import "a.css"; b { background: url( img/b.png ) }</style>"#,
            r#"<span onclick="location.href='entry://x'" style="background:url('c.png')">"#,
        );
        let r = html(entry, BASE);
        assert!(r.text.contains("location.href='xdict://d/entry/'+t"), "{}", r.text);
        assert!(r.text.contains(r#""xdict://d/sound/"+w"#), "{}", r.text);
        assert!(r.text.contains(r#"@import "xdict://d/r/a.css""#), "{}", r.text);
        assert!(r.text.contains(r#""xdict://d/r/img/b.png")"#), "{}", r.text);
        assert!(r.text.contains(r#"onclick="location.href='xdict://d/entry/x'""#), "{}", r.text);
        assert!(r.text.contains(r#"url('xdict://d/r/c.png')"#), "{}", r.text);
    }

    /// Oxford's lookups, on its namespaced `xhtml:a`, become the view's lookups.
    #[test]
    fn oxford_lookups() {
        let r =
            html(r#"<xhtml:a href="d:360-degree appraisal">x</xhtml:a><xhtml:a href="help:bre">BrE</xhtml:a>"#, BASE);
        assert!(r.text.contains(r#"href="xdict://d/entry/360-degree%20appraisal""#), "{}", r.text);
        assert!(r.text.contains(r#"href="help:bre""#), "{}", r.text);
    }

    /// Decision 7: a stylesheet's URLs resolve against its own directory.
    #[test]
    fn a_stylesheet_resolves_against_itself() {
        let r = css("@font-face { src: url(../fonts/a.woff2) }", BASE, "styles");
        assert!(r.text.contains(r#"url("xdict://d/r/fonts/a.woff2")"#), "{}", r.text);
    }

    /// A rewritten inline style stays inside its attribute, whatever quote the attribute uses.
    #[test]
    fn an_inline_style_is_escaped_for_its_attribute() {
        let r =
            html(r#"<b style="background:url(a.png)">x</b><i style='background:url(&quot;b.png&quot;)'>y</i>"#, BASE);
        assert!(r.text.contains(r#"style="background:url(&quot;xdict://d/r/a.png&quot;)""#), "{}", r.text);
        assert!(r.text.contains(r#"style='background:url("xdict://d/r/b.png")'"#), "{}", r.text);
        assert_eq!(r.links.len(), 2, "{:?}", r.links);
    }

    /// Every candidate of a `srcset` is a URL, its descriptor kept.
    #[test]
    fn srcset_candidates_are_rewritten() {
        let r = html(r#"<img srcset="a.png 1x, img/b.png 2x,c.png"><source srcset="d.png 480w">"#, BASE);
        assert!(
            r.text.contains(r#"srcset="xdict://d/r/a.png 1x, xdict://d/r/img/b.png 2x, xdict://d/r/c.png""#),
            "{}",
            r.text
        );
        assert!(r.text.contains(r#"srcset="xdict://d/r/d.png 480w""#), "{}", r.text);
        assert_eq!(r.links.len(), 4, "{:?}", r.links);
    }

    /// `url(` and `@import` inside a string or a comment are text, not URLs.
    #[test]
    fn css_strings_and_comments_are_left_alone() {
        let sheet =
            r#"a::after { content: "url(a.png)" } /* url(b.png) @import "c.css"; */ b { background: url(d.png) }"#;
        let r = css(sheet, BASE, "");
        assert!(r.text.contains(r#"content: "url(a.png)""#), "{}", r.text);
        assert!(r.text.contains(r#"/* url(b.png) @import "c.css"; */"#), "{}", r.text);
        assert!(r.text.contains(r#"url("xdict://d/r/d.png")"#), "{}", r.text);
        assert_eq!(r.links.len(), 1, "{:?}", r.links);
        let r = css("a { content: 'unclosed }\nb { background: url(e.png) }", BASE, "");
        assert_eq!(r.links.len(), 1, "a string ends at its line, as CSS tokenises it: {}", r.text);
    }

    /// Every way CSS can name a remote URL is blocked, read as CSS's tokeniser reads it: an escaped quote or
    /// slash starts no string or comment, an escaped `url` is still `url(`, and image functions fetch their strings.
    #[test]
    fn no_remote_url_hides_from_the_css_scanner() {
        let remote = "https://evil.example/x";
        for sheet in [
            format!(r#"a{{b:\"}} c{{background:url({remote})}} d{{e:"}}"#),
            format!(r#"a{{b:\/*}} c{{background:url({remote})}} d{{e:*/}}"#),
            format!(r#"b{{background:u\72 l({remote})}}"#),
            format!(r#"b{{background:\75rl("{remote}")}}"#),
            format!(r#"b{{background-image:image-set("{remote}" 1x, url(a.png) 2x)}}"#),
            format!(r#"b{{background-image:-webkit-image-set('{remote}' 1x)}}"#),
            format!(r#"@import "{remote}";"#),
            format!(r#"@im\70 ort '{remote}';"#),
        ] {
            let r = css(&sheet, BASE, "");
            assert!(!r.text.contains(remote), "{sheet} → {}", r.text);
            assert!(
                r.links.iter().any(|w| matches!(&w.link, Link::Blocked(Block::Remote { url }) if url == remote)),
                "{sheet}: {:?}",
                r.links
            );
        }
    }

    /// Only a function named `url` is a URL: `myurl(` is another function.
    #[test]
    fn only_the_url_function_is_a_url() {
        let r = css("b { x: myurl(a.png); y: url(b.png) }", BASE, "");
        assert!(r.text.contains("myurl(a.png)"), "{}", r.text);
        assert_eq!(r.links.len(), 1, "{:?}", r.links);
    }

    /// CSS escapes name the characters they stand for, and an escaped quote does not end a string.
    #[test]
    fn css_escapes_are_decoded() {
        let r = css(
            r#"a { background: url(foo\ bar.png) } b { background: url("q\"x.png") } c { background: url(\31 .png) }"#,
            BASE,
            "",
        );
        let paths: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
        assert_eq!(
            paths,
            ["foo bar.png", "q\"x.png", "1.png"].map(|p| Link::Resource { path: Path::resolve("", p).travel() }),
            "{}",
            r.text
        );
    }

    /// A preload's `imagesrcset` is a `srcset`.
    #[test]
    fn imagesrcset_is_a_srcset() {
        let r = html(r#"<link rel="preload" as="image" imagesrcset="https://evil.example/x 1x, a.png 2x">"#, BASE);
        assert!(!r.text.contains("https://evil.example"), "{}", r.text);
        assert_eq!(r.links.len(), 2, "{:?}", r.links);
    }

    /// HTML's named references are decoded as a browser decodes them, not only the five XML ones.
    #[test]
    fn named_references_are_decoded() {
        let r = html(r#"<a href="entry://caf&eacute;">x</a><a href="entry://a&nbsp;b">y</a>"#, BASE);
        let queries: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
        assert_eq!(queries, ["café", "a\u{a0}b"].map(|q| Link::Lookup { query: q.into(), anchor: None }), "{}", r.text);
    }

    /// A value of many `&` and no `;` decodes in one pass.
    #[test]
    fn many_ampersands_are_decoded_in_one_pass() {
        let started = std::time::Instant::now();
        let r = html(&format!(r#"<a href="entry://{}">x</a>"#, "&".repeat(1_000_000)), BASE);
        assert_eq!(r.links.len(), 1);
        // Searching each `&`'s whole rest is some 5·10¹¹ bytes here; one bounded pass, well under a second.
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "took {:?}", started.elapsed());
    }

    /// What a view gets is what the measured rewrite writes: only the URLs met are left out.
    #[test]
    fn the_text_alone_is_the_same_text() {
        let entry = concat!(
            r#"<link href="a.css"><a href="entry://run">r</a><img src='\img\b.png' style="background:url(c.png)">"#,
            r#"<style>@import "d.css"; b { background: url(e.png) }</style><span onclick="location='sound://x.mp3'">"#,
            r#"<a href="https://example.com/x">out</a>"#,
        );
        assert_eq!(html_text(entry, BASE), html(entry, BASE).text);
        assert_eq!(html(entry, BASE).links.len(), 7);
        let sheet = "@import url(x.css); b { background: url('../f.png') }";
        assert_eq!(css_text(sheet, BASE, "s"), css(sheet, BASE, "s").text);
        assert_eq!(css(sheet, BASE, "s").links.len(), 2);
    }

    /// `<!-->` and `<!--->` are whole comments to a browser (HTML's abrupt closing), so what follows them is
    /// markup and must be rewritten.
    #[test]
    fn an_abruptly_closed_comment_ends_where_a_browser_ends_it() {
        for open in ["<!-->", "<!--->"] {
            let r = html(&format!(r#"{open}<a href="https://example.com/x">out</a>-->"#), BASE);
            assert!(r.text.contains("xdict://d/blocked/"), "{open}: {}", r.text);
        }
        let r = html(r#"<!-- <a href="https://example.com/x"> -->"#, BASE);
        assert!(!r.text.contains("blocked"), "a comment's text is left alone: {}", r.text);
    }

    /// Each match is found once: searching the rest for every needle at every match made a large script or
    /// stylesheet quadratic, and a dictionary's resource can be 64 MiB.
    #[test]
    fn many_matches_are_rewritten_in_one_pass() {
        let n = 40_000;
        let started = std::time::Instant::now();
        let r = script(&"location='entry://a';".repeat(n), BASE);
        assert_eq!(r.text.matches("xdict://d/entry/a").count(), n);
        let r = css(&"b{background:url(a.png)}".repeat(n), BASE, "");
        assert_eq!(r.links.len(), n);
        // Quadratic, this ran over 600 s; linear, well under one. Ten leaves room for a loaded machine.
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "took {:?}", started.elapsed());
    }
}
