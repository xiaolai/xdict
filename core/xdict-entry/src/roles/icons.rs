//! The icon sweep's rules on the entry's tree (`dev-docs/measurements/2026-10-15-icon-sweep/` §7, the owner's answers
//! in ADR-0010), generic: an element's own classes, `type`, `title`, handler and image file stem, its nearest
//! ancestors, and what the edition's sheet draws on it. No dictionary is named here.
//!
//! - Meaning drawn as a graphic (§7.4: a CEFR or word-list badge, frequency dots or a band, a "new" image) becomes
//!   XDict's text label, inserted where the graphic was; the graphic is kept, hidden, so a script's hook survives.
//!   A link that held only the graphic is unwrapped; a link that was the graphic is replaced.
//! - A symbol a sheet draws (§7.1) becomes XDict's marker or `lookup` mark, or is dropped, by role; one written as
//!   text stays, except a sense number drawn as a symbol (a plain number), a speaker's glyph left inside a speaker
//!   and a fold head's triangle (XDict's control draws both).
//! - A fold control (§7.3) is marked `disclosure`, its classes, id and handler kept.
//! - A link left with nothing in it that goes nowhere XDict can follow (OED's quotation popups) goes.
//!
//! Each pass reads every element once, and an element's ancestors at most [`ANCESTOR_DEPTH`] up.

use std::collections::BTreeMap;

use super::{Decided, Kid, Lk, Node, Role, Tree};
use crate::facts::{ANCESTOR_DEPTH, Facts};
use crate::symbols::{self, Ctx, Treatment};

/// The longest attribute value kept for the rules.
const VALUE_CHARS: usize = 160;
/// The most symbols written as text recorded in one entry.
const MAX_WRITTEN: usize = 1 << 16;
/// How many ancestors a control's tokens are read from (§7.4).
const CONTROL_ANCESTORS: usize = 3;

/// What the icon rules read of one element, kept as it is built: boxed, and only when the element has any of it
/// (`Detail`), since an entry holds up to `MAX_NODES`. What every element inherits is [`Inherited`].
#[derive(Debug, Clone, Default)]
pub(super) struct Attrs {
    detail: Option<Box<Detail>>,
}

/// What the icon rules read that an element inherits: two bytes, held in the element itself.
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct Inherited {
    /// Inside a speaker: a sound link, or itself one.
    pub(super) in_speaker: bool,
    /// The nearest link it is in, itself included.
    pub(super) link: Option<Lk>,
}

/// What the icon rules read of an element that has any of it; read through `Attrs`, empty when it has none.
#[derive(Debug, Clone, Default)]
pub(super) struct Detail {
    classes: Box<[String]>,
    title: Box<str>,
    alt: Box<str>,
    kind: Box<str>,
    /// The image's file stem, lower case.
    stem: Box<str>,
    /// Its first handler's code.
    handler: Box<str>,
    /// The symbols its `::before` and `::after` draw, with the drawing rule's selector.
    before: Option<(char, Box<str>)>,
    after: Option<(char, Box<str>)>,
    /// A recording its handler names by key (`'a/a__/a__gb/a__gb_2'`).
    pub(super) keyed: Option<Box<str>>,
}

/// The detail of an element that has none.
static EMPTY: std::sync::OnceLock<Detail> = std::sync::OnceLock::new();

impl Detail {
    fn is_empty(&self) -> bool {
        self.classes.is_empty()
            && self.title.is_empty()
            && self.alt.is_empty()
            && self.kind.is_empty()
            && self.stem.is_empty()
            && self.handler.is_empty()
            && self.before.is_none()
            && self.after.is_none()
            && self.keyed.is_none()
    }
}

impl std::ops::Deref for Attrs {
    type Target = Detail;

    fn deref(&self) -> &Detail {
        self.detail.as_deref().unwrap_or_else(|| EMPTY.get_or_init(Detail::default))
    }
}

fn bounded(v: &str) -> Box<str> {
    v.chars().take(VALUE_CHARS).collect::<String>().into_boxed_str()
}

