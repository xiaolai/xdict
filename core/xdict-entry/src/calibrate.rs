//! The base size from the text itself (ADR-0010 d.4, as corrected 2026-10-15): each sampled entry's visible text is
//! attributed to the size it is set in, under the edition's sheets, and the base is the size most of its characters
//! take. A rule weighs what it covers, so a container holding the whole entry wins and hidden or tiny selectors weigh
//! their few characters.
//!
//! No DOM: a tag scanner follows open elements, and a rule matches an element when its selector's compounds (element,
//! classes, id) match the element and, in order, its ancestors; sibling combinators, pseudo-classes and attribute
//! values are not read, so such a selector does not take part. That is enough to tell which size text is set in.
//!
//! Hidden text (`display:none`, `visibility:hidden`) does not count, except where an entry's text is mostly hidden:
//! there a script reveals it (Chambers hides its whole `cb13` until its script runs), and all of it counts.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::normalize::{Rule, absolute_px, keyword_px, relative_ratio};

/// The most of each entry read.
const ENTRY_BYTES: usize = 256 << 10;
/// The deepest open element followed.
const MAX_DEPTH: usize = 256;
/// How far down the stack an end tag looks for its element.
const MATCH_DEPTH: usize = 32;
/// The most compounds a selector may have, and the most ancestor steps tried in all.
const MAX_COMPOUNDS: usize = 8;
/// Every candidate rule collected, rule tried and ancestor step taken costs one; past it, calibration stops and
/// answers from what it has read. Each costs a constant: a compound has at most `MAX_CLASSES` classes, an element
/// at most `ELEMENT_CLASSES`.
const MATCH_BUDGET: u64 = 20_000_000;
const MAX_CLASSES: usize = 8;
const ELEMENT_CLASSES: usize = 32;
const VOID: [&str; 14] =
    ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param"];

/// What a rule sets that calibration needs.
#[derive(Clone, Copy)]
enum Size {
    Absolute(f64),
    Relative(f64),
    Unset,
}

/// One compound selector: an element, classes, an id; each may be absent.
#[derive(Default)]
struct Compound {
    tag: Option<String>,
    classes: Vec<String>,
    id: Option<String>,
}

/// An element as the scanner meets it.
struct Element {
    tag: String,
    classes: Vec<String>,
    id: Option<String>,
}

impl Compound {
    fn matches(&self, e: &Element) -> bool {
        self.tag.as_ref().is_none_or(|t| *t == e.tag)
            && self.id.as_ref().is_none_or(|x| e.id.as_ref() == Some(x))
            && self.classes.iter().all(|c| e.classes.contains(c))
    }
}

/// A selector, subject last, and what its rule sets.
struct Sized {
    /// The selector as written: trimmed, lower case, its spaces collapsed.
    selector: String,
    compounds: Vec<Compound>,
    size: Size,
    hidden: bool,
}

/// What the text says: the size most characters are set in, how many are, and their share of all.
pub(crate) struct Measured {
    pub(crate) px: f64,
    /// The selectors whose relative size, wherever the sample met it, sized an element whose parent was at the page's
    /// size: what they set is the page's size times their ratio (R4, D48).
    pub(crate) over_page: BTreeSet<String>,
    pub(crate) chars: u64,
    pub(crate) share: f64,
}

fn size_of(value: &str) -> Size {
    let v = value.trim();
    if let Some(px) = absolute_px(v).or_else(|| keyword_px(v)) {
        return Size::Absolute(px);
    }
    relative_ratio(v).map_or(Size::Unset, Size::Relative)
}

fn hides(name: &str, value: &str) -> bool {
    let v = value.trim().to_ascii_lowercase();
    (name == "display" && v == "none") || (name == "visibility" && v == "hidden")
}

