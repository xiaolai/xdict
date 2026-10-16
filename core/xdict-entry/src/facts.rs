//! What an edition's own CSS and scripts say about its elements, read once per edition (`dev-docs/element-sweep.md`
//! §2.1, §2.4): which classes and tags its rules set bold, italic, small capitals, superscript or unconditionally
//! hidden; which it draws (a pseudo-element, a size, a background or a border); which class and tag names its
//! scripts mention; and which element wraps its entries. Only a rule's subject is read, as the sweep read it: a rule
//! that names ancestors, pseudo-classes or attributes may not hold, so its `display` is not believed.

use std::collections::{BTreeMap, BTreeSet};

use crate::normalize::Rule;

/// The most classes a compound is read with.
const MAX_CLASSES: usize = 8;
/// The most distinct words kept from an edition's scripts.
const SCRIPT_WORDS: usize = 200_000;
/// The most bytes of one entry read for the element that wraps it.
const WRAPPER_BYTES: usize = 4096;

/// What a set of rules sets on an element, each property the last rule's.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Props {
    /// `Some(true)` bold, `Some(false)` normal.
    pub(crate) bold: Option<bool>,
    pub(crate) italic: Option<bool>,
    pub(crate) small_caps: Option<bool>,
    pub(crate) upper: Option<bool>,
    pub(crate) sup: Option<bool>,
    /// `display: none` (only from a rule that holds whatever the state).
    pub(crate) none: Option<bool>,
    /// `display: inline…` (`Some(true)`) or another box (`Some(false)`), from the same rules as `none`.
    pub(crate) inline: Option<bool>,
}

impl Props {
    fn over(&mut self, other: &Props) {
        self.bold = other.bold.or(self.bold);
        self.italic = other.italic.or(self.italic);
        self.small_caps = other.small_caps.or(self.small_caps);
        self.upper = other.upper.or(self.upper);
        self.sup = other.sup.or(self.sup);
        self.none = other.none.or(self.none);
        self.inline = other.inline.or(self.inline);
    }

    /// The properties `decls` set; `display` only when `simple`.
    pub(crate) fn of<'d>(decls: impl IntoIterator<Item = (&'d str, &'d str)>, simple: bool) -> Self {
        let mut p = Props::default();
        for (name, value) in decls {
            let v = value.trim().to_ascii_lowercase();
            let v = v.trim_end_matches("!important").trim();
            match name.trim().to_ascii_lowercase().as_str() {
                "font-weight" => {
                    if matches!(v, "bold" | "bolder" | "600" | "700" | "800" | "900") {
                        p.bold = Some(true);
                    } else if matches!(v, "normal" | "400" | "300" | "lighter") {
                        p.bold = Some(false);
                    }
                }
                "font-style" => {
                    if v.contains("italic") || v.contains("oblique") {
                        p.italic = Some(true);
                    } else if v == "normal" {
                        p.italic = Some(false);
                    }
                }
                "font-variant" => p.small_caps = Some(v.contains("small-caps")),
                "font" if v.contains("small-caps") => p.small_caps = Some(true),
                "text-transform" => p.upper = Some(v == "uppercase"),
                "vertical-align" => p.sup = Some(v.contains("super")),
                "display" if simple => {
                    p.none = Some(v == "none");
                    p.inline = Some(v.starts_with("inline") || v == "contents");
                }
                _ => {}
            }
        }
        p
    }
}

/// A rule's subject: its element and classes.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Subject {
    tag: Option<String>,
    classes: Vec<String>,
    props: Props,
}

/// An edition's facts.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Facts {
    /// Rules by their subject's first class.
    by_class: BTreeMap<String, Vec<Subject>>,
    /// Rules whose subject is an element only.
    by_tag: BTreeMap<String, Props>,
    /// Classes and elements a rule draws: a pseudo-element, a size, a background or a border.
    drawn: BTreeSet<String>,
    /// Words the edition's scripts hold, lower case.
    script_words: BTreeSet<String>,
    /// The element (`cb13`, `.entry`, `div.e`) that wraps most entries, when a rule hides it unconditionally.
    pub(crate) revealed: BTreeSet<String>,
    /// Symbols a rule's `::before`/`::after` draws, by its subject's first class, or element when it has none.
    glyphs: BTreeMap<String, Vec<Glyph>>,
    glyph_count: usize,
}