impl Attrs {
    pub(super) fn of(
        tag: &str,
        attrs: &[(String, String)],
        classes: &[String],
        link: Lk,
        facts: &Facts,
        nodes: &[Node],
        stack: &[u32],
    ) -> (Self, Inherited) {
        let get = |n: &str| attrs.iter().find(|(k, _)| k == n).map_or("", |(_, v)| v.as_str());
        let parent = stack.last().and_then(|&p| nodes.get(p as usize)).map(|p| p.inherit);
        let handler = attrs.iter().find(|(k, _)| k.starts_with("on")).map_or("", |(_, v)| v.as_str());
        let src = get("src");
        let file = src.rsplit(['/', '\\']).next().unwrap_or("");
        let stem = file.rsplit_once('.').map_or(file, |(s, _)| s).to_ascii_lowercase();
        let mut out = Detail {
            classes: classes.into(),
            title: bounded(get("title")),
            alt: bounded(get("alt")),
            kind: bounded(&get("type").to_ascii_lowercase()),
            stem: bounded(&stem),
            handler: bounded(handler),
            before: None,
            after: None,
            keyed: keyed(handler).map(String::into_boxed_str),
        };
        let ancestors: Vec<&Node> =
            stack.iter().rev().take(ANCESTOR_DEPTH).filter_map(|&a| nodes.get(a as usize)).collect();
        for g in facts.glyphs(tag, classes) {
            let held = g.ancestors.iter().all(|c| ancestors.iter().any(|a| c.matches(&a.name, &a.icon.classes)));
            if held {
                let drawn = Some((g.ch, Box::from(g.selector.as_str())));
                if g.after {
                    out.after = drawn;
                } else {
                    out.before = drawn;
                }
            }
        }
        let inherit = Inherited {
            in_speaker: link == Lk::Sound || parent.is_some_and(|p| p.in_speaker),
            link: if link == Lk::None { parent.and_then(|p| p.link) } else { Some(link) },
        };
        (Attrs { detail: if out.is_empty() { None } else { Some(Box::new(out)) } }, inherit)
    }
}

/// A recording a handler names by an MDict-style key: a quoted path whose last part holds `_gb_1`, `_us_2`, `_uk_1`.
pub(super) fn keyed(handler: &str) -> Option<String> {
    handler
        .split(['\'', '"'])
        .skip(1)
        .step_by(2)
        .find(|q| {
            let last = q.rsplit('/').next().unwrap_or(q).to_ascii_lowercase();
            ["_gb_", "_us_", "_uk_"].iter().any(|a| {
                last.match_indices(a).any(|(at, m)| last.as_bytes().get(at + m.len()).is_some_and(u8::is_ascii_digit))
            }) && q.chars().all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '/' | '.'))
        })
        .map(str::to_owned)
}

/// The files a package might hold a keyed recording as, by its path as it travels: the key, its last part, each
/// with `__` read as `_`, as `.mp3` at the root or under `mp3/`.
pub(super) fn keyed_files(key: &str) -> impl Iterator<Item = String> + '_ {
    let last = key.rsplit('/').next().unwrap_or(key);
    let names = [last.to_owned(), last.replace("__", "_"), key.to_owned()];
    names.into_iter().flat_map(|n| {
        ["", "mp3/"].into_iter().map(move |dir| crate::url::Path::resolve("", &format!("{dir}{n}.mp3")).travel())
    })
}

/// The accent a key names.
pub(super) fn keyed_accent(key: &str) -> Option<&'static str> {
    let last = key.rsplit('/').next().unwrap_or(key).to_ascii_lowercase();
    if last.contains("_gb_") || last.contains("_uk_") {
        Some("uk")
    } else if last.contains("_us_") {
        Some("us")
    } else {
        None
    }
}

/// A symbol written as text: the element it is in, where it is written, its length and character, and whether it
/// leads the element's text.
#[derive(Debug, Clone, Copy)]
pub(super) struct Written {
    node: u32,
    at: usize,
    len: usize,
    ch: char,
    lead: bool,
}

/// Records the symbols in a text the rules may change, written at `at` in element `node`; `first`: no text came
/// before it in the element.
pub(super) fn written(raw: &str, at: usize, node: u32, first: bool, out: &mut Vec<Written>) {
    let lead_at = raw.find(|c: char| !c.is_whitespace());
    for (i, ch) in raw.char_indices() {
        if out.len() >= MAX_WRITTEN {
            return;
        }
        let lead = first && Some(i) == lead_at && (ch == '+' || "▶►▸▹▷▾▼".contains(ch));
        if lead || symbols::sense_value(ch).is_some() || symbols::private_use(ch) || symbols::SPEAKERS.contains(ch) {
            out.push(Written { node, at: at + i, len: ch.len_utf8(), ch, lead });
        }
    }
}

