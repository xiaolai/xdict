//! The URLs an entry, and the stylesheets and scripts it loads, are seen to hold, rewritten under the view's base
//! (ADR-0007 decisions 6, 8 and 14), so that each shell serves one space of URLs.
//!
//! An entry is not parsed into a tree: a tag scanner finds attributes, `<script>` and `<style>`, and copies
//! everything else unchanged. Scripts are rewritten by prefix only (`entry://` and its kin), which is best effort by construction: a URL a
//! script builds from pieces (`'entry' + '://'`) is not seen, so each shell still intercepts navigations.
//!
//! This is compatibility, not the boundary: where a browser's parsing context differs from the scanner's (a
//! `<textarea>`, SVG, a `srcdoc` document) a URL can go unrewritten. That nothing else loads is the CSP's and the
//! shell's to ensure (ADR-0007 decision 14, corrected 2026-10-14).

use crate::Exceeded;
use crate::url::{
    BLOCKED, Block, ENTRY, Link, Path, RESOURCE, SOUND, encode, encoded_len, is_oxford_lookup, is_remote_scheme,
    names_a_host, preprocess, scheme, tts,
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
    text: Bounded,
    links: Option<Vec<Written>>,
}

/// Text written under a ceiling: a write that would pass `max` is not made and marks the text exceeded, so a
/// rewrite stops growing as soon as its result could not be served.
struct Bounded {
    text: String,
    max: usize,
    exceeded: bool,
}

impl Bounded {
    fn push_str(&mut self, s: &str) {
        if self.exceeded || self.text.len().saturating_add(s.len()) > self.max {
            self.exceeded = true;
        } else {
            self.text.push_str(s);
        }
    }

    fn push(&mut self, c: char) {
        self.push_str(c.encode_utf8(&mut [0; 4]));
    }

    fn extend(&mut self, c: Option<char>) {
        if let Some(c) = c {
            self.push(c);
        }
    }

    fn as_str(&self) -> &str {
        &self.text
    }
}

impl Out {
    /// Room for `capacity` bytes, no more than `max`; nothing is written past `max`.
    fn new(capacity: usize, collect: bool, max: usize) -> Self {
        let text = Bounded { text: String::with_capacity(capacity.min(max)), max, exceeded: false };
        Self { text, links: collect.then(Vec::new) }
    }

    /// The text, or `Exceeded` if it would have passed its ceiling.
    fn bounded(self) -> Result<String, Exceeded> {
        if self.text.exceeded { Err(Exceeded) } else { Ok(self.text.text) }
    }

    /// Marks this text exceeded when `other`, which it was made from, is.
    fn exceeded_with(&mut self, other: &Bounded) {
        self.text.exceeded |= other.exceeded;
    }

    /// The bytes still free under the ceiling: what a value rewritten on the way may grow to before it is
    /// written here, so that it is refused as soon as it could not fit rather than once it is whole.
    fn room(&self) -> usize {
        self.text.max.saturating_sub(self.text.text.len())
    }

    /// `value`, or nothing and this text exceeded when it would not fit.
    fn fitting(&mut self, value: Option<String>) -> String {
        value.unwrap_or_else(|| {
            self.text.exceeded = true;
            String::new()
        })
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
        self.text.push_str(other.text.as_str());
        self.exceeded_with(&other.text);
        if let (Some(links), Some(more)) = (&mut self.links, other.links) {
            links.extend(more);
        }
    }

    fn done(self) -> Rewritten {
        Rewritten { text: self.text.text, links: self.links.unwrap_or_default() }
    }
}

/// What a literal URL becomes: its new text (`None`: kept as it is), and its meaning (`None`: not a link, as
/// `data:` is not).
type Literal = (Option<String>, Option<Link>);

/// [`literal`] held to `room` bytes: a new text longer than that is refused before it is built, from its length
/// counted first (percent-encoding writes up to three bytes for one).
fn literal(url: &str, base: &str, dir: &str, room: usize) -> Result<Literal, Exceeded> {
    let clean = preprocess(url);
    if clean.is_empty() {
        return Ok((None, None));
    }
    if let Some(name) = clean.strip_prefix('#') {
        return Ok((None, Some(Link::Anchor { name: name.to_owned() })));
    }
    if let Some((scheme, rest)) = scheme(&clean) {
        let body = rest.strip_prefix("//").unwrap_or(rest);
        return Ok(match scheme.as_str() {
            "entry" | "bword" => {
                let (query, anchor) = match body.split_once('#') {
                    Some((q, a)) => (q, Some(a)),
                    None => (body, None),
                };
                let anchored = anchor.map_or(0, |a| 1 + encoded_len(a));
                weigh(room, [base.len(), ENTRY.len(), encoded_len(query), anchored])?;
                let mut to = format!("{base}{ENTRY}{}", encode(query));
                if let Some(a) = anchor {
                    to.push('#');
                    to.push_str(&encode(a));
                }
                (Some(to), Some(Link::Lookup { query: query.to_owned(), anchor: anchor.map(str::to_owned) }))
            }
            "sound" | "gdau" => match tts(body) {
                Some(text) => {
                    weigh(room, [base.len(), SOUND.len(), encoded_len(text), ".tts".len()])?;
                    (Some(format!("{base}{SOUND}{}.tts", encode(text))), Some(Link::Speak { text: text.to_owned() }))
                }
                None => {
                    let path = Path::resolve("", body);
                    weigh(room, [base.len(), SOUND.len(), path.travel_len(), 0])?;
                    let path = path.travel();
                    (Some(format!("{base}{SOUND}{path}")), Some(Link::Sound { path }))
                }
            },
            s if is_oxford_lookup(s) => {
                weigh(room, [base.len(), ENTRY.len(), encoded_len(rest), 0])?;
                (
                    Some(format!("{base}{ENTRY}{}", encode(rest))),
                    Some(Link::Lookup { query: rest.to_owned(), anchor: None }),
                )
            }
            "file" | "mdd" => resource(body, base, "", room)?,
            "javascript" => (None, Some(Link::Blocked(Block::Script))),
            "data" => (None, None),
            s if is_remote_scheme(s) => blocked(&clean, base, room)?,
            _ => (None, Some(Link::Blocked(Block::UnknownScheme { scheme }))),
        });
    }
    if names_a_host(&clean) {
        return blocked(&clean, base, room);
    }
    resource(&clean, base, dir, room)
}

