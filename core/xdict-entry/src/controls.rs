//! Speaker controls (reading-style §5.2, §5.3): a link the core classifies as a sound is marked a speaker, with
//! XDict's glyph inserted first inside it, so the frame draws one control in the theme's colours. The dictionary's
//! own drawing stays in the bytes and the frame hides it: an image of a speaker is pixels the palette cannot reach
//! (CEPD's `uk_sound.png`, LDOCE-EC's `spkr_*.png` kept dark tails through every colour rule).

use crate::url::Link;

/// How far ahead a link's content is read. The read stops at the next link, so the reads of all links together
/// cover the entry at most once.
const CONTENT_BYTES: usize = 4096;
/// The most tags of a link's content read for an accent signal.
const SIGNAL_TAGS: usize = 64;
/// Tags that make a link's content more than a control: it is left alone.
const BLOCKS: [&str; 18] = [
    "div",
    "p",
    "li",
    "ul",
    "ol",
    "dl",
    "dt",
    "dd",
    "table",
    "tr",
    "td",
    "th",
    "h1",
    "h2",
    "h3",
    "h4",
    "section",
    "blockquote",
];
const UK: [&str; 8] = ["uk", "gb", "br", "bre", "brit", "british", "en_gb", "英"];
const US: [&str; 9] = ["us", "am", "ame", "name", "n_am", "nam", "american", "en_us", "美"];

#[derive(Default)]
pub(crate) struct Controls {
    pub(crate) inserts: Vec<(usize, String)>,
    /// Output ranges removed: the dictionary's private-use glyphs inside a speaker.
    pub(crate) removals: Vec<(usize, usize)>,
    pub(crate) speakers: u64,
    /// Where the content of the speaker last found ends, in the source; text before it is inside that speaker.
    inside_until: usize,
}

impl Controls {
    /// A start tag `<a …>` (`tag`, as written in the source), its attributes insertable at `attribute` and its
    /// content starting at `content`, (in the source, in the output); `after` is the source after the tag.
    pub(crate) fn link(
        &mut self,
        tag: &str,
        after: &str,
        attribute: usize,
        (source, content): (usize, usize),
        base: &str,
        dir: &str,
    ) {
        let Some(href) = crate::phon::attribute_of(tag, "href") else { return };
        if !matches!(crate::url::classify(href, base, dir), Link::Sound { .. } | Link::Speak { .. }) {
            return;
        }
        let Some(inner) = content_of(after) else { return };
        let Some(icon_only) = icon_only(inner) else { return };
        let mode = if icon_only { "replace" } else { "prefix" };
        let accent = accent(tag, inner, href);
        let mut marks = format!(" data-xdict-control=\"speaker\" data-xdict-control-mode=\"{mode}\"");
        let mut glyph = "<span data-xdict-icon=\"speaker\" aria-hidden=\"true\"></span>".to_owned();
        if let Some(accent) = accent {
            marks.push_str(&format!(" data-xdict-accent=\"{accent}\""));
            glyph.push_str("<span data-xdict-tag aria-hidden=\"true\"></span>");
        }
        self.inserts.push((attribute, marks));
        self.inserts.push((content, glyph));
        self.speakers += 1;
        self.inside_until = source + inner.len();
    }

    /// Whether `source` (a position in the source) is inside the speaker last found.
    pub(crate) fn inside(&self, source: usize) -> bool {
        source < self.inside_until
    }

    /// Text between tags, starting at `source` in the source and `written` in the output. Inside a speaker, each
    /// private-use character, raw or as a numeric reference, is the dictionary's icon-font glyph (COBUILD's `icomoon`
    /// U+EA27): XDict does not load that face, so it would draw a missing-glyph box beside XDict's own speaker. It is
    /// removed; an element left empty by it the frame hides.
    pub(crate) fn text(&mut self, text: &str, source: usize, written: usize) {
        if source >= self.inside_until {
            return;
        }
        let mut i = 0;
        while i < text.len() {
            let rest = text.get(i..).unwrap_or("");
            let Some(c) = rest.chars().next() else { break };
            let (len, glyph) = match reference(rest) {
                Some((len, c)) => (len, private_use(c)),
                None => (c.len_utf8(), private_use(c)),
            };
            if glyph {
                self.removals.push((written + i, written + i + len));
            }
            i += len;
        }
    }
}

/// Private use: the Basic Multilingual Plane's area and planes 15 and 16, where icon fonts put their glyphs.
fn private_use(c: char) -> bool {
    matches!(u32::from(c), 0xE000..=0xF8FF | 0xF0000..=0x10FFFD)
}

/// A numeric character reference at the start of `text` (`&#59943;`, `&#xEA27;`, the `;` optional as HTML reads
/// it): its length and character.
fn reference(text: &str) -> Option<(usize, char)> {
    let body = text.strip_prefix("&#")?;
    let (radix, digits_at) = if body.starts_with(['x', 'X']) { (16, 3) } else { (10, 2) };
    let digits = text.get(digits_at..)?;
    let n = digits.bytes().take_while(|b| (*b as char).is_digit(radix)).count();
    if n == 0 || n > 8 {
        return None;
    }
    let value = u32::from_str_radix(digits.get(..n)?, radix).ok()?;
    let semicolon = usize::from(digits.as_bytes().get(n) == Some(&b';'));
    Some((digits_at + n + semicolon, char::from_u32(value)?))
}

