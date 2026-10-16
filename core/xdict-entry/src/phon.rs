//! Marks an entry's phonetic transcriptions (ADR-0010, the orchestrator's addition of 2026-10-15), so every shell
//! can set them in one IPA font: the element whose text is a transcription gets `data-xdict-phon` and
//! `data-xdict-phon-system`, naming its delimiters (`slash`, `bracket`, `backslash`, `none`), or `font:<family>`
//! where the dictionary draws IPA through a phonetic font over ASCII ([`crate::KeptReason::Phonetic`]). The text
//! and its delimiters are never changed: they say which system the transcription is in.
//!
//! The scanner has no tree, so elements are followed on a stack of open tags: each collects its text (its
//! descendants' included) up to [`TEXT_CHARS`]; the outermost element whose text qualifies is marked, its
//! descendants' marks dropped. Marks are insertions recorded by output position and made in one pass at the end,
//! so the cost is linear in the entry.
//!
//! A transcription that is no element of its own (loose text among other content, as CALD's
//! `—vision … /ˈvɪʒ.<sup>ə</sup>n/`, or delimiters outside the element holding the letters, as OED's
//! `Brit.<a>sound</a>/<span>ˈdʌɪnə</span>/`) is found by its delimiters: each element scans its own text and
//! children for `/…/`, `[…]` or `\…\` holding a transcription, and wraps it whole in a `<span>` carrying the same
//! attributes. An element holding a delimited transcription is never marked whole as undelimited, so a label is never part of a mark.

use std::collections::{BTreeMap, BTreeSet};

use crate::normalize::{KeptReason, Style};

/// The most characters of text an element may hold and still be a transcription.
const TEXT_CHARS: usize = 160;
/// The deepest open element followed.
const MAX_DEPTH: usize = 256;
/// How far down the stack an end tag looks for its element.
const MATCH_DEPTH: usize = 32;
/// Elements that have no end tag.
const VOID: [&str; 14] =
    ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param"];

/// What an entry's marking found.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Transcriptions {
    /// Elements marked.
    pub marked: u64,
    /// How many use each system.
    pub systems: BTreeMap<String, u64>,
    /// Every non-ASCII character met inside a marked transcription.
    pub characters: BTreeSet<char>,
}

impl Transcriptions {
    pub fn add(&mut self, other: &Self) {
        self.marked += other.marked;
        for (k, v) in &other.systems {
            *self.systems.entry(k.clone()).or_default() += v;
        }
        self.characters.extend(other.characters.iter().copied());
    }
}

/// A mark waiting for its ancestors to decide: where it goes, its system, its text.
struct Mark {
    at: usize,
    /// Where a wrapping `<span>` ends; `None` when the mark is an element's own attributes.
    end: Option<usize>,
    system: String,
    text: String,
}

struct Open {
    name: String,
    at: usize,
    text: String,
    chars: usize,
    over: bool,
    /// Marked by its class, for a phonetic font: its text is not read.
    fixed: bool,
    pending: Vec<Mark>,
    /// A delimited transcription being read in this element's own content.
    scan: Option<Scan>,
    /// Whether it holds a delimited transcription: its own wrap, or a descendant's.
    delimited: bool,
}

/// An opening delimiter met in an element's content, and the text since it.
struct Scan {
    delimiter: char,
    at: usize,
    inner: String,
    chars: usize,
}

pub(crate) struct Marker {
    stack: Vec<Open>,
    /// Elements opened past [`MAX_DEPTH`].
    deep: usize,
    done: Vec<Mark>,
    /// Classes whose elements a kept phonetic font draws, and the font.
    fonts: Vec<(String, String)>,
    /// The entry's key, folded ([`folded`]): a headword stressed inside a word is not a transcription.
    key: Option<String>,
    pub(crate) found: Transcriptions,
}

impl Marker {
    pub(crate) fn new(style: &Style, key: Option<&str>) -> Self {
        let mut fonts = Vec::new();
        for kept in style.kept().iter().filter(|k| k.reason == KeptReason::Phonetic) {
            for selector in kept.selector.split(',') {
                let subject = selector.rsplit(|c: char| c.is_whitespace() || matches!(c, '>' | '+' | '~')).next();
                let class = subject
                    .and_then(|s| s.split('.').nth(1))
                    .map(|c| c.split([':', '[', '#']).next().unwrap_or("").to_ascii_lowercase());
                if let Some(class) = class.filter(|c| !c.is_empty()) {
                    fonts.push((class, kept.family.clone()));
                }
            }
        }
        let key = key.map(folded).filter(|k| !k.is_empty());
        Self { stack: Vec::new(), deep: 0, done: Vec::new(), fonts, key, found: Transcriptions::default() }
    }