/// `Exceeded` when `parts`, the lengths of what a new text is written from, add up to more than `room`.
fn weigh(room: usize, parts: [usize; 4]) -> Result<(), Exceeded> {
    if parts.into_iter().fold(0usize, usize::saturating_add) > room { Err(Exceeded) } else { Ok(()) }
}

fn resource(path: &str, base: &str, dir: &str, room: usize) -> Result<Literal, Exceeded> {
    let path = Path::resolve(dir, path);
    weigh(room, [base.len(), RESOURCE.len(), path.travel_len(), 0])?;
    let path = path.travel();
    Ok((Some(format!("{base}{RESOURCE}{path}")), Some(Link::Resource { path })))
}

fn blocked(url: &str, base: &str, room: usize) -> Result<Literal, Exceeded> {
    weigh(room, [base.len(), BLOCKED.len(), encoded_len(url), 0])?;
    Ok((Some(format!("{base}{BLOCKED}{}", encode(url))), Some(Link::Blocked(Block::Remote { url: url.to_owned() }))))
}

/// Attributes whose value is a URL, on any element.
const URL_ATTRIBUTES: [&str; 8] = ["src", "background", "poster", "data", "action", "formaction", "xlink:href", "cite"];
/// The elements whose `href` is a URL. Dictionaries put `href` on others as data for their scripts (OALD's
/// `<span class="topic" href="l2:people:feelings">`, `<span class="xr-g" href="pg_e">`): not links.
const HREF_ELEMENTS: [&str; 6] = ["a", "area", "link", "base", "image", "use"];

/// An entry's HTML, its URLs rewritten, and the URLs met. Inline styles and scripts are rewritten as stylesheets
/// and scripts are.
pub fn html(text: &str, base: &str) -> Rewritten {
    html_out(text, base, "", true, usize::MAX).done()
}

/// HTML as a view shows it: [`html`] without the URLs met. `dir` is the folder relative URLs resolve against: an
/// entry's is the package's root (`""`), a page served from the package its own folder.
pub fn html_text(text: &str, base: &str, dir: &str) -> String {
    html_out(text, base, dir, false, usize::MAX).text.text
}

/// [`html_text`] held to `max` bytes: `Exceeded` as soon as the text would pass it, before it is all written.
pub fn html_text_within(text: &str, base: &str, dir: &str, max: usize) -> Result<String, Exceeded> {
    html_out(text, base, dir, false, max).bounded()
}

fn html_out(text: &str, base: &str, dir: &str, collect: bool, max: usize) -> Out {
    let mut out = Out::new(text.len() + text.len() / 8, collect, max);
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        if out.text.exceeded {
            return out;
        }
        let (before, from) = rest.split_at(at);
        out.text.push_str(before);
        if let Some(comment) = from.strip_prefix("<!--") {
            // `<!-->` and `<!--->` close at once, as a browser reads them, and `--!>` closes as `-->` does
            // (HTML's comment end bang state).
            let end = if comment.starts_with('>') {
                1
            } else if comment.starts_with("->") {
                2
            } else {
                first_of(comment, &["-->", "--!>"])
                    .map_or(comment.len(), |(e, which)| e + if which == 0 { 3 } else { 4 })
            };
            out.text.push_str("<!--");
            out.text.push_str(comment.get(..end).unwrap_or(comment));
            rest = comment.get(end..).unwrap_or("");
            continue;
        }
        // `<?`, `<!` that opens no comment (a doctype among them) and `</` before anything but a letter are bogus
        // comments to a browser, which end at the first `>`.
        let bogus = from.strip_prefix("<?").or_else(|| from.strip_prefix("<!")).or_else(|| {
            from.strip_prefix("</").filter(|a| !a.is_empty() && !a.starts_with(|c: char| c.is_ascii_alphabetic()))
        });
        if let Some(body) = bogus {
            let whole = 2 + body.find('>').map_or(body.len(), |e| e + 1);
            out.text.push_str(from.get(..whole).unwrap_or(from));
            rest = from.get(whole..).unwrap_or("");
            continue;
        }
        let Some((name, after, end)) = tag(from, base, dir, &mut out) else {
            out.text.push('<');
            rest = from.get(1..).unwrap_or("");
            continue;
        };
        rest = after;
        // Only a script's and a style's text are read as raw text. A tag scanner cannot know the tree builder's
        // context, and taking `textarea`, `title`, `noscript` and the rest for raw text hides the markup after
        // them wherever a browser does not (in a template's column group, a frameset, inside `svg`); reading them
        // as markup rewrites text that may only be shown, which costs a view's text, not a URL.
        let script = name.eq_ignore_ascii_case("script");
        if end || !(script || name.eq_ignore_ascii_case("style")) {
            continue;
        }
        let (body, after) = rest.split_at(end_tag(rest, &name));
        rest = after;
        if script {
            let text = script_out(body, base, out.room()).ok();
            let text = out.fitting(text);
            out.text.push_str(&text);
        } else {
            let sheet = css_out(body, base, dir, out.collects(), out.room());
            out.append(sheet);
        }
    }
    out.text.push_str(rest);
    out
}