/// A compound as written (`div.a.b#c`).
fn compound(plain: &str) -> Option<Compound> {
    let mut out = Compound::default();
    let mut part = String::new();
    let mut kind = 't';
    let flush = |kind: char, part: &mut String, out: &mut Compound| {
        let word = std::mem::take(part).to_ascii_lowercase();
        if word.is_empty() || word == "*" {
            return;
        }
        match kind {
            '.' => out.classes.push(word),
            '#' => out.id = Some(word),
            _ => out.tag = Some(word),
        }
    };
    for c in plain.chars() {
        if c == '.' || c == '#' {
            flush(kind, &mut part, &mut out);
            kind = c;
        } else {
            part.push(c);
        }
    }
    flush(kind, &mut part, &mut out);
    (out.classes.len() <= MAX_CLASSES).then_some(out)
}

/// Each selector of `rule` that calibration can read.
fn selectors(rule: &Rule, size: Size, hidden: bool, out: &mut Vec<Sized>) {
    for selector in rule.selector.split(',') {
        // Attribute values are not read: dropped, `[class^=x]` would match every element.
        if selector.contains([':', '+', '~', '[']) {
            continue;
        }
        let spaced = selector.replace('>', " ");
        let parts: Vec<&str> = spaced.split_whitespace().collect();
        if parts.is_empty() || parts.len() > MAX_COMPOUNDS {
            continue;
        }
        let compounds: Option<Vec<Compound>> = parts.iter().map(|p| compound(p)).collect();
        if let Some(compounds) = compounds {
            let selector = selector.split_whitespace().collect::<Vec<_>>().join(" ").to_ascii_lowercase();
            out.push(Sized { selector, compounds, size, hidden });
        }
    }
}

/// One open element: what it is, its size in pixels, whether that is still the page's, and whether it is hidden.
struct Open {
    element: Element,
    px: f64,
    at_page: bool,
    hidden: bool,
}

/// By selector, how many elements its relative size sized over a parent at the page's size, and over any other.
type Applied = HashMap<String, (u64, u64)>;

/// The size most of `entries`' visible text is set in under `rules`, the page at `page_px`; `None` when they hold no
/// text.
pub(crate) fn measure<'a, 'r>(
    rules: impl Iterator<Item = &'r Rule>,
    page_px: f64,
    entries: impl IntoIterator<Item = &'a str>,
) -> Option<Measured> {
    let mut sized = Vec::new();
    for rule in rules.filter(|r| !r.face && !r.page) {
        let size =
            rule.decls.iter().rev().find_map(|(n, v)| (n == "font-size").then(|| size_of(v))).unwrap_or(Size::Unset);
        let hidden = rule.decls.iter().any(|(n, v)| hides(n, v));
        if hidden || !matches!(size, Size::Unset) {
            selectors(rule, size, hidden, &mut sized);
        }
    }
    // By the subject's most selective key: a class, else its id, else its element, else any element.
    let mut index: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, s) in sized.iter().enumerate() {
        let Some(subject) = s.compounds.last() else { continue };
        let key = match (subject.classes.first(), &subject.id, &subject.tag) {
            (Some(c), _, _) => format!(".{c}"),
            (None, Some(id), _) => format!("#{id}"),
            (None, None, Some(t)) => t.clone(),
            _ => "*".to_owned(),
        };
        index.entry(key).or_default().push(i);
    }
    let mut chars: BTreeMap<u64, u64> = BTreeMap::new();
    let mut applied = Applied::new();
    let mut budget = MATCH_BUDGET;
    for entry in entries {
        let end = (0..=entry.len().min(ENTRY_BYTES)).rev().find(|&i| entry.is_char_boundary(i)).unwrap_or(0);
        let (visible, all) = scan(entry.get(..end).unwrap_or(""), page_px, &sized, &index, &mut applied, &mut budget);
        let (v, a): (u64, u64) = (visible.values().sum(), all.values().sum());
        // Mostly hidden: a script reveals it.
        let counted = if v * 2 < a { all } else { visible };
        for (k, n) in counted {
            *chars.entry(k).or_default() += n;
        }
        if budget == 0 {
            break;
        }
    }
    let total: u64 = chars.values().sum();
    let (&key, &most) = chars.iter().max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0)))?;
    let over_page = applied.into_iter().filter(|(_, (page, other))| *page > 0 && *other == 0).map(|(s, _)| s).collect();
    (total > 0).then(|| Measured { px: key as f64 / 100.0, over_page, chars: most, share: most as f64 / total as f64 })
}