/// A label's kind, its value and the text drawn.
struct Label {
    kind: &'static str,
    value: String,
    max: Option<u32>,
    text: String,
}

impl Label {
    fn html(&self) -> String {
        let max = self.max.map(|m| format!(" data-xdict-max=\"{m}\"")).unwrap_or_default();
        format!(
            "<span data-xdict-role=\"label\" data-xdict-label=\"{}\" data-xdict-value=\"{}\"{max}>{}</span>",
            self.kind, self.value, self.text
        )
    }
}

/// What a graphic means (§7.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Meaning {
    /// A level and/or a word list: the labels are read from the tokens.
    LevelList,
    Frequency,
    New,
    /// A level written as text in a box the dictionary draws: the text is the level.
    Pill,
}

fn tokens(a: &Attrs) -> Vec<String> {
    let mut out = Vec::new();
    for c in &a.classes {
        out.push(c.clone());
        out.extend(c.split(['_', '-']).filter(|p| !p.is_empty()).map(str::to_owned));
    }
    if !a.kind.is_empty() {
        out.push(a.kind.to_string());
    }
    if !a.stem.is_empty() {
        out.push(a.stem.to_string());
        out.extend(a.stem.split(['_', '-']).filter(|p| !p.is_empty()).map(str::to_owned));
    }
    out
}

/// What a drawn box's whole text names: a CEFR level, or a word list written as text (OPAL's written and spoken
/// lists, "OPAL W" and "OPAL S").
fn pill(text: &str) -> Option<Label> {
    if let Some(level) = cefr(text) {
        return Some(Label { kind: "level", value: level.clone(), max: None, text: level });
    }
    let squeezed: String = text.split_whitespace().collect::<Vec<_>>().join(" ").to_ascii_uppercase();
    let value = match squeezed.as_str() {
        "OPAL W" => "opal-w",
        "OPAL S" => "opal-s",
        _ => return None,
    };
    Some(Label { kind: "wordlist", value: value.into(), max: None, text: squeezed })
}

fn cefr(t: &str) -> Option<String> {
    let t = t.trim().to_ascii_lowercase();
    matches!(t.as_str(), "a1" | "a2" | "b1" | "b2" | "c1" | "c2").then(|| t.to_ascii_uppercase())
}

/// The level a class (whole, or its last part: never a prefix, `C1_cabr_1` is a class), or a title or alt, names.
fn level_of(a: &Attrs) -> Option<String> {
    a.classes
        .iter()
        .flat_map(|c| [c.as_str(), c.rsplit(['_', '-']).next().unwrap_or(c)])
        .chain([&*a.title, &*a.alt])
        .find_map(cefr)
}

fn list_of(t: &str) -> Option<(&'static str, &'static str)> {
    let squeezed = t.replace(' ', "");
    if t.contains("ox5k") || squeezed.contains("oxford5000") {
        Some(("oxford5000", "Oxford 5000"))
    } else if t == "awl" {
        Some(("awl", "AWL"))
    } else if t.contains("ox3k") || squeezed.contains("oxford3000") || t == "key" || t.contains("keyword") {
        Some(("oxford3000", "Oxford 3000"))
    } else {
        None
    }
}

fn frequency_token(t: &str) -> bool {
    let digit_after = |p: &str| t.strip_prefix(p).is_some_and(|r| r.starts_with(|c: char| c.is_ascii_digit()));
    t.starts_with("freq")
        || t.contains("frequency")
        || t.starts_with("star")
        || ["band", "level", "rank", "lvl"].iter().any(|p| digit_after(p))
}

fn new_token(t: &str) -> bool {
    let bytes = t.as_bytes();
    ["new", "update"].iter().any(|w| {
        t.match_indices(w).any(|(at, m)| {
            let before = at.checked_sub(1).and_then(|b| bytes.get(b)).is_some_and(u8::is_ascii_lowercase);
            let after = bytes.get(at + m.len()).is_some_and(u8::is_ascii_lowercase);
            !before && !after
        })
    })
}

fn control_token(t: &str) -> bool {
    ["save", "fav", "bookmark", "share", "print", "copy"].iter().any(|w| t.contains(w))
}