/// A link's content: up to the next `</a` or `<a` (HTML does not nest links), within the bound; `None` past it.
fn content_of(after: &str) -> Option<&str> {
    let bytes = after.as_bytes();
    let limit = bytes.len().min(CONTENT_BYTES);
    let mut i = 0;
    while i < limit {
        if bytes.get(i) == Some(&b'<') {
            let rest = bytes.get(i + 1..).unwrap_or(&[]);
            let rest = rest.strip_prefix(b"/").unwrap_or(rest);
            let is_a = rest.first().is_some_and(|b| b.eq_ignore_ascii_case(&b'a'))
                && rest.get(1).is_none_or(|b| b.is_ascii_whitespace() || matches!(b, b'>' | b'/'));
            if is_a {
                return after.get(..i);
            }
        }
        i += 1;
    }
    None
}

/// Whether a link's content is only an icon (images, empty elements, whitespace, private-use characters or a
/// speaker-like symbol); `None` when it holds a block, and the link is left alone.
fn icon_only(inner: &str) -> Option<bool> {
    let mut text = String::new();
    let mut rest = inner;
    while let Some(at) = rest.find('<') {
        text.push_str(rest.get(..at).unwrap_or(""));
        let from = rest.get(at + 1..).unwrap_or("");
        let close = from.find('>').map_or(from.len(), |e| e + 1);
        let name: String = from
            .trim_start_matches('/')
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        if BLOCKS.contains(&name.as_str()) {
            return None;
        }
        rest = from.get(close..).unwrap_or("");
    }
    text.push_str(rest);
    let text = crate::rewrite::unescaped_html(&text);
    Some(text.chars().all(|c| {
        c.is_whitespace() || private_use(c) || c == '\u{FE0F}' || matches!(c, '🔊' | '🔉' | '🔈' | '▶' | '►' | '♪')
    }))
}

/// The accent a speaker shows, from the first decisive signal (§5.3): its icon's file stem and classes, then
/// `title`/`alt`, then the sound file's name, then its folders. Conflicting signals at one level mean none.
fn accent(tag: &str, inner: &str, href: &str) -> Option<&'static str> {
    let mut icon = String::new();
    for source in std::iter::once(tag).chain(tags(inner)) {
        for name in ["class", "src"] {
            if let Some(v) = crate::phon::attribute_of(source, name) {
                let v = v.rsplit('/').next().unwrap_or(v);
                icon.push_str(v.split('.').next().unwrap_or(v));
                icon.push(' ');
            }
        }
        // A custom element named for its accent (OALECD's `<audio-gb>`).
        let name: String =
            source.trim_start_matches('<').chars().take_while(|c| !c.is_whitespace() && *c != '>').collect();
        if name.contains('-') {
            icon.push_str(&name);
            icon.push(' ');
        }
    }
    let mut titles = String::new();
    for source in std::iter::once(tag).chain(tags(inner)) {
        for name in ["title", "alt"] {
            if let Some(v) = crate::phon::attribute_of(source, name) {
                titles.push_str(v);
                titles.push(' ');
            }
        }
    }
    let path = href.split(['?', '#']).next().unwrap_or(href);
    let (folders, file) = path.rsplit_once('/').unwrap_or(("", path));
    let file = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
    let folders = folders.split_once("://").map_or(folders, |(_, f)| f);
    for level in [icon.as_str(), titles.as_str(), file, folders] {
        match told(level) {
            Told::One(a) => return Some(a),
            Told::Both => return None,
            Told::None => {}
        }
    }
    None
}

enum Told {
    None,
    One(&'static str),
    Both,
}

/// What one level's text says, split on anything but letters (and `_` kept for `en_gb`, `n_am`).
fn told(text: &str) -> Told {
    let lower = text.to_lowercase();
    let (mut uk, mut us) = (false, false);
    let words = lower.split(|c: char| !c.is_alphabetic());
    let joined = lower.split(|c: char| !(c.is_alphabetic() || c == '_'));
    for word in words.chain(joined) {
        uk |= UK.contains(&word);
        us |= US.contains(&word);
    }
    match (uk, us) {
        (true, false) => Told::One("uk"),
        (false, true) => Told::One("us"),
        (true, true) => Told::Both,
        (false, false) => Told::None,
    }
}

/// The start tags in `inner`, as written: each ends at its `>` or the next `<`, so they never overlap and reading
/// them all costs `inner`'s length once (a run of `<` without `>` cost its square when each ran to the end). At most
/// `SIGNAL_TAGS` are read.
fn tags(inner: &str) -> impl Iterator<Item = &str> {
    inner
        .match_indices('<')
        .filter_map(move |(at, _)| {
            let from = inner.get(at..)?;
            if !from.as_bytes().get(1).is_some_and(u8::is_ascii_alphabetic) {
                return None;
            }
            let body = from.get(1..)?;
            let end = body.find(['>', '<']).map_or(body.len(), |e| e + 1);
            from.get(..end + 1)
        })
        .take(SIGNAL_TAGS)
}
