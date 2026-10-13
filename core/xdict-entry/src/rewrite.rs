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
        let (quote, value, after) = match value_from.chars().next() {
            Some(q @ ('"' | '\'')) => {
                let body = value_from.get(1..)?;
                let end = body.find(q).unwrap_or(body.len());
                (Some(q), body.get(..end)?, body.get(end + 1..).unwrap_or(""))
            }
            _ => {
                let end = value_from.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(value_from.len());
                (None, value_from.get(..end)?, value_from.get(end..)?)
            }
        };
        let new = attribute(&name, attr, value, base, out);
        // Written as found unless it changed; a changed value is quoted.
        let q = if new == value { quote } else { Some(quote.unwrap_or('"')) };
        out.text.extend(q);
        out.text.push_str(&new);
        out.text.extend(q);
        rest = after;
    }
}

/// An attribute's value, rewritten if it holds URLs. The value is written back as it was unless it changes; a
/// changed URL holds only characters that need no escaping.
fn attribute(element: &str, name: &str, value: &str, base: &str, out: &mut Out) -> String {
    let lower = name.to_ascii_lowercase();
    let local = element.rsplit(':').next().unwrap_or(element).to_ascii_lowercase();
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
            let Out { text, links } = css_out(value, base, "", out.collects());
            if let (Some(all), Some(more)) = (&mut out.links, links) {
                all.extend(more);
            }
            text
        }
        _ if lower.starts_with("on") => script(value, base).text,
        _ => value.to_owned(),
    }
}

/// The character references a URL in an attribute is likely to hold.
fn unescape(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(rest.get(..at).unwrap_or(""));
        let from = rest.get(at..).unwrap_or("");
        let end = from.find(';').filter(|&e| e <= 10);
        let decoded = end.and_then(|e| {
            let name = from.get(1..e)?;
            let c = match name {
                "amp" => '&',
                "lt" => '<',
                "gt" => '>',
                "quot" => '"',
                "apos" => '\'',
                _ => {
                    let n = name.strip_prefix('#')?;
                    let code = match n.strip_prefix(['x', 'X']) {
                        Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                        None => n.parse().ok()?,
                    };
                    char::from_u32(code)?
                }
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
    let mut rest = text;
    while let Some((at, which)) = first_of(rest, &["url(", "@import"]) {
        let is_url = which == 0;
        let skip = if is_url { 4 } else { 7 };
        out.text.push_str(rest.get(..at + skip).unwrap_or(""));
        let after = rest.get(at + skip..).unwrap_or("");
        let value_from = after.trim_start();
        out.text.push_str(after.get(..after.len() - value_from.len()).unwrap_or(""));
        let (quote, value, tail) = match value_from.chars().next() {
            Some(q @ ('"' | '\'')) => {
                let body = value_from.get(1..).unwrap_or("");
                let end = body.find(q).unwrap_or(body.len());
                (Some(q), body.get(..end).unwrap_or(""), body.get(end + 1..).unwrap_or(""))
            }
            // `@import url(…)` is met as `url(` next time round.
            _ if !is_url => {
                rest = value_from;
                continue;
            }
            _ => {
                let end = value_from.find(')').unwrap_or(value_from.len());
                (None, value_from.get(..end).unwrap_or("").trim_end(), value_from.get(end..).unwrap_or(""))
            }
        };
        let (to, link) = literal(value, base, dir);
        if let Some(link) = link {
            out.link(value, link);
        }
        let q = quote.unwrap_or('"');
        out.text.push(q);
        out.text.push_str(&to.unwrap_or_else(|| value.to_owned()));
        out.text.push(q);
        rest = tail;
    }
    out.text.push_str(rest);
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
        assert!(started.elapsed() < std::time::Duration::from_secs(1), "took {:?}", started.elapsed());
    }
}