pub(super) fn decide(
    nodes: &[Node],
    t: &Tree<'_>,
    roles: &[Option<Role>],
    written: &[Written],
    facts: &Facts,
    decided: &mut Decided,
) {
    let n = nodes.len();
    let mut count = BTreeMap::<String, u64>::new();
    let mut done = vec![false; n];
    labels(nodes, t, &mut done, &mut count, decided);
    let disclosure = disclosures(nodes, t, facts, &mut count, decided);
    speaker_rows(nodes, t, &mut count, decided);
    drawn(nodes, t.buf, &disclosure, &mut count, decided);
    text(nodes, roles, written, &disclosure, &mut count, decided);
    empty_links(nodes, t, &done, &mut count, decided);
    for (k, v) in count {
        *decided.icons.entry(k).or_default() += v;
    }
}

/// Whether an element shows no words: no text, or only a key or an icon face's glyphs (OALECD's `🔑`), which are
/// the word-list sign itself. Stars and dots written as text are the dictionary's words and stay (§7.1).
fn wordless(t: &Tree<'_>, i: usize) -> bool {
    let f = t.f(i);
    f.len == 0
        || f.short
            .as_deref()
            .is_some_and(|s| s.chars().all(|c| c.is_whitespace() || c == '🔑' || symbols::private_use(c)))
}

fn ancestors(nodes: &[Node], i: usize) -> impl Iterator<Item = &Node> {
    let mut at = nodes.get(i).map_or(0, |n| n.parent as usize);
    std::iter::from_fn(move || {
        if at == 0 {
            return None;
        }
        let node = nodes.get(at)?;
        at = node.parent as usize;
        Some(node)
    })
}

fn meaning(nodes: &[Node], t: &Tree<'_>, i: usize) -> Option<Meaning> {
    let node = nodes.get(i)?;
    const SKIP: [&str; 9] = ["script", "style", "br", "hr", "html", "body", "head", "meta", "link"];
    if SKIP.contains(&&*node.name) || node.inherit.in_speaker || node.recording.is_some() || node.icon.keyed.is_some() {
        return None;
    }
    // A level pill: the element's whole text is a level and the dictionary's rules draw its box. A link keeps its text.
    if node.drawn && !matches!(&*node.name, "img" | "a") && t.f(i).short.as_deref().and_then(pill).is_some() {
        return Some(Meaning::Pill);
    }
    if &*node.name != "img" && !wordless(t, i) {
        return None;
    }
    let a = &node.icon;
    let toks = tokens(a);
    let near = ancestors(nodes, i).take(CONTROL_ANCESTORS).flat_map(|p| p.icon.classes.iter());
    if toks.iter().any(|x| control_token(x)) || near.into_iter().any(|c| control_token(c)) {
        return None;
    }
    if level_of(a).is_some() || toks.iter().any(|x| list_of(x).is_some()) {
        return Some(Meaning::LevelList);
    }
    if toks.iter().any(|x| frequency_token(x)) {
        return Some(Meaning::Frequency);
    }
    (&*node.name == "img" && toks.iter().any(|x| new_token(x))).then_some(Meaning::New)
}

/// A number in a text: the first run of digits.
fn number_in(text: &str) -> Option<u32> {
    let d: String = text.chars().skip_while(|c| !c.is_ascii_digit()).take_while(char::is_ascii_digit).take(4).collect();
    d.parse().ok()
}

/// A token that only numbers its element among its siblings (`level3`), not a mark it carries (`roundRed`).
fn indexed(t: &str) -> bool {
    let letters = t.trim_end_matches(|c: char| c.is_ascii_digit());
    letters.len() < t.len() && letters.chars().all(|c| c.is_ascii_alphabetic())
}