type Counted = BTreeMap<u64, u64>;

/// One entry's characters by size, visible ones and all.
fn scan(
    text: &str,
    page_px: f64,
    sized: &[Sized],
    index: &HashMap<String, Vec<usize>>,
    applied: &mut Applied,
    budget: &mut u64,
) -> (Counted, Counted) {
    let (mut visible, mut all) = (Counted::new(), Counted::new());
    let mut stack: Vec<Open> = Vec::new();
    let mut deep = 0usize;
    let mut rest = text;
    let mut count = |run: &str, stack: &[Open]| {
        let (px, hidden) = stack.last().map_or((page_px, false), |o| (o.px, o.hidden));
        let n = run.chars().filter(|c| !c.is_whitespace()).count() as u64;
        if n > 0 {
            let key = (px * 100.0).round() as u64;
            *all.entry(key).or_default() += n;
            if !hidden {
                *visible.entry(key).or_default() += n;
            }
        }
    };
    while let Some(at) = rest.find('<') {
        if *budget == 0 {
            rest = "";
            break;
        }
        count(rest.get(..at).unwrap_or(""), &stack);
        let from = rest.get(at..).unwrap_or("");
        if let Some(comment) = from.strip_prefix("<!--") {
            rest = comment.find("-->").and_then(|e| comment.get(e + 3..)).unwrap_or("");
            continue;
        }
        let close = from.find('>').map_or(from.len(), |e| e + 1);
        let tag = from.get(..close).unwrap_or(from);
        rest = from.get(close..).unwrap_or("");
        let (end, inner) = match tag.strip_prefix("</") {
            Some(inner) => (true, inner),
            None => (false, tag.get(1..).unwrap_or("")),
        };
        let name: String = inner
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':'))
            .collect::<String>()
            .to_ascii_lowercase();
        if name.is_empty() {
            continue;
        }
        if end {
            if deep > 0 {
                deep -= 1;
                continue;
            }
            if let Some(up) = stack.iter().rev().take(MATCH_DEPTH).position(|o| o.element.tag == name) {
                stack.truncate(stack.len() - up - 1);
            }
            continue;
        }
        if name == "script" || name == "style" {
            let needle = format!("</{name}");
            rest = find_ignoring_case(rest, &needle).and_then(|e| rest.get(e..)).unwrap_or("");
            continue;
        }
        if VOID.contains(&name.as_str()) || tag.ends_with("/>") {
            continue;
        }
        if stack.len() >= MAX_DEPTH {
            deep += 1;
            continue;
        }
        let open = element(name, tag, &stack, page_px, (sized, index), applied, budget);
        stack.push(open);
    }
    count(rest, &stack);
    (visible, all)
}

/// Whether `ancestors` (outermost first) hold `compounds`, in order, as an element's ancestors.
fn ancestors_match(compounds: &[Compound], ancestors: &[Open], budget: &mut u64) -> bool {
    let mut need = compounds.iter().rev();
    let mut next = need.next();
    for open in ancestors.iter().rev() {
        let Some(c) = next else { return true };
        if *budget == 0 {
            return false;
        }
        *budget -= 1;
        if c.matches(&open.element) {
            next = need.next();
        }
    }
    next.is_none()
}