/// One tag at the start of `from`, written to `out`: the tag's name, what follows it, and whether it is an end
/// tag. A start tag's attributes are rewritten; an end tag's, which a browser ignores, are read only to find
/// where it ends. `None` if `from` does not start a tag (`a < b`).
fn tag<'a>(from: &'a str, base: &str, dir: &str, out: &mut Out) -> Option<(String, &'a str, bool)> {
    let inner = from.strip_prefix('<')?;
    let (end, inner) = match inner.strip_prefix('/') {
        Some(inner) => (true, inner),
        None => (false, inner),
    };
    // A name starts with a letter and runs to whitespace, `/` or `>` (HTML's tag open and tag name states):
    // `<script.foo>` names no script.
    let name_len = inner.find(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>').unwrap_or(inner.len());
    if name_len == 0 || !inner.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    let name = inner.get(..name_len)?.to_owned();
    out.text.push_str(if end { "</" } else { "<" });
    out.text.push_str(&name);
    let mut rest = inner.get(name_len..)?;
    loop {
        let spaces = rest.len() - rest.trim_ascii_start().len();
        out.text.push_str(rest.get(..spaces)?);
        rest = rest.get(spaces..)?;
        if rest.is_empty() {
            return Some((name, rest, end));
        }
        if let Some(after) = rest.strip_prefix('>') {
            out.text.push('>');
            return Some((name, after, end));
        }
        if let Some(after) = rest.strip_prefix('/') {
            out.text.push('/');
            rest = after;
            continue;
        }
        let attr_len =
            rest.find(|c: char| c.is_ascii_whitespace() || matches!(c, '=' | '>' | '/')).unwrap_or(rest.len());
        let attr = rest.get(..attr_len)?;
        out.text.push_str(attr);
        rest = rest.get(attr_len..)?;
        let before_eq = rest.len() - rest.trim_ascii_start().len();
        let Some(after_eq) = rest.trim_ascii_start().strip_prefix('=') else { continue };
        out.text.push_str(rest.get(..before_eq)?);
        out.text.push('=');
        let value_from = after_eq.trim_ascii_start();
        out.text.push_str(after_eq.get(..after_eq.len() - value_from.len())?);
        let (quote, value, after) = attribute_value(value_from)?;
        let new = if end { value.to_owned() } else { attribute(&name, attr, value, quote, base, dir, out) };
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
            let end = from.find(|c: char| c.is_ascii_whitespace() || c == '>').unwrap_or(from.len());
            Some((None, from.get(..end)?, from.get(end..)?))
        }
    }
}

/// An attribute's value, rewritten if it holds URLs. The value is written back as it was unless it changes; a
/// changed URL holds only characters that need no escaping, and changed text is escaped for `quote` (an unquoted
/// value is quoted with `"` when it changes).
fn attribute(
    element: &str,
    name: &str,
    value: &str,
    quote: Option<char>,
    base: &str,
    dir: &str,
    out: &mut Out,
) -> String {
    let lower = name.to_ascii_lowercase();
    let local = element.rsplit(':').next().unwrap_or(element).to_ascii_lowercase();
    if (lower == "srcset" && matches!(local.as_str(), "img" | "source")) || (lower == "imagesrcset" && local == "link")
    {
        let decoded = unescape(value);
        let rewritten = srcset(&decoded, base, dir, out);
        let rewritten = out.fitting(rewritten);
        return if rewritten == decoded { value.to_owned() } else { escaped_in(&rewritten, quote, out) };
    }
    let href = lower == "href" && HREF_ELEMENTS.contains(&local.as_str());
    if href || URL_ATTRIBUTES.contains(&lower.as_str()) {
        let url = unescape(value);
        let Ok((to, link)) = literal(&url, base, dir, out.room()) else { return out.fitting(None) };
        if let Some(link) = link {
            out.link(url, link);
        }
        return to.unwrap_or_else(|| value.to_owned());
    }
    match lower.as_str() {
        "style" => {
            let decoded = unescape(value);
            let Out { text, links } = css_out(&decoded, base, dir, out.collects(), out.room());
            out.exceeded_with(&text);
            if let (Some(all), Some(more)) = (&mut out.links, links) {
                all.extend(more);
            }
            if text.as_str() == decoded { value.to_owned() } else { escaped_in(text.as_str(), quote, out) }
        }
        // A handler runs as its value decodes; written back escaped for its quote, as a style is.
        _ if lower.starts_with("on") => {
            let decoded = unescape(value);
            let text = script_out(&decoded, base, out.room()).ok();
            let text = out.fitting(text);
            if text == decoded { value.to_owned() } else { escaped_in(&text, quote, out) }
        }
        _ => value.to_owned(),
    }
}

/// `text` as an attribute value delimited by `quote` (`"` for an unquoted value, which is quoted when it
/// changes), within the room `out` has left; nothing, and `out` exceeded, when it would not fit.
fn escaped_in(text: &str, quote: Option<char>, out: &mut Out) -> String {
    let escaped = escaped(text, quote.unwrap_or('"'), out.room());
    out.fitting(escaped)
}

/// `text` as an attribute value delimited by `quote`: `&` and the quote escaped; `None` when that is longer than
/// `max`, found by counting before anything is written.
fn escaped(text: &str, quote: char, max: usize) -> Option<String> {
    let as_reference = if quote == '"' { "&quot;" } else { "&#39;" };
    let grows = |c: char, by: usize| text.matches(c).count().saturating_mul(by);
    let len = text.len().saturating_add(grows('&', 4)).saturating_add(grows(quote, as_reference.len() - 1));
    (len <= max).then(|| text.replace('&', "&amp;").replace(quote, as_reference))
}

/// A `srcset`'s candidates (HTML's "parse a srcset attribute": a URL is a run of anything but ASCII whitespace,
/// trailing commas end it; a descriptor runs to the next comma), each URL rewritten, written back
/// `url descriptor, …`.
fn srcset(value: &str, base: &str, dir: &str, out: &mut Out) -> Option<String> {
    let max = out.room();
    let mut written = String::new();
    let mut rest = value;
    loop {
        rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == ',');
        if rest.is_empty() {
            break;
        }
        let url_end = rest.find(|c: char| c.is_ascii_whitespace()).unwrap_or(rest.len());
        let (url, after) = rest.split_at(url_end);
        let (url, descriptor, after) = match url.strip_suffix(',') {
            Some(url) => (url.trim_end_matches(','), "", after),
            None => {
                let end = after.find(',').unwrap_or(after.len());
                let (descriptor, after) = after.split_at(end);
                (url, descriptor.trim_ascii(), after)
            }
        };
        rest = after;
        let separator = if written.is_empty() { "" } else { ", " };
        let space = if descriptor.is_empty() { "" } else { " " };
        let around = separator.len() + space.len() + descriptor.len();
        let room = max.saturating_sub(written.len().saturating_add(around));
        let (to, link) = literal(url, base, dir, room).ok()?;
        if let Some(link) = link {
            out.link(url, link);
        }
        let url = to.as_deref().unwrap_or(url);
        let grows = around + url.len();
        if written.len().saturating_add(grows) > max {
            return None;
        }
        for part in [separator, url, space, descriptor] {
            written.push_str(part);
        }
    }
    Some(written)
}

