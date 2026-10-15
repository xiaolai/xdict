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
}

pub(crate) struct Marker {
    stack: Vec<Open>,
    /// Elements opened past [`MAX_DEPTH`].
    deep: usize,
    done: Vec<Mark>,
    /// Classes whose elements a kept phonetic font draws, and the font.
    fonts: Vec<(String, String)>,
    pub(crate) found: Transcriptions,
}

impl Marker {
    pub(crate) fn new(style: &Style) -> Self {
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
        Self { stack: Vec::new(), deep: 0, done: Vec::new(), fonts, found: Transcriptions::default() }
    }

    /// A start tag, written so that an attribute inserted at `at` follows its name; `tag` is its source.
    pub(crate) fn start(&mut self, name: &str, at: usize, tag: &str) {
        let lower = name.to_ascii_lowercase();
        if VOID.contains(&lower.as_str()) || tag.ends_with("/>") {
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
            self.commit(Mark { at, system: format!("font:{family}"), text: String::new() });
        }
        self.stack.push(Open {
            name: lower,
            at,
            text: String::new(),
            chars: 0,
            over: false,
            fixed,
            pending: Vec::new(),
        });
    }

    /// Text between tags, as written.
    pub(crate) fn text(&mut self, raw: &str) {
        if raw.is_empty() {
            return;
        }
        if let Some(top) = self.stack.last_mut() {
            append(top, &crate::rewrite::unescaped_html(raw));
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
        let system = (!open.fixed && !open.over).then(|| transcription(&open.text)).flatten();
        let parent = self.stack.last_mut();
        match system {
            Some(system) => {
                let mark = Mark { at: open.at, system: system.to_owned(), text: open.text.clone() };
                match parent {
                    Some(parent) => {
                        append(parent, &open.text);
                        parent.pending.push(mark);
                    }
                    None => self.commit(mark),
                }
            }
            None => {
                if let Some(parent) = parent {
                    if open.fixed || open.over {
                        parent.over = true;
                    } else {
                        append(parent, &open.text);
                    }
                }
                if !open.fixed {
                    for mark in open.pending {
                        self.commit(mark);
                    }
                }
            }
        }
    }

    fn commit(&mut self, mark: Mark) {
        self.found.marked += 1;
        *self.found.systems.entry(mark.system.clone()).or_default() += 1;
        self.found.characters.extend(mark.text.chars().filter(|c| !c.is_ascii()));
        self.done.push(mark);
    }

    /// The insertions to make, by output position: every element still open closed.
    pub(crate) fn finish(mut self) -> (Vec<(usize, String)>, Transcriptions) {
        while !self.stack.is_empty() {
            self.close();
        }
        let mut inserts: Vec<(usize, String)> = self
            .done
            .into_iter()
            .map(|m| (m.at, format!(" data-xdict-phon data-xdict-phon-system=\"{}\"", attribute_text(&m.system))))
            .collect();
        inserts.sort_by_key(|(at, _)| *at);
        (inserts, self.found)
    }
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

    #[test]
    fn a_class_is_read_from_its_tag() {
        assert_eq!(class_of("<span class=\"a phon\">"), Some("a phon"));
        assert_eq!(class_of("<span data-class=x class=b>"), Some("b"));
        assert_eq!(class_of("<span id=c>"), None);
    }
}