fn labels(nodes: &[Node], t: &Tree<'_>, done: &mut [bool], count: &mut BTreeMap<String, u64>, decided: &mut Decided) {
    let n = nodes.len();
    let meanings: Vec<Option<Meaning>> = (0..n).map(|i| if i == 0 { None } else { meaning(nodes, t, i) }).collect();
    // Runs of frequency dots: two or more siblings of one first class.
    let mut group: Vec<Option<u32>> = vec![None; n];
    for p in 0..n {
        let mut by_class: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
        for c in t.el_kids(p) {
            if meanings.get(c).copied().flatten() == Some(Meaning::Frequency)
                && let Some(first) = nodes.get(c).and_then(|x| x.icon.classes.first())
            {
                by_class.entry(first.as_str()).or_default().push(c);
            }
        }
        for dots in by_class.into_values().filter(|d| d.len() >= 2) {
            let Some(&lead) = dots.first() else { continue };
            for &d in &dots {
                if let Some(g) = group.get_mut(d) {
                    *g = Some(lead as u32);
                }
            }
            let base = nodes.get(lead).and_then(|x| x.icon.classes.first()).cloned().unwrap_or_default();
            let marked = dots
                .iter()
                .filter(|&&d| nodes.get(d).is_some_and(|x| x.icon.classes.iter().any(|c| *c != base && !indexed(c))))
                .count();
            let (value, max) = (marked as u32, dots.len() as u32);
            let label = Label {
                kind: "frequency",
                value: value.to_string(),
                max: Some(max),
                text: format!("Frequency {value}/{max}"),
            };
            if let Some(node) = nodes.get(lead) {
                decided.edits.push((node.start, node.start, label.html()));
                *count.entry("label:frequency".into()).or_default() += 1;
            }
        }
    }
    let mut below = vec![false; n];
    for i in (1..n).rev() {
        let Some(node) = nodes.get(i) else { continue };
        let emitted = if group.get(i).copied().flatten().is_some() {
            hide(node, decided);
            true
        } else if below.get(i).copied().unwrap_or(false) {
            false
        } else if let Some(m) = meanings.get(i).copied().flatten() {
            let found = read_labels(node, m, t.f(i).short.as_deref());
            if found.is_empty() {
                false
            } else {
                let html: String = found.iter().map(Label::html).collect();
                for l in &found {
                    *count.entry(format!("label:{}", l.kind)).or_default() += 1;
                }
                place(nodes, t, i, html, done, decided);
                true
            }
        } else {
            false
        };
        if (emitted || below.get(i).copied().unwrap_or(false))
            && let Some(b) = below.get_mut(node.parent as usize)
        {
            *b = true;
        }
        if emitted && let Some(d) = done.get_mut(i) {
            *d = true;
        }
    }
}

fn read_labels(node: &Node, m: Meaning, text: Option<&str>) -> Vec<Label> {
    let a = &node.icon;
    let toks = tokens(a);
    match m {
        Meaning::LevelList => {
            let mut out = Vec::new();
            if let Some((value, text)) = toks.iter().find_map(|x| list_of(x)) {
                out.push(Label { kind: "wordlist", value: value.into(), max: None, text: text.into() });
            }
            if let Some(level) = level_of(a) {
                out.push(Label { kind: "level", value: level.clone(), max: None, text: level });
            }
            out
        }
        Meaning::Frequency => {
            let value = number_in(&a.title).or_else(|| {
                toks.iter().find_map(|x| {
                    ["band", "level", "rank", "lvl"].iter().find_map(|p| x.strip_prefix(p).and_then(|r| r.parse().ok()))
                })
            });
            let Some(value) = value else { return Vec::new() };
            // A band is one of eight (OED's bands); another single step names no scale.
            let max = toks.iter().any(|x| x.contains("band")).then_some(8);
            let text = max.map_or_else(|| format!("Frequency {value}"), |m| format!("Frequency {value}/{m}"));
            vec![Label { kind: "frequency", value: value.to_string(), max, text }]
        }
        Meaning::Pill => text.and_then(pill).into_iter().collect(),
        Meaning::New => vec![Label { kind: "new", value: "new".into(), max: None, text: "New".into() }],
    }
}

/// Hides a graphic a label replaced: kept for a script's hook and for the dictionary's own style.
fn hide(node: &Node, decided: &mut Decided) {
    decided.edits.push((node.attr_at, node.attr_at, " hidden data-xdict-labelled".into()));
}

/// Puts a label where graphic `i` was: a link that was the graphic is replaced, one that held only it is unwrapped.
fn place(nodes: &[Node], t: &Tree<'_>, i: usize, html: String, done: &mut [bool], decided: &mut Decided) {
    let Some(node) = nodes.get(i) else { return };
    if &*node.name == "a" {
        let until = node.end.map_or(node.tag_end, |(_, after)| after);
        decided.edits.push((node.start, until, html));
        return;
    }
    decided.edits.push((node.start, node.start, html));
    hide(node, decided);
    let p = node.parent as usize;
    if let Some(parent) = nodes.get(p).filter(|x| &*x.name == "a" && p != 0)
        && wordless(t, p)
        && t.el_kids(p).count() == 1
        && let Some((end, after)) = parent.end
    {
        decided.edits.push((parent.start, parent.tag_end, String::new()));
        decided.edits.push((end, after, String::new()));
        if let Some(d) = done.get_mut(p) {
            *d = true;
        }
    }
}