/// An element's size and visibility: its parent's, then each matching rule's in source order, then its own style.
/// Each relative size a rule gives it is counted in `applied`, by whether its parent was at the page's size.
fn element(
    name: String,
    tag: &str,
    stack: &[Open],
    page_px: f64,
    (sized, index): (&[Sized], &HashMap<String, Vec<usize>>),
    applied: &mut Applied,
    budget: &mut u64,
) -> Open {
    let classes: Vec<String> = crate::phon::attribute_of(tag, "class")
        .map(|c| c.split_ascii_whitespace().take(ELEMENT_CLASSES).map(str::to_ascii_lowercase).collect())
        .unwrap_or_default();
    let id = crate::phon::attribute_of(tag, "id").map(str::to_ascii_lowercase);
    let element = Element { tag: name, classes, id };
    let (parent_px, parent_at_page, parent_hidden) =
        stack.last().map_or((page_px, true, false), |o| (o.px, o.at_page, o.hidden));
    let mut candidates: Vec<usize> = Vec::new();
    let keys = element
        .classes
        .iter()
        .map(|c| format!(".{c}"))
        .chain(element.id.iter().map(|i| format!("#{i}")))
        .chain([element.tag.clone(), "*".to_owned()]);
    for key in keys {
        if let Some(list) = index.get(&key) {
            let room = usize::try_from(*budget).unwrap_or(usize::MAX).min(list.len());
            candidates.extend(list.iter().take(room));
            *budget -= room as u64;
        }
    }
    candidates.sort_unstable();
    candidates.dedup();
    let (mut px, mut at_page, mut hidden) = (parent_px, parent_at_page, parent_hidden);
    for i in candidates {
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        let Some(s) = sized.get(i) else { continue };
        let Some((subject, context)) = s.compounds.split_last() else { continue };
        if !subject.matches(&element) || !ancestors_match(context, stack, budget) {
            continue;
        }
        hidden |= s.hidden;
        match s.size {
            Size::Absolute(v) => (px, at_page) = (v, false),
            Size::Relative(r) => {
                (px, at_page) = (parent_px * r, false);
                let seen = applied.entry(s.selector.clone()).or_default();
                if parent_at_page { seen.0 += 1 } else { seen.1 += 1 }
            }
            Size::Unset => {}
        }
    }
    if let Some(style) = crate::phon::attribute_of(tag, "style") {
        for decl in style.split(';') {
            let Some((n, v)) = decl.split_once(':') else { continue };
            let n = n.trim().to_ascii_lowercase();
            hidden |= hides(&n, v);
            if n == "font-size" {
                match size_of(v) {
                    Size::Absolute(v) => (px, at_page) = (v, false),
                    Size::Relative(r) => (px, at_page) = (parent_px * r, false),
                    Size::Unset => {}
                }
            }
        }
    }
    Open { element, px, at_page, hidden }
}

/// Where `needle` (ASCII) first starts in `haystack`, compared ignoring case: one forward pass.
fn find_ignoring_case(haystack: &str, needle: &str) -> Option<usize> {
    let (h, n) = (haystack.as_bytes(), needle.as_bytes());
    (0..h.len()).find(|&i| h.get(i..i + n.len()).is_some_and(|w| w.eq_ignore_ascii_case(n)))
}

/// The most `<link>` tags read from one entry.
const LINKS_PER_ENTRY: usize = 64;

/// A path's or URL's file name, lower case, without query or fragment: how an entry's `<link href>` and a
/// package's sheet are matched.
pub fn file_name(path: &str) -> String {
    let path = path.split(['?', '#']).next().unwrap_or(path);
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_ascii_lowercase()
}

/// The file names of the sheets an entry links (`<link ... href="x.css">`): each tag read once, so the cost is the
/// entry's length; at most `LINKS_PER_ENTRY` of them.
pub fn linked_sheets(entry: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = entry;
    while out.len() < LINKS_PER_ENTRY {
        let Some(at) = rest.find('<') else { break };
        let from = rest.get(at + 1..).unwrap_or("");
        let end = from.find(['>', '<']).unwrap_or(from.len());
        let tag = from.get(..end).unwrap_or("");
        rest = from.get(end..).unwrap_or("");
        let is_link = tag.get(..4).is_some_and(|n| n.eq_ignore_ascii_case("link"))
            && tag.as_bytes().get(4).is_none_or(u8::is_ascii_whitespace);
        if is_link && let Some(href) = crate::phon::attribute_of(tag, "href") {
            out.push(file_name(href));
        }
    }
    out
}