/// An attribute value's character references decoded as HTML's tokeniser decodes them in an attribute (HTML
/// §13.2.5.72–80): numeric ones with or without `;`, every named one of the standard's table, the longest that
/// matches, and a name without `;` only where history allows it. What is no reference stays as written.
fn unescape(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(rest.get(..at).unwrap_or(""));
        let after = rest.get(at + 1..).unwrap_or("");
        match reference(after, &mut out) {
            Some(len) => rest = after.get(len..).unwrap_or(""),
            None => {
                out.push('&');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The reference `after` (what follows an `&`) starts with, written to `out`, and how many bytes of `after` it
/// takes; `None`, and nothing written, if it starts none. A name is searched for no further than the longest.
fn reference(after: &str, out: &mut String) -> Option<usize> {
    use crate::entities::{LONGEST, LONGEST_LEGACY, c1, named};
    let bytes = after.as_bytes();
    if bytes.first() == Some(&b'#') {
        let (radix, start) = if matches!(bytes.get(1), Some(b'x' | b'X')) { (16, 2) } else { (10, 1) };
        let digits = bytes.get(start..)?.iter().take_while(|b| char::from(**b).is_digit(radix)).count();
        if digits == 0 {
            return None;
        }
        // Too large is as wrong as any number past Unicode's last: both are U+FFFD.
        let code = after
            .get(start..start + digits)?
            .chars()
            .filter_map(|d| d.to_digit(radix))
            .fold(0u32, |n, d| n.saturating_mul(radix).saturating_add(d));
        let c = match code {
            0x80..=0x9f => c1(code).or_else(|| char::from_u32(code)),
            _ => char::from_u32(code).filter(|&c| c != '\0'),
        };
        out.push(c.unwrap_or('\u{fffd}'));
        return Some(start + digits + usize::from(bytes.get(start + digits) == Some(&b';')));
    }
    let run = bytes.iter().take(LONGEST).take_while(|b| b.is_ascii_alphanumeric()).count();
    if bytes.get(run) == Some(&b';')
        && let Some(text) = named(after.get(..=run)?)
    {
        out.push_str(text);
        return Some(run + 1);
    }
    // A name a browser still reads without `;`, the longest; in an attribute not before `=`, a letter or a digit.
    let len = (1..=run.min(LONGEST_LEGACY)).rev().find(|&n| after.get(..n).and_then(named).is_some())?;
    if bytes.get(len).is_some_and(|&b| b == b'=' || b.is_ascii_alphanumeric()) {
        return None;
    }
    out.push_str(named(after.get(..len)?)?);
    Some(len)
}

/// A stylesheet's `url(…)` and `@import "…"` rewritten, and the URLs met; `dir` is the stylesheet's own directory.
pub fn css(text: &str, base: &str, dir: &str) -> Rewritten {
    css_out(text, base, dir, true, usize::MAX).done()
}

/// A stylesheet rewritten, as a view loads it: [`css`] without the URLs met.
pub fn css_text(text: &str, base: &str, dir: &str) -> String {
    css_out(text, base, dir, false, usize::MAX).text.text
}

/// [`css_text`] held to `max` bytes: `Exceeded` as soon as the text would pass it, before it is all written.
pub fn css_text_within(text: &str, base: &str, dir: &str, max: usize) -> Result<String, Exceeded> {
    css_out(text, base, dir, false, max).bounded()
}

fn css_out(text: &str, base: &str, dir: &str, collect: bool, max: usize) -> Out {
    // Read as CSS's tokeniser reads it (css-syntax §4), so that what is a URL here is what a browser fetches:
    // comments and strings are text, an escaped character is part of a name, `url(` is a function whose name
    // decodes to `url`, and an image function's strings are images.
    let out = Out::new(text.len(), collect, max);
    let mut css = Css { text, base, dir, out, i: 0, copied: 0, parens: Vec::new() };
    let mut importing = false;
    while let Some(&b) = text.as_bytes().get(css.i) {
        if css.out.text.exceeded {
            return css.out;
        }
        importing = match b {
            b'/' if text.as_bytes().get(css.i + 1) == Some(&b'*') => {
                css.comment();
                importing
            }
            b'"' | b'\'' => {
                css.string(char::from(b), importing);
                false
            }
            b'(' | b')' => {
                css.paren(b == b'(');
                false
            }
            b'@' => css.at_keyword(),
            _ if b.is_ascii_digit() || starts_name(text, css.i) => {
                css.name(b.is_ascii_digit());
                false
            }
            _ => {
                css.i += 1;
                importing && b.is_ascii_whitespace()
            }
        };
    }
    css.out.text.push_str(text.get(css.copied..).unwrap_or(""));
    css.out
}

/// A stylesheet being rewritten: where it is read (`i`), how much of `text` is written to `out` (`copied`), and
/// for each open parenthesis whether its function fetches its strings.
struct Css<'a> {
    text: &'a str,
    base: &'a str,
    dir: &'a str,
    out: Out,
    i: usize,
    copied: usize,
    parens: Vec<bool>,
}

impl Css<'_> {
    /// A comment: text, read past its `*/`.
    fn comment(&mut self) {
        self.i = self.text.get(self.i + 2..).and_then(|r| r.find("*/")).map_or(self.text.len(), |e| self.i + 2 + e + 2);
    }

    /// A string: a URL just after `@import` (`importing`) or in an image function, text anywhere else.
    fn string(&mut self, quote: char, importing: bool) {
        let (body, next) = quoted(self.text, self.i, quote);
        if importing || self.parens.last() == Some(&true) {
            self.out.text.push_str(self.text.get(self.copied..self.i).unwrap_or(""));
            write_url(&mut self.out, body, quote, self.base, self.dir);
            self.copied = next;
        }
        self.i = next;
    }

    /// An opening parenthesis that is no function's, or a closing one.
    fn paren(&mut self, open: bool) {
        if open {
            self.parens.push(false);
        } else {
            self.parens.pop();
        }
        self.i += 1;
    }

    /// An at-keyword; whether it is `@import`, whose next token, if a string, is the imported sheet.
    fn at_keyword(&mut self) -> bool {
        let (name, len) = name_at(self.text, self.i + 1);
        self.i += 1 + len;
        name.eq_ignore_ascii_case("import")
    }

    /// A name, or a number: a name before `(` opens a function, and `url(` one whose argument is a URL.
    fn name(&mut self, number: bool) {
        let (name, len) = name_at(self.text, self.i);
        let open = self.i + len.max(1);
        self.i = open;
        if number || self.text.as_bytes().get(open) != Some(&b'(') {
            return;
        }
        if name.eq_ignore_ascii_case("url") {
            self.url(open);
        } else {
            self.parens.push(IMAGE_FUNCTIONS.iter().any(|f| name.eq_ignore_ascii_case(f)));
            self.i = open + 1;
        }
    }

    /// `url(`, its `(` at `open`: whitespace, then a string or an unquoted URL; its `)` is met as any other.
    fn url(&mut self, open: usize) {
        self.parens.push(false);
        let inner = self.text.get(open + 1..).unwrap_or("");
        let value_from = inner.trim_ascii_start();
        let start = open + 1 + (inner.len() - value_from.len());
        self.out.text.push_str(self.text.get(self.copied..start).unwrap_or(""));
        match value_from.chars().next() {
            Some(q @ ('"' | '\'')) => {
                let (body, next) = quoted(self.text, start, q);
                write_url(&mut self.out, body, q, self.base, self.dir);
                self.copied = next;
            }
            _ => {
                // Unquoted, it runs to `)`; the spaces before it are dropped with the quotes added.
                let end = string_end(value_from, ')');
                let written = value_from.get(..end).unwrap_or("").trim_ascii_end();
                write_url(&mut self.out, written, '"', self.base, self.dir);
                self.copied = start + end;
            }
        }
        self.i = self.copied;
    }
}

/// The CSS string whose opening `quote` is at `at` in `text`: its body as written, and where what follows it
/// starts (past its closing quote, or the end of `text` for a string left open).
fn quoted(text: &str, at: usize, quote: char) -> (&str, usize) {
    let body = text.get(at + 1..).unwrap_or("");
    let end = string_end(body, quote);
    (body.get(..end).unwrap_or(""), (at + 1 + end + 1).min(text.len()))
}

/// The functions whose string arguments a browser fetches as images (css-images-4).
const IMAGE_FUNCTIONS: [&str; 3] = ["image-set", "-webkit-image-set", "image"];

/// A URL a stylesheet wrote (`written`, its escapes undecoded), rewritten and written between `quote`s.
fn write_url(out: &mut Out, written: &str, quote: char, base: &str, dir: &str) {
    let value = css_unescape(written);
    let Ok((to, link)) = literal(&value, base, dir, out.room().saturating_sub(2)) else {
        out.text.exceeded = true;
        return;
    };
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
        Some(b'\\') => bytes.get(at + 1).is_some_and(|&b| !css_newline(char::from(b))),
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
                Some((_, n)) if css_newline(n) => break,
                None => break,
                Some((j, e)) if e.is_ascii_hexdigit() => {
                    let mut end = j + 1;
                    let mut digits = 1;
                    while digits < 6 && chars.peek().is_some_and(|(_, h)| h.is_ascii_hexdigit()) {
                        end += 1;
                        digits += 1;
                        chars.next();
                    }
                    if let Some((_, w)) = chars.next_if(|(_, w)| w.is_ascii_whitespace()) {
                        end += 1;
                        if w == '\r' && chars.next_if(|(_, l)| *l == '\n').is_some() {
                            end += 1;
                        }
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

/// Where `close` ends `body`, a backslash escaping the character after it (both of an escaped CRLF); the end of
/// `body` if nothing does. A quoted string also ends at an unescaped newline, as CSS tokenises a string left open.
fn string_end(body: &str, close: char) -> usize {
    let mut chars = body.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '\\' => {
                if chars.next().is_some_and(|(_, e)| e == '\r') {
                    chars.next_if(|(_, l)| *l == '\n');
                }
            }
            _ if css_newline(c) && close != ')' => return i,
            _ if c == close => return i,
            _ => {}
        }
    }
    body.len()
}

/// A newline as CSS reads one: LF, and the CR, CRLF and FF its preprocessing turns into LF (css-syntax §3.3).
fn css_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\x0c')
}

/// CSS's escapes decoded: `\` and one to six hex digits (and one space after them, a CRLF being one) is that
/// code point, `\` before a newline (LF, CR, CRLF or FF) is nothing, `\` before anything else is that character.
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
                Some('\r') => {
                    chars.next_if_eq(&'\n');
                }
                Some(n) if css_newline(n) => {}
                None => {}
                Some(other) => out.push(other),
            }
            continue;
        }
        if chars.next_if(char::is_ascii_whitespace) == Some('\r') {
            chars.next_if_eq(&'\n');
        }
        let code = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32).unwrap_or('\u{fffd}');
        out.push(if code == '\0' { '\u{fffd}' } else { code });
    }
    out
}