    /// A start tag, written so that an attribute inserted at `at` follows its name; `tag` is its source.
    pub(crate) fn start(&mut self, name: &str, at: usize, tag: &str) {
        let lower = name.to_ascii_lowercase();
        if VOID.contains(&lower.as_str()) || tag.ends_with("/>") {
            // A line break or an image ends any transcription being read.
            if let Some(top) = self.stack.last_mut() {
                top.scan = None;
            }
            return;
        }
        if self.stack.len() >= MAX_DEPTH {
            self.deep += 1;
            return;
        }
        let font = (!self.fonts.is_empty())
            .then(|| class_of(tag))
            .flatten()
            .and_then(|classes| {
                self.fonts.iter().find(|(c, _)| classes.split_ascii_whitespace().any(|x| x.eq_ignore_ascii_case(c)))
            })
            .map(|(_, family)| family.clone());
        let fixed = font.is_some();
        if let Some(family) = font {
            self.commit(Mark { at, end: None, system: format!("font:{family}"), text: String::new() });
        }
        self.stack.push(Open {
            name: lower,
            at,
            text: String::new(),
            chars: 0,
            over: false,
            fixed,
            pending: Vec::new(),
            scan: None,
            delimited: false,
        });
    }

    /// Text between tags, as written, starting at output position `at`.
    pub(crate) fn text(&mut self, raw: &str, at: usize) {
        if raw.is_empty() {
            return;
        }
        let Some(top) = self.stack.last_mut() else { return };
        append(top, &crate::rewrite::unescaped_html(raw));
        let mut from = 0;
        while let Some(c) = raw.get(from..).and_then(|r| r.chars().next()) {
            let (c, len) = decoded(raw, from).unwrap_or((c, c.len_utf8()));
            step(top, c, at + from, at + from + len);
            from += len;
        }
    }

    /// An end tag: closes its element, and any left open inside it.
    pub(crate) fn end(&mut self, name: &str) {
        if self.deep > 0 {
            self.deep -= 1;
            return;
        }
        let lower = name.to_ascii_lowercase();
        let found = self.stack.iter().rev().take(MATCH_DEPTH).position(|o| o.name == lower);
        let Some(up) = found else { return };
        for _ in 0..=up {
            self.close();
        }
    }

    fn close(&mut self) {
        let Some(open) = self.stack.pop() else { return };
        // Undelimited text round a delimited transcription is a label beside it ("Brit./ˈdʌɪnə/"): the inner mark stands.
        let system = (!open.fixed && !open.over)
            .then(|| transcription(&open.text))
            .flatten()
            .filter(|s| !(open.delimited && *s == "none"))
            .filter(|s| !(*s == "none" && self.key.as_deref().is_some_and(|k| stressed_word(&open.text, k))));
        let delimited = open.delimited || system.is_some_and(|s| s != "none");
        let parent = self.stack.last_mut();
        if let Some(parent) = parent {
            parent.delimited |= delimited;
        }
        let parent = self.stack.last_mut();
        match system {
            Some(system) => {
                let mark = Mark { at: open.at, end: None, system: system.to_owned(), text: open.text.clone() };
                match parent {
                    Some(parent) => {
                        within(parent, &open);
                        append(parent, &open.text);
                        parent.pending.push(mark);
                    }
                    None => self.commit(mark),
                }
            }
            None => {
                if let Some(parent) = parent {
                    within(parent, &open);
                    if open.fixed || open.over {
                        parent.over = true;
                    } else {
                        append(parent, &open.text);
                    }
                }
                if !open.fixed {
                    match self.stack.last_mut() {
                        // Kept for the parent while it reads a delimited transcription that may wrap them.
                        Some(parent) if parent.scan.is_some() => parent.pending.extend(open.pending),
                        _ => {
                            for mark in open.pending {
                                self.commit(mark);
                            }
                        }
                    }
                }
            }
        }
    }

    fn commit(&mut self, mark: Mark) {
        self.done.push(mark);
    }

