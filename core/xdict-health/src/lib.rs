//! **The import health check** (plan-macos-v1 WI-12): what an edition carries that a reader would see as damage,
//! counted per class with up to three examples each, in one pass over its records in file order.
//!
//! The classes are the census's (`dev-docs/measurements/2026-10-15-mdx-health/`, whose scanner this is, made fit for
//! the core): the same names, the same rules, with three changes the owner decided on 2026-10-15 —
//! - a link to a key the edition lacks at tier 1 is tried at tier 2 (lookup's folding) before it counts as broken,
//!   and counted as `link.entry_found_by_folding` when that finds it;
//! - Oxford's lookup schemes (`d:`, `x:`, `xi:`, `xp:`), which the rewriter already makes entry links, are checked
//!   as links, not as files;
//! - `text.repaired` counts what the render repairs in the text (`xdict_entry::repairs`).
//!
//! Nothing here holds the whole edition: a record is checked and dropped. What grows with the edition is bounded —
//! redirects kept for the chain check ([`MAX_REDIRECTS`]), names of missing files ([`MAX_NAMES`]), the key cache
//! ([`MAX_CACHED_KEYS`]) — and every check is linear in the record (`tests/linear.rs`).

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::hash::{Hash, Hasher};

use xdict_mdx::{Budget, File, Kept};

/// The checker's version: raised by any change to what it counts, so a cached report of an older one is checked again.
pub const VERSION: u32 = 1;
/// Examples kept per class, and the characters each shows around its place.
pub const EXAMPLES: usize = 3;
const WINDOW: usize = 60;
/// A record larger than this is `record.huge_over_1mib`.
const HUGE: usize = 1 << 20;
/// Records read between two progress reports.
const CHUNK: usize = 4096;
/// Redirect hops followed before a chain is `redirect.chain_too_deep`.
const CHAIN: usize = 5;
/// Redirects kept for the chain check; past it, each is `redirect.unchecked`.
pub const MAX_REDIRECTS: usize = 1 << 20;
/// Distinct missing stylesheets and scripts named; past it, each is counted under `""`.
pub const MAX_NAMES: usize = 1024;
/// Spellings of one folded key held at once for the duplicate check.
const MAX_SPELLINGS: usize = 64;
/// Keys whose presence is remembered.
pub const MAX_CACHED_KEYS: usize = 1 << 17;

/// One class: how often it was met, and the first few places.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Class {
    pub count: u64,
    /// The record's key and up to 120 characters around the place.
    pub examples: Vec<(String, String)>,
}

/// What the check found in one edition.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    /// Records checked: all of them, since a check that stops is an error, never a partial report.
    pub records: u64,
    pub classes: BTreeMap<String, Class>,
    /// Stylesheets and scripts the entries link but the package lacks, by file name (lower case), with the number of
    /// references to each.
    pub missing_files: BTreeMap<String, u64>,
}

impl Report {
    fn hit(&mut self, class: &str, key: &str, text: &str, at: usize) {
        let entry = self.classes.entry(class.to_owned()).or_default();
        entry.count += 1;
        if entry.examples.len() < EXAMPLES {
            entry.examples.push((key.to_owned(), window(text, at)));
        }
    }

    fn add(&mut self, class: &str, n: u64) {
        if n > 0 {
            self.classes.entry(class.to_owned()).or_default().count += n;
        }
    }

    /// How often `class` was met.
    pub fn count(&self, class: &str) -> u64 {
        self.classes.get(class).map_or(0, |c| c.count)
    }
}

/// Why a check gave no report.
#[derive(Debug)]
pub enum Stop {
    /// The progress callback answered `false`.
    Cancelled,
    Read(xdict_mdx::Error),
}