const FOLD: [&str; 10] =
    ["toggle", "expand", "collaps", "fold", "show", "hide", "more", "less", "display", "classname"];
const NOT_FOLD: [&str; 15] = [
    "img", "pic", "thumb", "enlarg", "big", "zoom", "media", "popup", "tip", "showat", "pron_key", "switch", "audio",
    "window", "wordform",
];

/// The first element of box `i`, when a kept script names it by a class and an element follows it in the box (the
/// fold it opens): the head a click on which the script binds.
fn caption(nodes: &[Node], i: usize, facts: &Facts) -> Option<usize> {
    let mut els = nodes.get(i)?.kids.iter().filter_map(|k| match k {
        Kid::El(c) => Some(*c as usize),
        Kid::Text { .. } => None,
    });
    let first = els.next()?;
    let named = nodes.get(first).is_some_and(|c| facts.script_named(&c.name, false, &c.icon.classes));
    (named && els.next().is_some()).then_some(first)
}

/// §7.3: a clickable whose handler names a fold, and is not about an image, a popup, a tip, a tab, audio, a window or
/// a pronunciation key; or an element a kept script names by a class that says it folds. Marked `disclosure`.
fn disclosures(
    nodes: &[Node],
    t: &Tree<'_>,
    facts: &Facts,
    count: &mut BTreeMap<String, u64>,
    decided: &mut Decided,
) -> Vec<bool> {
    let mut marked = vec![false; nodes.len()];
    for (i, node) in nodes.iter().enumerate().skip(1) {
        if node.inherit.in_speaker || node.recording.is_some() || node.icon.keyed.is_some() || &*node.name == "img" {
            continue;
        }
        let a = &node.icon;
        let handler = a.handler.to_ascii_lowercase();
        let key = format!("{}.{}", node.name, a.classes.first().map_or("", String::as_str));
        let by_handler = !handler.is_empty()
            && FOLD.iter().any(|w| handler.contains(w))
            && !NOT_FOLD.iter().any(|w| key.contains(w) || handler.contains(w));
        let by_class = handler.is_empty()
            && a.classes.iter().any(|c| {
                ["fold", "toggle", "expand", "collaps"].iter().any(|w| c.contains(w))
                    && facts.script_named(&node.name, false, std::slice::from_ref(c))
            });
        // A box named by its folded state folds by a click on its first child when the script names that child too
        // (COBUILD's `$('.trend > .caption').on('click', …)` on `div.trend.folded`): the child is the head, so a click
        // on XDict's chevron reaches the handler, and the fold is the child's next sibling.
        let head = if by_class { caption(nodes, i, facts).unwrap_or(i) } else { i };
        if (by_handler || by_class)
            && let Some(h) = nodes.get(head)
            && !marked.get(head).copied().unwrap_or(true)
        {
            decided.edits.push((h.attr_at, h.attr_at, " data-xdict-control=\"disclosure\"".into()));
            *count.entry("disclosure".into()).or_default() += 1;
            if let Some(m) = marked.get_mut(head) {
                *m = true;
            }
        }
    }
    signs(nodes, t, &marked, count, decided);
    marked
}

/// A box holding speakers and no word (CEPD's `sense-info`) is marked `data-xdict-speakers`: the marks draw it inline,
/// so its speakers sit on their transcription's line rather than on a line of their own; every such box, nested ones too.
fn speaker_rows(nodes: &[Node], t: &Tree<'_>, count: &mut BTreeMap<String, u64>, decided: &mut Decided) {
    let n = nodes.len();
    let mut holds = vec![false; n];
    for j in (1..n).rev() {
        let Some(node) = nodes.get(j) else { continue };
        let parent = node.parent as usize;
        let root = node.inherit.in_speaker && !nodes.get(parent).is_some_and(|p| p.inherit.in_speaker);
        if (root || holds.get(j).copied().unwrap_or(false))
            && parent != 0
            && let Some(h) = holds.get_mut(parent)
        {
            *h = true;
        }
    }
    let mut marked = vec![false; n];
    for (i, node) in nodes.iter().enumerate().skip(1) {
        if node.inherit.in_speaker || !holds.get(i).copied().unwrap_or(false) || !wordless(t, i) {
            continue;
        }
        if let Some(m) = marked.get_mut(i) {
            *m = true;
        }
        // The outermost box leading its parent, with an element after it (CEPD's `sense-head` before its
        // `sense-body`): `lead`, drawn at the line's start so the next block's first line runs beside it.
        let parent = node.parent as usize;
        let first = nodes.get(parent).is_some_and(|p| {
            p.kids
                .get(..node.pos as usize)
                .is_some_and(|before| before.iter().all(|k| matches!(k, Kid::Text { blank: true, .. })))
        });
        let lead = !marked.get(parent).copied().unwrap_or(false) && first && t.sibling(i, true).is_some();
        let mark = if lead { " data-xdict-speakers=\"lead\"" } else { " data-xdict-speakers" };
        decided.edits.push((node.attr_at, node.attr_at, mark.into()));
        *count.entry("speakers-row".into()).or_default() += 1;
    }
}