    /// The insertions to make, by output position: every element still open closed.
    /// `headwords`: the extents of the elements the core gives the headword role, inside which nothing undelimited
    /// is a transcription.
    pub(crate) fn finish(mut self, headwords: &[(usize, usize)]) -> (Vec<(usize, String)>, Transcriptions) {
        while !self.stack.is_empty() {
            self.close();
        }
        // Only an innermost headword: a block given the role as well (AHD's) holds the transcription beside it.
        // Sorted by start, longest first, a range holds another exactly when the next one starts before it ends.
        let mut spans = headwords.to_vec();
        spans.sort_unstable_by_key(|&(from, to)| (from, std::cmp::Reverse(to)));
        let merged: Vec<(usize, usize)> = spans
            .iter()
            .enumerate()
            .filter(|(i, (_, to))| spans.get(i + 1).is_none_or(|(next, _)| next >= to))
            .map(|(_, r)| *r)
            .collect();
        let in_headword = |at: usize| {
            let i = merged.partition_point(|(from, _)| *from <= at);
            i.checked_sub(1).and_then(|i| merged.get(i)).is_some_and(|(_, to)| at < *to)
        };
        self.done.retain(|m| !(m.end.is_none() && m.system == "none" && in_headword(m.at)));
        for m in &self.done {
            self.found.marked += 1;
            *self.found.systems.entry(m.system.clone()).or_default() += 1;
            self.found.characters.extend(m.text.chars().filter(|c| !c.is_ascii()));
        }
        // At one position a wrap's end goes before anything that starts there.
        let mut inserts: Vec<(usize, bool, String)> = Vec::with_capacity(self.done.len());
        for m in self.done {
            let attributes = format!(" data-xdict-phon data-xdict-phon-system=\"{}\"", attribute_text(&m.system));
            match m.end {
                None => inserts.push((m.at, true, attributes)),
                Some(end) => {
                    inserts.push((m.at, true, format!("<span{attributes}>")));
                    inserts.push((end, false, "</span>".to_owned()));
                }
            }
        }
        inserts.sort_by_key(|(at, starts, _)| (*at, *starts));
        (inserts.into_iter().map(|(at, _, text)| (at, text)).collect(), self.found)
    }
}

/// One character of an element's own text, at output bytes `at..end`: read into, closes or opens a delimited
/// transcription.
fn step(open: &mut Open, c: char, at: usize, end: usize) {
    if let Some(scan) = &mut open.scan {
        let closer = if scan.delimiter == '[' { ']' } else { scan.delimiter };
        if c == closer {
            let text = format!("{}{}{c}", scan.delimiter, scan.inner);
            if scan.inner.trim() == scan.inner
                && let Some(system) = transcription(&text).filter(|s| *s != "none")
            {
                let from = scan.at;
                // Marks inside it are dropped: the wrap is the outermost. Pending marks are in order of position.
                while open.pending.last().is_some_and(|m| m.at >= from) {
                    open.pending.pop();
                }
                open.pending.push(Mark { at: from, end: Some(end), system: system.to_owned(), text });
                open.scan = None;
                open.delimited = true;
                return;
            }
        } else if allowed(c) && c != '[' && scan.chars < TEXT_CHARS {
            scan.inner.push(c);
            scan.chars += 1;
            return;
        }
        open.scan = None;
    }
    if matches!(c, '/' | '[' | '\\') {
        open.scan = Some(Scan { delimiter: c, at, inner: String::new(), chars: 0 });
    }
}

/// A child element closed inside `parent`: its text joins a transcription being read, or ends it.
fn within(parent: &mut Open, child: &Open) {
    let Some(scan) = &mut parent.scan else { return };
    let n = child.text.chars().count();
    if child.fixed || child.over || !child.text.chars().all(allowed) || scan.chars + n > TEXT_CHARS {
        parent.scan = None;
        return;
    }
    scan.inner.push_str(&child.text);
    scan.chars += n;
}

/// The character an entity at `raw[from..]` stands for, and the entity's length; `None` if none starts there.
fn decoded(raw: &str, from: usize) -> Option<(char, usize)> {
    let rest = raw.get(from..)?;
    if !rest.starts_with('&') {
        return None;
    }
    let semi = rest.get(..rest.len().min(12))?.find(';')?;
    let entity = rest.get(..=semi)?;
    let text = crate::rewrite::unescaped_html(entity);
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if text != entity => Some((c, entity.len())),
        _ => None,
    }
}

/// Text as a key compares: stress marks and syllable dots gone, spaces collapsed, lower case.
fn folded(text: &str) -> String {
    let kept: String = text.chars().filter(|c| !matches!(c, 'ˈ' | 'ˌ' | '·' | '‧')).collect();
    kept.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Whether `text` is the key `key` (folded) with stress marked inside a word (`cataˈractical`), as a headword
/// is; a stress mark only before a word (`ˈpet`) is a transcription's as much as a headword's, so it is not enough.
fn stressed_word(text: &str, key: &str) -> bool {
    let inside =
        text.split_whitespace().any(|w| w.char_indices().any(|(i, c)| i > 0 && matches!(c, 'ˈ' | 'ˌ' | '·' | '‧')));
    inside && folded(text) == key
}

fn append(open: &mut Open, text: &str) {
    if open.over {
        return;
    }
    let n = text.chars().count();
    if open.chars + n > TEXT_CHARS {
        open.over = true;
        open.text = String::new();
        return;
    }
    open.chars += n;
    open.text.push_str(text);
}

/// A value safe inside `"…"`.
fn attribute_text(text: &str) -> String {
    text.replace('&', "&amp;").replace('"', "&quot;").replace('<', "&lt;")
}

/// A start tag's `class`, as written.
fn class_of(tag: &str) -> Option<&str> {
    attribute_of(tag, "class")
}

/// A start tag's attribute `name` (ASCII, lower case), its value as written; `None` without one.
pub(crate) fn attribute_of<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = lower.get(from..).and_then(|r| r.find(name)).map(|a| a + from) {
        from = at + name.len();
        let before = lower.as_bytes().get(at.wrapping_sub(1)).copied().unwrap_or(b' ');
        if !before.is_ascii_whitespace() {
            continue;
        }
        let rest = tag.get(from..)?.trim_start();
        let Some(value) = rest.strip_prefix('=') else { continue };
        let value = value.trim_start();
        return Some(match value.chars().next() {
            Some(q @ ('"' | '\'')) => {
                let body = value.get(1..)?;
                body.get(..body.find(q).unwrap_or(body.len()))?
            }
            _ => value.get(..value.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(value.len()))?,
        });
    }
    None
}