/// The most glyph rules read from an edition, and the most of one subject an element is checked against (the last
/// ones: a later rule wins).
const MAX_GLYPHS: usize = 8192;
const GLYPHS_PER_SUBJECT: usize = 16;
/// The most compounds of a selector read, and how far up an element's ancestors one is looked for.
const MAX_COMPOUNDS: usize = 8;
pub(crate) const ANCESTOR_DEPTH: usize = 32;

/// A compound of a selector: its element and classes, lower case.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Compound {
    pub(crate) tag: Option<String>,
    pub(crate) classes: Vec<String>,
}

impl Compound {
    pub(crate) fn matches(&self, tag: &str, classes: &[String]) -> bool {
        self.tag.as_deref().is_none_or(|t| t == tag) && self.classes.iter().all(|c| classes.contains(c))
    }
}

/// A symbol a rule's pseudo-element draws: on which subject, under which ancestors, before or after, and the
/// character (the first symbol of its `content`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Glyph {
    pub(crate) subject: Compound,
    pub(crate) ancestors: Vec<Compound>,
    pub(crate) after: bool,
    pub(crate) ch: char,
    /// The selector, lower case and bounded: its words are the symbol rule's context.
    pub(crate) selector: String,
}

/// A selector's parts that name what it is: element, classes, and whether it is plain (one compound, nothing
/// else), its pseudo-element if any. `None` when its subject has a state (`:hover`) or is not readable.
struct Read {
    tag: Option<String>,
    classes: Vec<String>,
    simple: bool,
    pseudo: bool,
}

fn read(selector: &str) -> Option<Read> {
    let selector = selector.trim();
    if selector.is_empty() {
        return None;
    }
    let spaced: String = selector.chars().map(|c| if matches!(c, '>' | '+' | '~') { ' ' } else { c }).collect();
    let mut parts = spaced.split_whitespace();
    let last = parts.next_back()?;
    let ancestors = parts.next().is_some();
    let lower = last.to_ascii_lowercase();
    let attrs = lower.contains('[');
    let mut pseudo = false;
    let mut plain = String::new();
    let mut rest = lower.split('[').next().unwrap_or("");
    let mut first = true;
    for piece in rest.split(':') {
        if first {
            plain.push_str(piece);
            first = false;
            continue;
        }
        let name = piece.split('(').next().unwrap_or("");
        match name {
            "" => {}
            "before" | "after" | "marker" => pseudo = true,
            "first-child" | "last-child" | "not" | "first-of-type" | "last-of-type" | "nth-child" | "nth-of-type" => {}
            _ => return None,
        }
    }
    rest = &plain;
    let mut tag = None;
    let mut classes = Vec::new();
    let mut kind = 't';
    let mut word = String::new();
    let mut flush = |kind: char, word: &mut String| {
        let w = std::mem::take(word);
        if w.is_empty() || w == "*" {
            return;
        }
        match kind {
            '.' => classes.push(w),
            '#' => {}
            _ => tag = Some(w),
        }
    };
    for c in rest.chars() {
        if c == '.' || c == '#' {
            flush(kind, &mut word);
            kind = c;
        } else {
            word.push(c);
        }
    }
    flush(kind, &mut word);
    let has_state = lower.contains(':') && !pseudo;
    (classes.len() <= MAX_CLASSES).then_some(Read { tag, classes, simple: !ancestors && !attrs && !has_state, pseudo })
}

/// Whether a declaration draws something on its own: a size, a background, a border, content.
fn draws(name: &str) -> bool {
    ["width", "height", "min-width", "min-height", "background", "border", "content", "list-style", "padding"]
        .iter()
        .any(|p| name.starts_with(p))
}