/// How far below its fold head a dictionary's own fold sign is looked for.
const SIGN_DEPTH: usize = 4;

/// A fold head's own sign goes where XDict draws its chevron: a drawn box holding no word inside a head, when the head
/// is itself wordless (the sign is the head: its lines go) or the box's class names a fold (COBUILD's
/// `cc_addon_foldButton` inside "Trends of …"). Hidden, not removed: a script's hook stays.
fn signs(nodes: &[Node], t: &Tree<'_>, marked: &[bool], count: &mut BTreeMap<String, u64>, decided: &mut Decided) {
    let mut gone = vec![false; nodes.len()];
    for (j, node) in nodes.iter().enumerate().skip(1) {
        let parent = node.parent as usize;
        if gone.get(parent).copied().unwrap_or(false) {
            if let Some(g) = gone.get_mut(j) {
                *g = true;
            }
            continue;
        }
        if marked.get(j).copied().unwrap_or(false) || !node.drawn || &*node.name == "img" || !wordless(t, j) {
            continue;
        }
        let mut at = parent;
        let mut head = None;
        for _ in 0..SIGN_DEPTH {
            if at == 0 {
                break;
            }
            if marked.get(at).copied().unwrap_or(false) {
                head = Some(at);
                break;
            }
            at = nodes.get(at).map_or(0, |x| x.parent as usize);
        }
        let Some(h) = head else { continue };
        let named =
            node.icon.classes.iter().any(|c| ["fold", "toggle", "expand", "collaps"].iter().any(|w| c.contains(w)));
        if wordless(t, h) || named {
            hide(node, decided);
            *count.entry("disclosure:sign".into()).or_default() += 1;
            if let Some(g) = gone.get_mut(j) {
                *g = true;
            }
        }
    }
}

/// Whether an empty element sits inside a word: in its parent, text right before it and right after it (one inline
/// run, no element or block boundary between), ending and starting with a letter or digit.
fn within_word(nodes: &[Node], i: usize, buf: &str) -> bool {
    let Some(node) = nodes.get(i) else { return false };
    let (start, end) = (node.text.0 as usize, node.text.1 as usize);
    if start != end {
        return false;
    }
    let Some(parent) = nodes.get(node.parent as usize) else { return false };
    let at = node.pos as usize;
    if !matches!(parent.kids.get(at), Some(Kid::El(e)) if *e as usize == i) {
        return false;
    }
    let text = |k: Option<&Kid>| matches!(k, Some(Kid::Text { blank: false, .. }));
    if !(at > 0 && text(parent.kids.get(at - 1)) && text(parent.kids.get(at + 1))) {
        return false;
    }
    let before = buf.get(..start).and_then(|b| b.chars().next_back());
    let after = buf.get(end..).and_then(|a| a.chars().next());
    before.is_some_and(char::is_alphanumeric) && after.is_some_and(char::is_alphanumeric)
}

fn link_name(link: Option<Lk>) -> &'static str {
    match link {
        Some(Lk::Sound) => "sound",
        Some(Lk::Lookup) => "lookup",
        Some(Lk::Anchor) => "anchor",
        Some(Lk::Other) => "other",
        _ => "",
    }
}