/// Checks every record of `file`, in file order. `has_resource` says whether the package holds a path as an entry
/// writes it (a sidecar or a volume's key); `progress` is told records done of all after each chunk, and answering
/// `false` stops the check.
pub fn check(
    file: &File,
    has_resource: &dyn Fn(&str) -> bool,
    progress: &mut dyn FnMut(u64, u64) -> bool,
) -> Result<Report, Stop> {
    let total = file.len();
    let mut scan = Scan { file, has_resource, found: HashMap::new(), report: Report::default() };
    let mut redirects: Vec<(usize, String, String)> = Vec::new();
    let mut run = Run::default();
    let mut kept = Kept::default();
    let mut from = 0usize;
    while from < total {
        let to = from.saturating_add(CHUNK).min(total);
        let keys: Vec<usize> = (from..to).collect();
        let mut budget = Budget::new(u64::MAX, usize::MAX);
        file.for_each_record_kept(&keys, &mut budget, &mut kept, |i, record| {
            let text = String::from_utf8_lossy(&record.data);
            scan.report.records += 1;
            run.add(&mut scan.report, &record.key, &record.data);
            if let Some(target) = redirect_target(&text) {
                if redirects.len() < MAX_REDIRECTS {
                    redirects.push((i, record.key.clone(), target.to_owned()));
                } else {
                    scan.report.add("redirect.unchecked", 1);
                }
            }
            scan.record(&record.key, &text, record.lossy);
            Ok(())
        })
        .map_err(Stop::Read)?;
        from = to;
        if !progress(from as u64, total as u64) {
            return Err(Stop::Cancelled);
        }
    }
    run.flush(&mut scan.report);
    let mut report = scan.report;
    chains(file, &redirects, &mut report).map_err(Stop::Read)?;
    Ok(report)
}

/// Records sharing one key: the same record stored twice, or homographs. A file sorts by its own folding, so one key's
/// records may lie apart with another case or spelling of it between them (`bear`, `Bear`, `bear`); they lie within one
/// run of keys equal once lower-cased and stripped to letters and digits, which is what is held.
#[derive(Default)]
struct Run {
    folded: String,
    keys: Vec<(String, Vec<u64>)>,
}

fn folded(key: &str) -> String {
    let f: String = key.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect();
    if f.is_empty() { key.to_owned() } else { f }
}

impl Run {
    fn add(&mut self, report: &mut Report, key: &str, data: &[u8]) {
        let fold = folded(key);
        if fold != self.folded {
            self.flush(report);
            self.folded = fold;
        }
        let mut hasher = DefaultHasher::new();
        data.hash(&mut hasher);
        let digest = hasher.finish();
        match self.keys.iter_mut().find(|(k, _)| k == key) {
            Some((_, digests)) => digests.push(digest),
            None => {
                // A run of more spellings than this is a hostile file's, not a dictionary's: it is cut, so the search
                // above stays bounded, at the cost of a duplicate across the cut.
                if self.keys.len() >= MAX_SPELLINGS {
                    self.flush(report);
                }
                self.keys.push((key.to_owned(), vec![digest]));
            }
        }
    }

    fn flush(&mut self, report: &mut Report) {
        for (key, digests) in self.keys.drain(..) {
            if digests.len() > 1 {
                let first = digests.first().copied();
                let class = if digests.iter().all(|d| Some(*d) == first) {
                    "key.duplicate_identical_records"
                } else {
                    "key.duplicate_differing_records"
                };
                report.hit(class, &key, &key, 0);
            }
        }
    }
}

/// Every redirect's target followed: missing, the redirect itself, a loop, too deep, or a chain that ends in an entry.
fn chains(file: &File, redirects: &[(usize, String, String)], report: &mut Report) -> Result<(), xdict_mdx::Error> {
    let targets: HashMap<usize, &str> = redirects.iter().map(|(i, _, t)| (*i, t.as_str())).collect();
    for (i, key, target) in redirects {
        let shown = format!("{key} -> @@@LINK={target}");
        if target.is_empty() {
            report.hit("redirect.empty_target", key, &shown, 0);
            continue;
        }
        let mut seen = HashSet::from([*i]);
        let mut current = target.clone();
        let mut depth = 0;
        loop {
            let found = file.find(&current)?;
            if found.is_empty() {
                let class = if depth == 0 { "redirect.missing_target" } else { "redirect.chain_ends_missing" };
                report.hit(class, key, &shown, 0);
                break;
            }
            // A key found under the file's folding rules may be the redirect's own: only the others count.
            let found: Vec<usize> = found.into_iter().filter(|f| !seen.contains(f)).collect();
            if found.is_empty() {
                let class = if depth == 0 { "redirect.to_itself" } else { "redirect.loop" };
                report.hit(class, key, &shown, 0);
                break;
            }
            // Followed only when every target is itself a redirect.
            let mut next = None;
            let mut all_redirects = true;
            for f in found {
                seen.insert(f);
                match targets.get(&f) {
                    Some(t) => next = Some((*t).to_owned()),
                    None => all_redirects = false,
                }
            }
            if !all_redirects {
                if depth > 0 {
                    report.add("redirect.chained_ok", 1);
                }
                break;
            }
            depth += 1;
            if depth >= CHAIN {
                report.hit("redirect.chain_too_deep", key, &shown, 0);
                break;
            }
            current = next.unwrap_or_default();
        }
    }
    Ok(())
}