/// Whether a character is specific to phonetic transcription: IPA Extensions, spacing modifier letters (ˈ ˌ ː),
/// combining diacritics, the phonetic extensions, and the few Latin and Greek letters IPA takes (æ ð ŋ θ β χ).
fn ipa_specific(c: char) -> bool {
    matches!(u32::from(c), 0x0250..=0x036F | 0x1D00..=0x1DBF) || matches!(c, 'æ' | 'ð' | 'ŋ' | 'θ' | 'β' | 'χ')
}

/// Whether a character may stand in a transcription: a Latin or phonetic letter, a diacritic, a delimiter, a
/// separator or a space.
fn allowed(c: char) -> bool {
    let code = u32::from(c);
    (c.is_alphabetic() && (code <= 0x036F || matches!(code, 0x1D00..=0x1DBF | 0x1E00..=0x1EFF)))
        || ipa_specific(c)
        || c.is_whitespace()
        || matches!(
            c,
            '/' | '['
                | ']'
                | '\\'
                | '('
                | ')'
                | '.'
                | ','
                | ';'
                | '-'
                | '\''
                | '‿'
                | '|'
                | '‖'
                | '{'
                | '}'
                | '*'
                | '‐'
                | '\u{00a0}'
                | '·'
                | '→'
                | '↗'
                | '↘'
                | '↑'
                | '↓'
                | '͡'
                | '⁀'
                | '’'
                | 'ʼ'
                | 'ˑ'
        )
}

/// The delimiter system of a transcription, or `None` if the text is not one.
fn transcription(text: &str) -> Option<&'static str> {
    let t = text.trim();
    if !t.chars().any(ipa_specific)
        || !t.chars().any(|c| c.is_alphabetic() && !matches!(u32::from(c), 0x02B0..=0x02FF))
        || !t.chars().all(allowed)
    {
        return None;
    }
    let around = |open: char, close: char| t.starts_with(open) && t.ends_with(close) && t.chars().count() > 1;
    Some(if around('/', '/') {
        "slash"
    } else if around('[', ']') {
        "bracket"
    } else if around('\\', '\\') {
        "backslash"
    } else if t.split_whitespace().all(|w| w.chars().any(ipa_specific)) {
        // Undelimited, every word must be phonetic: "the schwa ə" is prose about a symbol.
        "none"
    } else {
        return None;
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcriptions_are_told_from_text() {
        assert_eq!(transcription("/ˈæp(ə)l/"), Some("slash"));
        assert_eq!(transcription("[ˈæpl̩]"), Some("bracket"));
        assert_eq!(transcription("\\ˈa-pəl\\"), Some("backslash"));
        assert_eq!(transcription("ˈæpəl"), Some("none"));
        for no in ["apple", "/apple/", "苹果 ə", "ˈ", "a ə 1", "see ə: «x»"] {
            assert_eq!(transcription(no), None, "{no}");
        }
    }

    /// AHD gives the headword role to the block holding the headword and its transcription as well as to the
    /// headword itself: only an innermost headword holds no transcription.
    #[test]
    fn only_the_innermost_headword_excludes() {
        let mark = |at| Mark { at, end: None, system: "none".into(), text: "ə".into() };
        let mut m = Marker::new(&Style::of_sheets([""]), None);
        m.done = vec![mark(30), mark(12)];
        // The block 0..100 holds the headword 10..20 and the transcription at 30.
        let (inserts, found) = m.finish(&[(0, 100), (10, 20)]);
        assert_eq!(inserts.iter().map(|(at, _)| *at).collect::<Vec<_>>(), [30]);
        assert_eq!(found.marked, 1);
    }

    #[test]
    fn a_class_is_read_from_its_tag() {
        assert_eq!(class_of("<span class=\"a phon\">"), Some("a phon"));
        assert_eq!(class_of("<span data-class=x class=b>"), Some("b"));
        assert_eq!(class_of("<span id=c>"), None);
    }
}