/// A script's dictionary schemes rewritten to the view's routes, by prefix: `entry://` and `bword://` to
/// lookups, `sound://` and `gdau://` to sounds. What follows the prefix is left as the script builds it.
pub fn script(text: &str, base: &str) -> Rewritten {
    let text = script_out(text, base, usize::MAX).unwrap_or_default();
    Rewritten { text, links: Vec::new() }
}

/// [`script`]'s text held to `max` bytes: `Exceeded` as soon as it would pass it, before it is all written. A
/// script grows by the view's route at every scheme it holds, so a small one can become a large one.
pub fn script_text_within(text: &str, base: &str, max: usize) -> Result<String, Exceeded> {
    script_out(text, base, max)
}

fn script_out(text: &str, base: &str, max: usize) -> Result<String, Exceeded> {
    const PREFIXES: [(&str, &str); 4] =
        [("entry://", ENTRY), ("bword://", ENTRY), ("sound://", SOUND), ("gdau://", SOUND)];
    let mut out = String::with_capacity(text.len().min(max));
    let push = |out: &mut String, part: &str| {
        if out.len().saturating_add(part.len()) > max {
            return Err(Exceeded);
        }
        out.push_str(part);
        Ok(())
    };
    let mut rest = text;
    while let Some((at, which)) = first_of(rest, &PREFIXES.map(|(p, _)| p)) {
        let Some(&(prefix, route)) = PREFIXES.get(which) else { break };
        push(&mut out, rest.get(..at).unwrap_or(""))?;
        push(&mut out, base)?;
        push(&mut out, route)?;
        rest = rest.get(at + prefix.len()..).unwrap_or("");
    }
    push(&mut out, rest)?;
    Ok(out)
}