/// 120 characters around byte `at`, on character boundaries, line breaks shown as `⏎`.
fn window(text: &str, at: usize) -> String {
    let at = at.min(text.len());
    let mut start = at.saturating_sub(WINDOW);
    while !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = at.saturating_add(WINDOW).min(text.len());
    while !text.is_char_boundary(end) {
        end += 1;
    }
    text.get(start..end).unwrap_or("").chars().map(|c| if c == '\n' || c == '\r' { '⏎' } else { c }).collect()
}

const ENTITIES: &[&str] = &[
    "amp", "lt", "gt", "quot", "apos", "nbsp", "copy", "reg", "trade", "mdash", "ndash", "hellip", "lsquo", "rsquo",
    "ldquo", "rdquo", "laquo", "raquo", "middot", "bull", "deg", "plusmn", "times", "divide", "frac12", "frac14",
    "frac34", "sup1", "sup2", "sup3", "sect", "para", "dagger", "Dagger", "prime", "Prime", "larr", "rarr", "uarr",
    "darr", "harr", "lArr", "rArr", "hArr", "ensp", "emsp", "thinsp", "zwj", "zwnj", "shy", "iexcl", "iquest", "cent",
    "pound", "yen", "euro", "curren", "macr", "acute", "cedil", "uml", "ordf", "ordm", "not", "micro", "infin", "ne",
    "le", "ge", "asymp", "equiv", "minus", "radic", "sum", "prod", "part", "int", "forall", "exist", "empty", "nabla",
    "isin", "notin", "cap", "cup", "sub", "sup", "and", "or", "there4", "loz", "spades", "clubs", "hearts", "diams",
    "permil", "oline", "frasl", "circ", "tilde", "brvbar", "sbquo", "bdquo", "lsaquo", "rsaquo", "fnof", "image",
    "weierp", "real", "alefsym", "crarr", "lowast", "prop", "ang", "sim", "cong", "nsub", "sube", "supe", "oplus",
    "otimes", "perp", "sdot", "lceil", "rceil", "lfloor", "rfloor", "lang", "rang", "OElig", "oelig", "Scaron",
    "scaron", "Yuml", "szlig", "eth", "ETH", "thorn", "THORN", "AElig", "aelig", "Oslash", "oslash", "Aring", "aring",
    "Ccedil", "ccedil", "Ntilde", "ntilde", "Otilde", "otilde", "Atilde", "atilde",
];

const GREEK: &[&str] = &[
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi",
    "omicron", "pi", "rho", "sigma", "sigmaf", "tau", "upsilon", "phi", "chi", "psi", "omega", "thetasym", "upsih",
    "piv",
];

fn entity_known(name: &str) -> bool {
    if ENTITIES.contains(&name) {
        return true;
    }
    // Accented letters: Aacute, egrave, ocirc, uuml and so on.
    let mut cs = name.chars();
    match cs.next() {
        Some(c) if "AEIOUYaeiouy".contains(c) => matches!(cs.as_str(), "acute" | "grave" | "circ" | "uml"),
        _ => GREEK.contains(&name.to_ascii_lowercase().as_str()),
    }
}

/// Elements whose nesting is checked.
const WATCHED: &[&str] =
    &["b", "i", "u", "a", "table", "div", "span", "font", "sup", "sub", "ul", "ol", "em", "strong", "small", "big"];

/// Tags whose escaped form shown as text is `markup.escaped_tag_as_text`.
const ESCAPED: &[&str] = &[
    "b", "i", "u", "a", "br", "p", "div", "span", "font", "img", "table", "td", "tr", "sup", "sub", "em", "strong",
    "li", "ul", "hr", "link", "script", "style",
];