impl Facts {
    pub(crate) fn of_rules<'r>(rules: impl IntoIterator<Item = &'r Rule>) -> Self {
        let mut facts = Facts::default();
        for rule in rules {
            if rule.face {
                continue;
            }
            let drawing = rule.decls.iter().any(|(n, v)| draws(n) && !v.trim().is_empty());
            let glyph = drawn_symbol(&rule.decls);
            for one in rule.selector.split(',') {
                if let Some(ch) = glyph {
                    facts.glyph(one, ch);
                }
                let Some(r) = read(one) else { continue };
                let simple = r.simple && !rule.grouped;
                let props = Props::of(rule.decls.iter().map(|(n, v)| (n.as_str(), v.as_str())), simple);
                if r.pseudo || drawing {
                    if let Some(c) = r.classes.first() {
                        facts.drawn.insert(format!(".{c}"));
                    } else if let Some(t) = &r.tag {
                        facts.drawn.insert(t.clone());
                    }
                }
                if r.pseudo {
                    continue;
                }
                if let Some(c) = r.classes.first() {
                    facts.by_class.entry(c.clone()).or_default().push(Subject {
                        tag: r.tag.clone(),
                        classes: r.classes.clone(),
                        props,
                    });
                } else if let Some(t) = r.tag.filter(|t| t != "*") {
                    facts.by_tag.entry(t).or_default().over(&props);
                }
            }
        }
        facts
    }

    /// Whether a rule's subject leads with `class` (lower case): the edition's sheets style it.
    pub(crate) fn styles_class(&self, class: &str) -> bool {
        self.by_class.contains_key(class)
    }

    /// The properties an element's own rules set: its element's, then its classes'.
    pub(crate) fn props(&self, tag: &str, classes: &[String]) -> Props {
        let mut out = self.by_tag.get(tag).copied().unwrap_or_default();
        for c in classes {
            for s in self.by_class.get(c).map(Vec::as_slice).unwrap_or(&[]) {
                if s.tag.as_deref().is_none_or(|t| t == tag) && s.classes.iter().all(|x| classes.contains(x)) {
                    out.over(&s.props);
                }
            }
        }
        out
    }

    /// Reads a rule that draws symbol `ch` in a pseudo-element, by one piece of its selector.
    fn glyph(&mut self, selector: &str, ch: char) {
        if self.glyph_count >= MAX_GLYPHS {
            return;
        }
        let lower = selector.trim().to_ascii_lowercase();
        let spaced: String = lower.chars().map(|c| if matches!(c, '>' | '+' | '~') { ' ' } else { c }).collect();
        let parts: Vec<&str> = spaced.split_whitespace().collect();
        if parts.is_empty() || parts.len() > MAX_COMPOUNDS {
            return;
        }
        let Some((last, ancestors)) = parts.split_last() else { return };
        let after = if last.contains(":after") {
            true
        } else if last.contains(":before") {
            false
        } else {
            return;
        };
        let Some(subject) = compound(last) else { return };
        let ancestors: Option<Vec<Compound>> = ancestors.iter().map(|a| compound(a)).collect();
        let Some(ancestors) = ancestors else { return };
        let key = subject.classes.first().map_or_else(|| subject.tag.clone().unwrap_or_default(), |c| format!(".{c}"));
        let glyph = Glyph { subject, ancestors, after, ch, selector: lower.chars().take(160).collect() };
        self.glyphs.entry(key).or_default().push(glyph);
        self.glyph_count += 1;
    }

    /// The glyph rules whose subject is this element (its element and classes; ancestors are the caller's), the last
    /// [`GLYPHS_PER_SUBJECT`] of each key.
    pub(crate) fn glyphs<'f>(&'f self, tag: &str, classes: &[String]) -> impl Iterator<Item = &'f Glyph> + 'f {
        let mut keys: Vec<String> = classes.iter().take(MAX_CLASSES).map(|c| format!(".{c}")).collect();
        keys.push(tag.to_owned());
        keys.push(String::new());
        let tag = tag.to_owned();
        let classes = classes.to_vec();
        keys.into_iter()
            .filter_map(|k| self.glyphs.get(&k))
            .flat_map(|v| v.get(v.len().saturating_sub(GLYPHS_PER_SUBJECT)..).unwrap_or(&[]))
            .filter(move |g| g.subject.matches(&tag, &classes))
    }

    /// Whether a rule draws the element.
    pub(crate) fn drawn(&self, tag: &str, classes: &[String]) -> bool {
        self.drawn.contains(tag) || classes.iter().any(|c| self.drawn.contains(&format!(".{c}")))
    }

    /// Whether a script names the element's class or (non-HTML) tag.
    pub(crate) fn script_named(&self, tag: &str, custom: bool, classes: &[String]) -> bool {
        (custom && self.script_words.contains(tag)) || classes.iter().any(|c| self.script_words.contains(c))
    }

    /// Whether a script calls a function the edition's kept scripts name (`<script>ode();</script>` starting the
    /// dictionary's own `o3.js`): it then makes something work through them.
    pub(crate) fn calls_kept(&self, script: &str) -> bool {
        const KEYWORDS: [&str; 12] =
            ["function", "if", "for", "while", "return", "switch", "catch", "typeof", "new", "alert", "eval", "with"];
        let mut name = String::new();
        let mut chars = script.chars().take(4096).peekable();
        while let Some(c) = chars.next() {
            if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
                name.push(c);
                continue;
            }
            let called = c == '(' || (c.is_whitespace() && chars.peek() == Some(&'('));
            let word = std::mem::take(&mut name).to_ascii_lowercase();
            if called && word.len() >= 2 && !KEYWORDS.contains(&word.as_str()) && self.script_words.contains(&word) {
                return true;
            }
        }
        false
    }

    /// Reads the words of the scripts an edition runs.
    pub(crate) fn add_scripts<'a>(&mut self, scripts: impl IntoIterator<Item = &'a str>) {
        for text in scripts {
            for w in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_')) {
                if self.script_words.len() >= SCRIPT_WORDS {
                    return;
                }
                if w.len() >= 2 && w.len() <= 64 && w.starts_with(|c: char| c.is_ascii_alphabetic()) {
                    self.script_words.insert(w.to_ascii_lowercase());
                }
            }
        }
    }

    /// Reads which element wraps an edition's entries: the first element of each sampled entry, the one the most
    /// entries start with when it is at least half of them, kept when a plain rule hides it.
    pub(crate) fn find_wrapper<'e>(&mut self, entries: impl IntoIterator<Item = &'e str>) {
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        let mut n = 0usize;
        for entry in entries {
            n += 1;
            let end = (0..=entry.len().min(WRAPPER_BYTES)).rev().find(|&i| entry.is_char_boundary(i)).unwrap_or(0);
            if let Some(subjects) = first_element(entry.get(..end).unwrap_or("")) {
                for s in subjects {
                    *seen.entry(s).or_default() += 1;
                }
            }
        }
        for (subject, count) in seen {
            if count * 2 < n || count == 0 {
                continue;
            }
            let hidden = if let Some(class) = subject.strip_prefix('.') {
                self.by_class.get(class).is_some_and(|v| {
                    v.iter().any(|s| s.classes.len() == 1 && s.tag.is_none() && s.props.none == Some(true))
                })
            } else {
                self.by_tag.get(&subject).is_some_and(|p| p.none == Some(true))
            };
            if hidden {
                // Shown (S9): the roles read it as the reader will see it.
                if let Some(class) = subject.strip_prefix('.') {
                    for s in self.by_class.get_mut(class).into_iter().flatten() {
                        if s.classes.len() == 1 && s.tag.is_none() {
                            s.props.none = None;
                        }
                    }
                } else if let Some(p) = self.by_tag.get_mut(&subject) {
                    p.none = None;
                }
                self.revealed.insert(subject);
            }
        }
    }

    /// Whether `selector` is a revealed wrapper written plainly (`cb13`, `.entry`).
    pub(crate) fn reveals(&self, selector: &str) -> bool {
        if self.revealed.is_empty() {
            return false;
        }
        let s = selector.trim().to_ascii_lowercase();
        !s.contains([',', ' ', ':', '[', '>', '+', '~']) && self.revealed.contains(&s)
    }
}