/// Where the end tag of the raw text element `name` starts in `body`: `</name`, compared ignoring case, and then
/// whitespace, `/` or `>` (HTML's script data and RAWTEXT end tag name states); the end of `body` if none does.
/// `</scriptx>` and a `</script` with nothing after it end nothing.
fn end_tag(body: &str, name: &str) -> usize {
    let needle = format!("</{name}");
    let mut from = 0;
    while let Some(at) = body.get(from..).and_then(|rest| first_of(rest, &[&needle])).map(|(at, _)| from + at) {
        let after = body.as_bytes().get(at + needle.len());
        if after.is_some_and(|&b| b.is_ascii_whitespace() || b == b'/' || b == b'>') {
            return at;
        }
        from = at + needle.len();
    }
    body.len()
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

    /// HTML and CSS separate only on ASCII whitespace: a no-break space is part of the URL it stands in, in a
    /// `srcset`, an unquoted attribute value and an unquoted `url(`.
    #[test]
    fn only_ascii_whitespace_separates() {
        let resource = |p: &str| Link::Resource { path: Path::resolve("", p).travel() };
        let r = html("<img srcset=\"a\u{a0}b.png 1x, c.png\u{a0}2x\">", BASE);
        let paths: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
        assert_eq!(paths, [resource("a\u{a0}b.png"), resource("c.png\u{a0}2x")], "{}", r.text);
        let r = html("<img src=a\u{a0}b.png alt=x>", BASE);
        let paths: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
        assert_eq!(paths, [resource("a\u{a0}b.png")], "{}", r.text);
        let r = css("b { background: url(\u{a0}a.png\u{a0}) }", BASE, "");
        let paths: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
        assert_eq!(paths, [resource("\u{a0}a.png\u{a0}")], "{}", r.text);
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
            // CSS reads CR, FF and CRLF as newlines (css-syntax §3.3): each ends a string left open, an escaped
            // one continues it, and a CRLF after a hex escape is the one space the escape takes.
            format!("a{{b:\"x\r}} c{{background:url({remote})}}"),
            format!("a{{b:'x\x0c}} c{{background:url({remote})}}"),
            format!("a{{b:\"x\\\r\n\"}} c{{background:url({remote})}}"),
            format!("b{{background:u\\72\r\nl({remote})}}"),
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
        // An escaped newline is nothing, whichever of LF, CR, CRLF or FF it is.
        for newline in ["\n", "\r", "\r\n", "\x0c"] {
            let r = css(&format!("a {{ background: url(\"a\\{newline}b.png\") }}"), BASE, "");
            let paths: Vec<_> = r.links.iter().map(|w| w.link.clone()).collect();
            assert_eq!(paths, [Link::Resource { path: Path::resolve("", "ab.png").travel() }], "{newline:?}");
        }
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

    /// An attribute's references decode as HTML's tokeniser decodes them: every name of the standard's table,
    /// the longest that matches, a name without `;` only where history allows it (not before `=` or a letter or
    /// digit), and numbers with their replacements.
    #[test]
    fn references_decode_as_a_browser_decodes_them() {
        for (written, decoded) in [
            ("a&colon;b", "a:b"),
            ("&NotEqualTilde;", "\u{2242}\u{338}"),
            ("caf&eacute", "café"),
            ("&notit;", "&notit;"),
            ("&not.", "¬."),
            ("a?x=1&copy=2", "a?x=1&copy=2"),
            ("a&copy2", "a&copy2"),
            ("&amp;&AMP;&ampx", "&&&ampx"),
            ("a&#58b", "a:b"),
            ("&#150;", "\u{2013}"),
            ("&#x80;", "\u{20ac}"),
            ("a&#0;&#xD800;&#x110000;&#99999999999999999999;", "a\u{fffd}\u{fffd}\u{fffd}\u{fffd}"),
            ("&#;&#x;&#xg;", "&#;&#x;&#xg;"),
            ("&CounterClockwiseContourIntegral;", "\u{2233}"),
        ] {
            assert_eq!(unescape(written), decoded, "{written}");
        }
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
        assert_eq!(html_text(entry, BASE, ""), html(entry, BASE).text);
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

    /// A tag's name runs to whitespace, `/` or `>` (HTML's tag name state): `<script.foo>` is no script, so the
    /// markup after it is markup and is rewritten.
    #[test]
    fn a_tag_name_is_read_whole() {
        for open in ["<script.foo>", "<style.x>", "<script-x>", "<style:a>"] {
            let r = html(&format!("{open}<img src=https://example.com/a></script></style>"), BASE);
            assert!(r.text.contains("xdict://d/blocked/"), "{open}: {}", r.text);
        }
        let r = html("<SCRIPT\tsrc=x.js>location='https://example.com/'</SCRIPT>", BASE);
        assert!(r.text.contains("location='https://example.com/'"), "a script body is not HTML: {}", r.text);
    }

    /// `</scriptx>` ends no script and `</stylex>` no style: an end tag is its name and then whitespace, `/` or `>`
    /// (HTML's script data and RAWTEXT end tag name states), so the body runs on to the real end.
    #[test]
    fn only_the_whole_end_tag_ends_a_script_or_a_style() {
        let r = html("<script>var a='</scriptx>'; location='entry://run';</script>", BASE);
        assert!(r.text.contains("location='xdict://d/entry/run'"), "{}", r.text);
        let r = html("<style>a{}</stylex>b{background:url(https://example.com/a)}</style>", BASE);
        assert!(r.text.contains("xdict://d/blocked/"), "{}", r.text);
        for close in ["</script>", "</SCRIPT >", "</script/>", "</script\n>"] {
            let r = html(&format!("<script>x{close}<img src=https://example.com/a>"), BASE);
            assert!(r.text.contains("xdict://d/blocked/"), "{close}: {}", r.text);
        }
        // Without its delimiter at the very end, `</script` is the script's text, as it is to a browser.
        let r = html("<script>location='entry://a'</script", BASE);
        assert!(r.text.contains("xdict://d/entry/a"), "{}", r.text);
    }

    /// A tag scanner cannot know where a browser reads `textarea`, `title`, `xmp` or `noscript` as raw text: in a
    /// template's column group, a frameset, a select, or after a double-escaped script it does not, and the
    /// markup after them is live. So only scripts and styles are raw here (round-2 audit, Codex's inputs).
    #[test]
    fn only_scripts_and_styles_are_raw_text() {
        for input in [
            r#"<template><col><textarea></template><img src="https://example.com/x">"#,
            r#"<frameset><textarea><frame src="https://example.com/x">"#,
            r#"<script><!--<script></script><textarea></script><img src="https://example.com/x">"#,
            r#"<body><noscript><!--</noscript><textarea>--></noscript><img src="https://example.com/x">"#,
            r#"<svg></svg><!--<a title="--><img src="https://example.com/x">"#,
            r#"<select><xmp></select><img src="https://example.com/x">"#,
        ] {
            let r = html(input, BASE);
            assert!(!r.text.contains("\"https://example.com/x\""), "{input}: {}", r.text);
        }
    }

    /// `<?`, `<!` other than `<!--`, and `</` before anything but a letter open bogus comments, which end at the first
    /// `>`, and an end tag's attributes are read as a start tag's: a `<!--` inside any of them opens no comment, so
    /// what follows them is markup.
    #[test]
    fn only_a_real_comment_opens_one() {
        for open in ["<?x <!-- ?>", "<!x <!-- >", "</ <!-- >", "</a title=\"<!--\">", "<!DOCTYPE <!-- >"] {
            let r = html(&format!("{open}<img src=https://example.com/a>-->"), BASE);
            assert!(r.text.contains("xdict://d/blocked/"), "{open}: {}", r.text);
        }
        let kept = r#"<!DOCTYPE html><?xml version="1.0"?></p ><!-- <a href="https://example.com/x"> -->"#;
        assert_eq!(html(kept, BASE).text, kept);
    }

    /// An event handler runs as its value decodes (`&colon;` is `:`), so it is rewritten decoded and written back
    /// escaped for its quote.
    #[test]
    fn a_handler_is_rewritten_as_it_runs() {
        let r = html(r#"<a onclick="location='entry&colon;//run'">x</a>"#, BASE);
        assert!(r.text.contains(r#"onclick="location='xdict://d/entry/run'""#), "{}", r.text);
        let r = html(r#"<a onclick='go("entry://a&#39;s")'>x</a>"#, BASE);
        assert!(r.text.contains(r#"onclick='go("xdict://d/entry/a&#39;s")'"#), "{}", r.text);
        let kept = r#"<a onclick="f(&quot;x&quot;)">x</a>"#;
        assert_eq!(html(kept, BASE).text, kept, "an unchanged handler is written as found");
    }

    /// That `bounded` refuses, in under half the time `whole` takes on the same input on this machine: what a
    /// fixed duration cannot tell (a slow runner once took 530 ms for a 500 ms bound), a refusal that stops early
    /// against one that is written whole first can.
    fn stops_early(what: &str, whole: impl Fn() -> String, bounded: impl Fn() -> Result<String, crate::Exceeded>) {
        let started = std::time::Instant::now();
        let written = whole();
        let full = started.elapsed();
        assert!(!written.is_empty(), "{what}");
        let started = std::time::Instant::now();
        assert_eq!(bounded(), Err(crate::Exceeded), "{what}");
        let refused = started.elapsed();
        assert!(refused * 2 < full, "{what}: refused in {refused:?}, written whole in {full:?}");
    }

    /// Held to `max`, the rewrite stops as soon as its text would pass it; under it, it is the unbounded text.
    #[test]
    fn a_rewrite_past_its_ceiling_is_refused_early() {
        let entry = "<img src=a><a href='entry://b'>b</a><style>p{background:url(c.png)}</style>".repeat(200_000);
        stops_early("entry", || html_text(&entry, BASE, ""), || html_text_within(&entry, BASE, "", 1 << 20));
        let sheet = "p{background:url(c.png)}".repeat(200_000);
        assert_eq!(css_text_within(&sheet, BASE, "", 1 << 20), Err(crate::Exceeded));
        for text in [r#"<img src=a srcset="b 1x"><p style="background:url(c)">x</p><svg><style>a{}</style>"#, "plain"] {
            let whole = html_text(text, BASE, "d");
            assert_eq!(html_text_within(text, BASE, "d", whole.len()).as_deref(), Ok(whole.as_str()));
            assert_eq!(html_text_within(text, BASE, "d", whole.len() - 1), Err(crate::Exceeded));
        }
        let whole = css_text("a{background:url(x.png)}", BASE, "d");
        assert_eq!(css_text_within("a{background:url(x.png)}", BASE, "d", whole.len()).as_deref(), Ok(whole.as_str()));
        assert_eq!(css_text_within("a{background:url(x.png)}", BASE, "d", whole.len() - 1), Err(crate::Exceeded));
        // A script grows by the base at every scheme it holds: 7 bytes of `gdau://` become the whole route.
        let js = "gdau://".repeat(1 << 20);
        assert_eq!(script_text_within(&js, BASE, 1 << 20), Err(crate::Exceeded));
        let whole = script("a='entry://b'", BASE).text;
        assert_eq!(script_text_within("a='entry://b'", BASE, whole.len()).as_deref(), Ok(whole.as_str()));
        assert_eq!(script_text_within("a='entry://b'", BASE, whole.len() - 1), Err(crate::Exceeded));
    }

    /// What a page's rewrite builds on the way, an inline script, a handler, a `srcset` or a `style` value, is
    /// held to the room left under the ceiling, not rewritten whole first: a large one is refused as soon as it
    /// would not fit. Under the ceiling, each is written exactly as without one.
    #[test]
    fn a_value_rewritten_on_the_way_is_held_to_the_room_left() {
        let n = 4 << 20;
        let handler = format!("<a onclick=\"{}\">x</a>", "gdau://".repeat(n));
        let srcset = format!("<img srcset=\"{}\">", "a.png 1x, ".repeat(n / 2));
        for (what, page) in [("handler", &handler), ("srcset", &srcset)] {
            stops_early(what, || html_text(page, BASE, ""), || html_text_within(page, BASE, "", 1 << 10));
        }
        for page in [
            "<script>a='gdau://x';b='entry://y'</script><p>after</p>",
            r#"<a onclick="go('entry://b')&amp;x">b</a>"#,
            r#"<img srcset="a.png 1x, https://example.com/b.png 2x">"#,
            r#"<p style="background:url(c.png);content:'&amp;'">c</p>"#,
        ] {
            let whole = html_text(page, BASE, "d");
            assert_eq!(html_text_within(page, BASE, "d", whole.len()).as_deref(), Ok(whole.as_str()), "{page}");
            assert_eq!(html_text_within(page, BASE, "d", whole.len() - 1), Err(crate::Exceeded), "{page}");
        }
    }

    /// A rewritten URL is weighed before it is built: one that percent-encodes to three times its length (a
    /// blocked remote URL, a lookup) is refused as soon as it could not fit, whether it stands in a `srcset`, an
    /// attribute or a stylesheet, rather than once it is whole. Under the ceiling each is written as without one.
    /// What weighing saves is memory, not time: scanning the input takes as long either way, so this test asserts
    /// no duration (a 500 ms bound once failed on a slow runner without telling the two apart). The saving was
    /// measured with `XDICT_WEIGHED_URL_BYTES` = 32 MiB under `/usr/bin/time -l`: a 475 MB peak before, 240 after.
    #[test]
    fn a_url_is_weighed_before_it_is_built() -> Result<(), std::num::ParseIntError> {
        // `XDICT_WEIGHED_URL_BYTES` sets the URL's size, for measuring the peak under `/usr/bin/time -l`.
        let bytes: usize = std::env::var("XDICT_WEIGHED_URL_BYTES").map_or(Ok(4 << 20), |v| v.parse())?;
        let bang = "!".repeat(bytes);
        let pages = [
            ("srcset", format!("<img srcset=\"https://e.example/{bang} 1x\">")),
            ("href", format!("<a href=\"https://e.example/{bang}\">x</a>")),
            ("lookup", format!("<a href=\"entry://{bang}\">x</a>")),
            ("style", format!("<p style=\"background:url(https://e.example/{bang})\">x</p>")),
        ];
        for (what, page) in &pages {
            assert_eq!(html_text_within(page, BASE, "", 1 << 10), Err(crate::Exceeded), "{what}");
        }
        let sheet = format!("a{{background:url(https://e.example/{bang})}}");
        assert_eq!(css_text_within(&sheet, BASE, "", 1 << 10), Err(crate::Exceeded));
        for page in [
            r#"<img srcset="https://e.example/a!b 1x, c.png 2x">"#,
            r#"<a href="entry://a b#c d">x</a><a href="sound://s.mp3">s</a><a href="gdau://say:hi">t</a>"#,
            r#"<a href="https://e.example/x y">x</a><img src="../i/a b.png">"#,
            r#"<p style="background:url('https://e.example/q r')">x</p>"#,
        ] {
            let whole = html_text(page, BASE, "d");
            assert_eq!(html_text_within(page, BASE, "d", whole.len()).as_deref(), Ok(whole.as_str()), "{page}");
            assert_eq!(html_text_within(page, BASE, "d", whole.len() - 1), Err(crate::Exceeded), "{page}");
        }
        let sheet = "a{background:url(https://e.example/q r.png)}b{background:url('../c d.png')}";
        let whole = css_text(sheet, BASE, "d");
        assert_eq!(css_text_within(sheet, BASE, "d", whole.len()).as_deref(), Ok(whole.as_str()));
        assert_eq!(css_text_within(sheet, BASE, "d", whole.len() - 1), Err(crate::Exceeded));
        Ok(())
    }

    /// `--!>` ends a comment as `-->` does (HTML's comment end bang state), so what follows it is markup.
    #[test]
    fn a_comment_closed_by_a_bang_ends_where_a_browser_ends_it() {
        let r = html("<!--x--!><img src=https://example.com/a>", BASE);
        assert!(r.text.contains("xdict://d/blocked/"), "{}", r.text);
        let r = html("<!--x--!-><img src=https://example.com/a>-->", BASE);
        assert!(!r.text.contains("blocked"), "`--!-` does not end it: {}", r.text);
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