/// §7.1 on what a sheet draws: XDict's marker, its `lookup` mark, or nothing (`drop`); the frame draws the mark in
/// place of the dictionary's glyph.
fn drawn(nodes: &[Node], buf: &str, disclosure: &[bool], count: &mut BTreeMap<String, u64>, decided: &mut Decided) {
    for (i, node) in nodes.iter().enumerate().skip(1) {
        let a = &node.icon;
        for (side, glyph) in [("before", &a.before), ("after", &a.after)] {
            let Some((ch, selector)) = glyph else { continue };
            let classes = format!("{} {selector}", a.classes.join(" "));
            let click = node.handled || disclosure.get(i).copied().unwrap_or(false);
            let ctx = Ctx {
                pseudo: true,
                icon_font: symbols::private_use(*ch),
                classes: &classes,
                click,
                link: link_name(node.inherit.link),
                alone: true,
                run: 1,
                control: node.inherit.in_speaker,
                ..Ctx::default()
            };
            let mark = match symbols::owned(*ch, symbols::treatment(*ch, &ctx), &*node.name == "li") {
                // A dot drawn between two letters is a syllable break (NOAD's `ser•en•dip`), never a list marker.
                Treatment::Marker if within_word(nodes, i, buf) => continue,
                Treatment::Marker => "marker",
                Treatment::Xref => "lookup",
                Treatment::Speaker | Treatment::Wordlist | Treatment::Drop | Treatment::Frequency => "drop",
                Treatment::Disclosure => {
                    if !disclosure.get(i).copied().unwrap_or(false) {
                        decided.edits.push((node.attr_at, node.attr_at, " data-xdict-control=\"disclosure\"".into()));
                        *count.entry("disclosure".into()).or_default() += 1;
                    }
                    "drop"
                }
                Treatment::SenseNumber | Treatment::Keep => continue,
            };
            decided.edits.push((node.attr_at, node.attr_at, format!(" data-xdict-{side}=\"{mark}\"")));
            *count.entry(format!("drawn:{mark}")).or_default() += 1;
        }
    }
}

/// §7.1 on symbols written as text: a sense number becomes a plain number, a speaker's glyph inside a speaker and a
/// fold head's triangle go (XDict's controls draw them); every other symbol stays.
fn text(
    nodes: &[Node],
    roles: &[Option<Role>],
    written: &[Written],
    disclosure: &[bool],
    count: &mut BTreeMap<String, u64>,
    decided: &mut Decided,
) {
    for w in written {
        let i = w.node as usize;
        let Some(node) = nodes.get(i) else { continue };
        let (edit, kind) = if let Some(v) = symbols::sense_value(w.ch) {
            if roles.get(i).copied().flatten() == Some(Role::Sensenum) {
                (v, "sensenum")
            } else {
                (format!("<span data-xdict-role=\"sensenum\">{v}</span>"), "sensenum")
            }
        } else if node.inherit.in_speaker && (symbols::private_use(w.ch) || symbols::SPEAKERS.contains(w.ch)) {
            (String::new(), "speaker-glyph")
        } else if w.lead && disclosure.get(i).copied().unwrap_or(false) {
            (String::new(), "disclosure-glyph")
        } else {
            continue;
        };
        decided.edits.push((w.at, w.at + w.len, edit));
        *count.entry(kind.into()).or_default() += 1;
    }
}

/// §7.5, §7.7: a link with nothing in it (no text, no element) that goes nowhere XDict follows (a `javascript:` popup,
/// a website's path) goes; an anchor (`<a name>`, `<a id>` without `href`) stays.
fn empty_links(nodes: &[Node], t: &Tree<'_>, done: &[bool], count: &mut BTreeMap<String, u64>, decided: &mut Decided) {
    for (i, node) in nodes.iter().enumerate().skip(1) {
        if &*node.name != "a"
            || !node.href
            || matches!(node.link, Lk::Lookup | Lk::Sound | Lk::Anchor)
            || node.recording.is_some()
            || node.icon.keyed.is_some()
            || done.get(i).copied().unwrap_or(false)
            || t.f(i).len != 0
            || node.kids.iter().any(|k| matches!(k, Kid::El(_)))
        {
            continue;
        }
        let Some((_, after)) = node.end else { continue };
        decided.edits.push((node.start, after, String::new()));
        *count.entry("empty-link".into()).or_default() += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::Attrs;

    /// Every element of an entry holds its `Attrs`, up to `MAX_NODES` of them, and most elements have nothing the
    /// icon rules read: what it holds inline is paid for each one (232 bytes made 50 MiB of links 15 MiB larger).
    #[test]
    fn attrs_inline_is_small() {
        // An element with anything the rules read (each image, by its file stem) boxes a `Detail`.
        assert!(size_of::<super::Detail>() <= 160, "Detail: {} bytes", size_of::<super::Detail>());
        assert!(size_of::<Attrs>() <= 8 && size_of::<super::Inherited>() <= 2, "{} bytes", size_of::<Attrs>());
    }
}