/// The symbol a rule's `content` draws first, if it draws one.
fn drawn_symbol(decls: &[(String, String)]) -> Option<char> {
    let content = decls.iter().rev().find(|(n, _)| n.eq_ignore_ascii_case("content")).map(|(_, v)| v)?;
    let text = crate::rewrite::unescaped(content);
    let quoted = text.split(['"', '\'']).skip(1).step_by(2).collect::<String>();
    quoted.chars().find(|c| crate::symbols::symbol(*c)).or_else(|| counter_bullet(&text))
}

/// The bullet a list counter draws as its glyph (`counter(n, square)`; MWU's "Synonyms:"): disc, circle or square.
/// A numbering style is no bullet.
fn counter_bullet(content: &str) -> Option<char> {
    let lower = content.to_ascii_lowercase();
    let at = lower.find("counter")?;
    let args = lower.get(at..)?.split_once('(')?.1.split_once(')')?.0;
    match args.rsplit(',').next()?.trim() {
        "disc" => Some('•'),
        "circle" => Some('◦'),
        "square" => Some('▪'),
        _ => None,
    }
}

/// A compound as a glyph rule reads it: its element and classes, attribute tests ignored; `None` when it names a
/// state (`:hover`) or an id.
fn compound(text: &str) -> Option<Compound> {
    let mut plain = String::new();
    let mut depth = 0u32;
    for c in text.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => plain.push(c),
            _ => {}
        }
    }
    let mut pieces = plain.split(':');
    let head = pieces.next().unwrap_or("");
    for piece in pieces {
        let name = piece.split('(').next().unwrap_or("");
        if !matches!(
            name,
            "" | "before"
                | "after"
                | "first-child"
                | "last-child"
                | "not"
                | "first-of-type"
                | "last-of-type"
                | "nth-child"
                | "nth-of-type"
                | "lang"
                | "only-child"
        ) {
            return None;
        }
    }
    let mut tag = None;
    let mut classes = Vec::new();
    for (i, part) in head.split('.').enumerate() {
        let (name, id) = part.split_once('#').unwrap_or((part, ""));
        if !id.is_empty() {
            return None;
        }
        if i == 0 {
            if !name.is_empty() && name != "*" {
                tag = Some(name.to_owned());
            }
        } else if !name.is_empty() {
            classes.push(name.to_owned());
        }
    }
    (classes.len() <= MAX_CLASSES).then_some(Compound { tag, classes })
}