/// Positions of `pat` in `hay`.
fn all<'a>(hay: &'a str, pat: &'a str) -> impl Iterator<Item = usize> + 'a {
    hay.match_indices(pat).map(|(i, _)| i)
}

/// `s` from byte `at`, or empty.
fn from(s: &str, at: usize) -> &str {
    s.get(at..).unwrap_or("")
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while let Some(&byte) = b.get(i) {
        if byte == b'%'
            && let (Some(h), Some(l)) = (
                b.get(i + 1).and_then(|c| char::from(*c).to_digit(16)),
                b.get(i + 2).and_then(|c| char::from(*c).to_digit(16)),
            )
        {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(byte);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A resource path as an MDD key: lower case, backslashes, one leading backslash.
pub fn resource_key(path: &str) -> String {
    let p = path.split(['?', '#']).next().unwrap_or("");
    let p = percent_decode(p).replace('/', "\\").to_lowercase();
    let p = p.trim_start_matches(".\\").trim_start_matches('\\');
    format!("\\{p}")
}

/// The target of a record that is `@@@LINK=…`.
fn redirect_target(text: &str) -> Option<&str> {
    let t = text.trim_start_matches('\u{feff}').trim_start();
    let rest = t.strip_prefix("@@@LINK=")?;
    Some(rest.split(['\r', '\n', '\0']).next().unwrap_or("").trim())
}

/// Sorted, non-overlapping byte ranges, asked about at positions that never decrease: linear in all.
struct Ranges {
    ranges: Vec<(usize, usize)>,
    next: usize,
}

impl Ranges {
    fn new(mut ranges: Vec<(usize, usize)>) -> Self {
        ranges.sort_unstable();
        let mut merged: Vec<(usize, usize)> = Vec::with_capacity(ranges.len());
        for (s, e) in ranges {
            match merged.last_mut() {
                // Only overlapping ranges merge: touching ones stay apart, so a strict question is answered exactly.
                Some(last) if s < last.1 => last.1 = last.1.max(e),
                _ => merged.push((s, e)),
            }
        }
        Self { ranges: merged, next: 0 }
    }

    /// Whether `i` lies in a range: `s < i < e` when `strict`, else `s <= i < e`.
    fn contains(&mut self, i: usize, strict: bool) -> bool {
        while self.ranges.get(self.next).is_some_and(|&(_, e)| e <= i) {
            self.next += 1;
        }
        self.ranges.get(self.next).is_some_and(|&(s, e)| if strict { s < i && i < e } else { s <= i && i < e })
    }
}

struct Scan<'a> {
    file: &'a File,
    has_resource: &'a dyn Fn(&str) -> bool,
    found: HashMap<String, Found>,
    report: Report,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Found {
    Tier1,
    Folded,
    Missing,
}

impl Scan<'_> {
    /// Whether a link's key is in the edition, by the very matching a click uses (`xdict_lookup::matches` in link
    /// mode): at tier 1, or failing that at tier 2.
    fn key(&mut self, key: &str) -> Found {
        if let Some(&f) = self.found.get(key) {
            return f;
        }
        let matched = xdict_lookup::matches(self.file, key, xdict_lookup::Mode::Link).ok();
        let f = match matched.and_then(|m| m.into_iter().next()) {
            None => Found::Missing,
            Some((_, xdict_lookup::How::Unmarked)) => Found::Folded,
            Some(_) => Found::Tier1,
        };
        if self.found.len() < MAX_CACHED_KEYS {
            self.found.insert(key.to_owned(), f);
        }
        f
    }

    fn resource(&self, path: &str) -> bool {
        (self.has_resource)(path)
    }

    /// A link to a key: broken only when neither tier finds it nor is it a file of the package.
    fn link(&mut self, class: &str, key: &str, text: &str, at: usize, target: &str) {
        match self.key(target) {
            Found::Tier1 => {}
            Found::Folded => self.report.add("link.entry_found_by_folding", 1),
            Found::Missing if self.resource(target) => {}
            Found::Missing => self.report.hit(class, key, text, at),
        }
    }

    /// One URL written in the record, at byte `at`, in an attribute of an element of `kind`.
    fn url(&mut self, key: &str, text: &str, at: usize, url: &str, kind: &str) {
        let url = url.trim();
        let low = url.to_ascii_lowercase();
        if url.is_empty() || low.starts_with('#') {
            return;
        }
        for (scheme, class) in [("entry://", "link.entry_missing_key"), ("bword://", "link.bword_missing_key")] {
            if let Some(rest) = low.strip_prefix(scheme) {
                let target = percent_decode(from(url, scheme.len()).split('#').next().unwrap_or(""));
                if !rest.starts_with('#') && !target.is_empty() {
                    self.link(class, key, text, at, &target);
                }
                return;
            }
        }
        // Oxford's lookup schemes, which the rewriter makes entry links (`xdict_entry`'s `is_oxford_lookup`).
        for scheme in ["d:", "x:", "xi:", "xp:"] {
            if low.starts_with(scheme) {
                let target = from(url, scheme.len()).to_owned();
                if !target.is_empty() {
                    self.link("link.entry_missing_key", key, text, at, &target);
                }
                return;
            }
        }
        if low.starts_with("sound://") {
            if !self.resource(from(url, 8)) {
                self.report.hit("link.sound_missing", key, text, at);
            }
            return;
        }
        if ["http:", "https:", "data:", "mailto:", "javascript:", "about:", "file:", "//"]
            .iter()
            .any(|s| low.starts_with(s))
        {
            if low.starts_with("http") || low.starts_with("//") {
                self.report.hit("link.remote_url", key, text, at);
            }
            if low.starts_with("javascript:") {
                self.report.hit("script.javascript_url", key, text, at);
            }
            return;
        }
        let scheme_len = low.find(':').unwrap_or(0);
        let scheme = low.get(..scheme_len).unwrap_or("");
        if low.contains("://") || (scheme_len > 1 && scheme.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')) {
            self.report.hit("link.unknown_scheme", key, text, at);
            return;
        }
        if !self.resource(url) {
            self.report.hit(&format!("link.{kind}_missing_resource"), key, text, at);
            if matches!(kind, "stylesheet" | "script") {
                let name = resource_key(url).rsplit('\\').next().unwrap_or("").to_owned();
                let len = self.report.missing_files.len();
                let slot =
                    if len < MAX_NAMES || self.report.missing_files.contains_key(&name) { name } else { String::new() };
                *self.report.missing_files.entry(slot).or_default() += 1;
            }
        }
    }

    fn record(&mut self, key: &str, text: &str, lossy: u64) {
        self.key_checks(key);
        if text.is_empty() {
            self.report.hit("record.empty", key, text, 0);
            return;
        }
        if text.trim().is_empty() {
            self.report.hit("record.whitespace_only", key, text, 0);
            return;
        }
        if text.len() > HUGE {
            self.report.hit("record.huge_over_1mib", key, text, 0);
        }
        if lossy > 0 {
            self.report.hit("text.undecodable_bytes", key, text, text.find('\u{fffd}').unwrap_or(0));
        }
        if redirect_target(text).is_some() {
            return;
        }
        if let Some(at) = text.find("@@@LINK=") {
            self.report.hit("record.redirect_not_at_start", key, text, at);
        }
        let low = text.to_ascii_lowercase();
        let blocked = self.comments(key, text, &low);
        self.markup(key, text, &low, blocked);
        self.characters(key, text, lossy);
        self.entities(key, text);
    }

    fn key_checks(&mut self, key: &str) {
        if key.trim() != key {
            self.report.hit("key.edge_whitespace", key, key, 0);
        }
        if key.chars().any(|ch| {
            matches!(ch, '\u{200b}'..='\u{200f}' | '\u{2060}' | '\u{feff}' | '\u{00ad}' | '\u{202a}'..='\u{202e}')
                || ch.is_control()
        }) {
            self.report.hit("key.invisible_or_control", key, &key.escape_default().to_string(), 0);
        }
        let kl = key.to_ascii_lowercase();
        if kl.contains("</") || kl.contains("<b>") || kl.contains("<i>") || kl.contains("<span") || kl.contains("<br") {
            self.report.hit("key.html_in_key", key, key, 0);
        } else if key.contains("&amp;") || key.contains("&#") || key.contains("&lt;") || key.contains("&nbsp;") {
            self.report.hit("key.entity_in_key", key, key, 0);
        }
        if key.contains('\u{fffd}') {
            self.report.hit("key.replacement_char", key, key, 0);
        }
    }

    /// Comment defects; answers the byte ranges of closed comments, scripts and styles, which the markup check skips.
    fn comments(&mut self, key: &str, text: &str, low: &str) -> Ranges {
        let mut blocked = Vec::new();
        let mut styles = Vec::new();
        for (open, close, unclosed) in
            [("<script", "</script", "script.unclosed"), ("<style", "</style", "style.unclosed")]
        {
            // Each open runs to the first close after it; opens inside that range end at the same close.
            let mut at = 0;
            while let Some(p) = from(low, at).find(open) {
                let i = at + p;
                match from(low, i).find(close) {
                    Some(e) => {
                        styles.push((i, i + e));
                        at = i + e;
                    }
                    None => {
                        for o in all(from(low, i), open) {
                            self.report.hit(unclosed, key, text, i + o);
                        }
                        styles.push((i, low.len()));
                        break;
                    }
                }
            }
        }
        if let Some(at) = low.find("<script") {
            self.report.hit("script.inline_script", key, text, at);
        }
        blocked.extend_from_slice(&styles);
        let mut in_style = Ranges::new(styles);
        let mut i = 0;
        let (mut next_open, mut next_close): (Option<usize>, Option<usize>) = (None, None);
        while i < text.len() {
            if next_open.is_none_or(|o| o < i) {
                next_open = from(text, i).find("<!--").map(|p| p + i);
            }
            if next_close.is_none_or(|c| c < i) {
                next_close = from(text, i).find("-->").map(|p| p + i);
            }
            match (next_open, next_close) {
                (None, None) => break,
                (o, Some(cl)) if o.is_none_or(|o| cl < o) => {
                    if !in_style.contains(cl, false) && !text.get(..cl).unwrap_or("").ends_with('<') {
                        self.report.hit("comment.stray_close", key, text, cl);
                    }
                    i = cl + 3;
                }
                (Some(o), _) => match from(text, o + 4).find("-->") {
                    None => {
                        let class =
                            if text.len() - o > 200 { "comment.unclosed_swallows" } else { "comment.unclosed_short" };
                        self.report.hit(class, key, text, o);
                        blocked.push((o, text.len()));
                        break;
                    }
                    Some(e) => {
                        let end = o + 4 + e + 3;
                        let body = text.get(o + 4..o + 4 + e).unwrap_or("");
                        if body.contains("<!--") {
                            self.report.hit("comment.nested", key, text, o);
                        }
                        if !in_style.contains(o, false) && css_as_text(body).is_some() {
                            self.report.hit("style.css_in_comment", key, text, o);
                        }
                        blocked.push((o, end));
                        i = end;
                    }
                },
                _ => break,
            }
        }
        for at in all(text, "<--") {
            self.report.hit("comment.malformed_open_lt_dashes", key, text, at);
        }
        for at in all(text, "<!-") {
            if !from(text, at).starts_with("<!--") {
                self.report.hit("comment.malformed_open_bang_dash", key, text, at);
            }
        }
        for at in all(text, "--!>") {
            self.report.hit("comment.malformed_close_bang", key, text, at);
        }
        Ranges::new(blocked)
    }

    fn markup(&mut self, key: &str, text: &str, low: &str, mut blocked: Ranges) {
        let b = low.as_bytes();
        // Open watched elements, and how many of each, so a close with none open is known at once.
        let mut stack: Vec<(&str, usize)> = Vec::new();
        let mut open: HashMap<&str, usize> = HashMap::new();
        let mut i = 0;
        let mut visible_from = 0;
        let mut visible = String::new();
        let mut repaired = 0u64;
        while let Some(p) = from(low, i).find('<') {
            let at = i + p;
            let skipped = blocked.contains(at, true);
            if !skipped {
                let run = text.get(visible_from..at).unwrap_or("");
                repaired += xdict_entry::repairs(run, visible_from == 0);
                visible.push_str(run);
            }
            let mut j = at + 1;
            let closing = b.get(j) == Some(&b'/');
            if closing {
                j += 1;
            }
            let ns = j;
            while b.get(j).is_some_and(u8::is_ascii_alphanumeric) {
                j += 1;
            }
            let name = low.get(ns..j).unwrap_or("");
            let end = from(low, j).find('>').map_or(low.len(), |e| j + e + 1);
            i = end.max(at + 1);
            visible_from = i;
            if skipped || name.is_empty() || !b.get(ns).is_some_and(u8::is_ascii_alphabetic) {
                continue;
            }
            if !closing {
                self.attributes(key, text, low.get(at..end).unwrap_or(""), at);
            }
            let Some(&watched) = WATCHED.iter().find(|w| **w == name) else { continue };
            if !closing {
                if !low.get(at..end).unwrap_or("").ends_with("/>") {
                    stack.push((watched, at));
                    *open.entry(watched).or_default() += 1;
                }
            } else if open.get(watched).is_some_and(|n| *n > 0) {
                let pos = stack.iter().rposition(|(n, _)| *n == watched).unwrap_or(0);
                if pos + 1 != stack.len() {
                    self.report.hit("markup.misnested", key, text, at);
                }
                for (n, _) in stack.drain(pos..) {
                    if let Some(c) = open.get_mut(n) {
                        *c = c.saturating_sub(1);
                    }
                }
            } else {
                self.report.hit(&format!("markup.stray_close.{watched}"), key, text, at);
            }
        }
        if visible_from < text.len() {
            let run = from(text, visible_from);
            repaired += xdict_entry::repairs(run, visible_from == 0);
            visible.push_str(run);
        }
        self.report.add("text.repaired", repaired);
        for (name, at) in stack {
            self.report.hit(&format!("markup.unclosed.{name}"), key, text, at);
        }
        for at in all(low, "&lt;") {
            let r = from(low, at + 4);
            let r = r.strip_prefix('/').unwrap_or(r);
            let n = r.bytes().take_while(u8::is_ascii_alphabetic).count();
            let after = from(r, n);
            if n > 0
                && n < 10
                && (after.starts_with("&gt;") || after.starts_with(' ') || after.starts_with('/'))
                && ESCAPED.contains(&r.get(..n).unwrap_or(""))
            {
                self.report.hit("markup.escaped_tag_as_text", key, text, at);
            }
        }
        if let Some(at) = css_as_text(&visible) {
            self.report.hit("style.css_as_visible_text", key, &visible, at);
        }
        for (pat, class) in [("\\n", "text.literal_backslash_n"), ("\\t", "text.literal_backslash_t")] {
            for at in all(&visible, pat) {
                let next = from(&visible, at + 2).chars().next();
                let prev_bs = visible.get(..at).unwrap_or("").ends_with('\\');
                if !prev_bs && next.is_none_or(|n| !n.is_ascii_lowercase()) {
                    self.report.hit(class, key, &visible, at);
                }
            }
        }
    }

    /// The `src` and `href` of one start tag (`tag`, lower case, at `at` in `text`), and its handlers.
    fn attributes(&mut self, key: &str, text: &str, tag: &str, at: usize) {
        let name_end = tag.find(|ch: char| ch.is_whitespace() || ch == '>' || ch == '/').unwrap_or(tag.len());
        let kind = match tag.get(1..name_end).unwrap_or("") {
            "img" => "img",
            "link" => "stylesheet",
            "script" => "script",
            "a" => "a",
            "audio" | "source" | "embed" => "media",
            _ => "other",
        };
        for attr in ["src", "href"] {
            let mut next = 0;
            while let Some(p) = from(tag, next).find(attr) {
                let s = next + p;
                next = s + attr.len();
                let before_ok = s > 0 && tag.as_bytes().get(s - 1).is_some_and(u8::is_ascii_whitespace);
                let rest = from(tag, next).trim_start();
                if !before_ok || !rest.starts_with('=') {
                    continue;
                }
                let rest = from(rest, 1).trim_start();
                let raw = text.get(at + (tag.len() - rest.len())..at + tag.len()).unwrap_or("");
                let value = match raw.chars().next() {
                    Some(q @ ('"' | '\'')) => from(raw, 1).split(q).next().unwrap_or(""),
                    _ => raw.split(|ch: char| ch.is_whitespace() || ch == '>').next().unwrap_or(""),
                };
                self.url(key, text, at, value, kind);
            }
        }
        if tag.contains(" on")
            && [" onclick=", " onload=", " onmouseover=", " onerror="].iter().any(|e| tag.contains(e))
        {
            self.report.hit("script.inline_handler", key, text, at);
        }
    }

    fn characters(&mut self, key: &str, text: &str, lossy: u64) {
        let mut prev = '\0';
        for (i, ch) in text.char_indices() {
            match ch {
                '\0' => self.report.hit("text.nul", key, text, i),
                '\t' | '\n' | '\r' => {}
                '\u{feff}' => {
                    self.report.hit(if i == 0 { "text.bom_at_start" } else { "text.bom_inside" }, key, text, i);
                }
                '\u{fffd}' if lossy == 0 => self.report.hit("text.replacement_char_stored", key, text, i),
                c0 if (c0 as u32) < 0x20 || c0 == '\u{7f}' => self.report.hit("text.control_c0", key, text, i),
                '\u{80}'..='\u{9f}' => self.report.hit("text.control_c1", key, text, i),
                _ => {}
            }
            let c1 = ('\u{80}'..='\u{9f}').contains(&ch);
            let cp1252 = "€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ".contains(ch);
            let latin_tail = ('\u{80}'..='\u{bf}').contains(&ch) || cp1252;
            if (matches!(prev, 'Ã' | 'Â') && latin_tail) || (matches!(prev, 'â'..='é') && (c1 || ch == '€')) {
                self.report.hit("text.mojibake_double_utf8", key, text, i);
            }
            prev = ch;
        }
    }

    fn entities(&mut self, key: &str, text: &str) {
        let b = text.as_bytes();
        for at in all(text, "&") {
            let mut j = at + 1;
            while j - at < 34 && b.get(j).is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'#') {
                j += 1;
            }
            let name = text.get(at + 1..j).unwrap_or("");
            if name.is_empty() {
                continue;
            }
            let terminated = b.get(j) == Some(&b';');
            if let Some(num) = name.strip_prefix('#') {
                let v = match num.strip_prefix(['x', 'X']) {
                    Some(h) => u32::from_str_radix(h, 16).ok(),
                    None => num.parse::<u32>().ok(),
                };
                match v {
                    _ if !terminated => self.report.hit("entity.numeric_unterminated", key, text, at),
                    Some(v) if v != 0 && char::from_u32(v).is_some() => {}
                    _ => self.report.hit("entity.numeric_invalid", key, text, at),
                }
            } else if terminated {
                if !entity_known(name) {
                    self.report.hit("entity.unknown_named", key, text, at);
                }
            } else if entity_known(name) {
                self.report.hit("entity.named_unterminated", key, text, at);
            }
        }
    }
}

/// Where `s` holds something shaped like a CSS rule: a selector, `{`, `property:`, `}` within 400 bytes. Each `{`
/// looks no further than that, so the search is linear.
fn css_as_text(s: &str) -> Option<usize> {
    let last_close = s.rfind('}')?;
    let mut next = 0;
    while let Some(p) = from(s, next).find('{') {
        let o = next + p;
        next = o + 1;
        if o > last_close {
            return None;
        }
        let mut limit = (o + 400).min(s.len());
        while !s.is_char_boundary(limit) {
            limit -= 1;
        }
        let Some(e) = s.get(o..limit).and_then(|w| w.find('}')) else { continue };
        let inner = s.get(o + 1..o + e).unwrap_or("");
        if inner.contains(':') && inner.contains(';') {
            let prop = inner.trim_start().split(':').next().unwrap_or("");
            if !prop.is_empty() && prop.len() < 30 && prop.bytes().all(|b| b.is_ascii_lowercase() || b == b'-') {
                return Some(o);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    /// Records of one key may lie apart in file order, another case of it between them (`bear`, `Bear`, `bear`): a
    /// file sorts by its own folding. They are still one key's records.
    #[test]
    fn duplicates_are_found_across_a_case_variant_between_them() {
        let mut report = Report::default();
        let mut run = Run::default();
        for (key, data) in
            [("bear", "an animal"), ("Bear", "a name"), ("bear", "an animal"), ("bears", "x"), ("c", "1")]
        {
            run.add(&mut report, key, data.as_bytes());
        }
        run.flush(&mut report);
        assert_eq!(report.count("key.duplicate_identical_records"), 1);
        assert_eq!(report.count("key.duplicate_differing_records"), 0);
    }
}