/// The first element of an entry (past `link`, `script`, `style`, `meta` and the page's tags): its element and each
/// of its classes, as `tag` and `.class`.
fn first_element(text: &str) -> Option<Vec<String>> {
    const SKIP: [&str; 9] = ["link", "script", "style", "meta", "html", "head", "body", "br", "title"];
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        let from = rest.get(at + 1..)?;
        let end = from.find('>')?;
        let tag = from.get(..end)?;
        rest = from.get(end + 1..)?;
        if tag.starts_with(['/', '!', '?']) {
            continue;
        }
        let name_len = tag.find(|c: char| c.is_ascii_whitespace() || c == '/').unwrap_or(tag.len());
        let name = tag.get(..name_len)?.to_ascii_lowercase();
        if name.is_empty() || SKIP.contains(&name.as_str()) {
            continue;
        }
        let mut out = vec![name];
        if let Some(classes) = crate::phon::attribute_of(tag, "class") {
            out.extend(classes.split_ascii_whitespace().map(|c| format!(".{}", c.to_ascii_lowercase())));
        }
        return Some(out);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(selector: &str, decls: &[(&str, &str)]) -> Rule {
        Rule {
            selector: selector.into(),
            face: false,
            page: false,
            grouped: false,
            decls: decls.iter().map(|(n, v)| ((*n).into(), (*v).into())).collect(),
        }
    }

    #[test]
    fn only_a_plain_rule_hides() {
        let f = Facts::of_rules(&[
            rule(".a", &[("display", "none")]),
            rule(".open .b", &[("display", "none")]),
            rule(".c:hover", &[("font-weight", "bold")]),
            rule("i.d", &[("font-weight", "bold")]),
        ]);
        assert_eq!(f.props("span", &["a".into()]).none, Some(true));
        assert_eq!(f.props("span", &["b".into()]).none, None);
        assert_eq!(f.props("span", &["c".into()]).bold, None, "a state is not the element's");
        assert_eq!(f.props("span", &["d".into()]).bold, None, "the rule names another element");
        assert_eq!(f.props("i", &["d".into()]).bold, Some(true));
        let mut media = rule(".m", &[("display", "none")]);
        media.grouped = true;
        assert_eq!(
            Facts::of_rules(&[media]).props("span", &["m".into()]).none,
            None,
            "a media query's rule may not hold"
        );
    }

    #[test]
    fn a_pseudo_element_draws() {
        let f = Facts::of_rules(&[rule(".dot::before", &[("content", "'●'")]), rule("x-a", &[("width", "1em")])]);
        assert!(f.drawn("span", &["dot".into()]));
        assert!(f.drawn("x-a", &[]));
        assert!(!f.drawn("span", &["x".into()]));
    }

    #[test]
    fn the_wrapper_hidden_until_a_script_runs_is_found() {
        let mut f = Facts::of_rules(&[rule("w", &[("display", "none")])]);
        f.find_wrapper(["<link rel=stylesheet href=a.css><w hw=a><b>a</b></w>", "<w><b>b</b></w>", "<p>c</p>"]);
        assert!(f.reveals("w"));
        assert_eq!(f.props("w", &[]).none, None, "the roles see it shown");
        assert!(!f.reveals("w .x"));
        let mut g = Facts::of_rules(&[rule("w", &[("color", "red")])]);
        g.find_wrapper(["<w>a</w>"]);
        assert!(!g.reveals("w"), "not hidden: nothing to reveal");
    }
}
