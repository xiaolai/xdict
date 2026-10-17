//! ADR-0010: one XDict reading style for every dictionary, as `dev-docs/reading-style.md` specifies it. While the
//! rewriter copies a dictionary's CSS (a sidecar sheet, a `<style>` block, a `style=""`) it also normalizes it: values
//! become XDict's tokens ([`TOKENS`], §1), what the frame owns is dropped, and the rest is kept. The rules are a table,
//! property → action ([`RULES`]); presentational HTML (R22), tables (R10) and transcriptions are the HTML pass's.
//!
//! Only a rule's own declarations are touched, read off the rewriter's tokenizer: its structure (`{`, `;`, `}`) is
//! seen outside strings, comments and parentheses, and each finished block is normalized once, in place, so the
//! cost is linear in the sheet. Which fonts are kept and the base size are decided once per edition from all of
//! its sheets ([`Style::of_sheets`]), never from whichever entry is opened first.

use std::collections::{BTreeMap, BTreeSet};

use crate::Exceeded;
use crate::colour::{self, Role};

/// The version of these rules. Raised whenever what they write changes, so anything that keeps rewritten
/// output knows it is stale.
pub const STYLE: u32 = 12;

/// Every token the core may write, by `dev-docs/reading-style.md` §1's names: the frame defines exactly these, and a
/// name not among them would fall back silently. The one list; a test holds every output to it.
pub const TOKENS: [&str; 52] = [
    "--xdict-font",
    "--xdict-font-phon",
    "--xdict-font-mono",
    "--xdict-fs-xs",
    "--xdict-fs-s",
    "--xdict-fs-m",
    "--xdict-fs-l",
    "--xdict-fs-xl",
    "--xdict-fs-xxl",
    "--xdict-fs-min",
    "--xdict-fs-max",
    "--xdict-leading-tight",
    "--xdict-weight-bold",
    "--xdict-space-1",
    "--xdict-space-2",
    "--xdict-space-3",
    "--xdict-space-4",
    "--xdict-space-5",
    "--xdict-text",
    "--xdict-text-2",
    "--xdict-panel",
    "--xdict-rule",
    "--xdict-accent",
    "--xdict-red-deep",
    "--xdict-red",
    "--xdict-red-tint",
    "--xdict-orange-deep",
    "--xdict-orange",
    "--xdict-orange-tint",
    "--xdict-yellow-deep",
    "--xdict-yellow",
    "--xdict-yellow-tint",
    "--xdict-green-deep",
    "--xdict-green",
    "--xdict-green-tint",
    "--xdict-teal-deep",
    "--xdict-teal",
    "--xdict-teal-tint",
    "--xdict-blue-deep",
    "--xdict-blue",
    "--xdict-blue-tint",
    "--xdict-purple-deep",
    "--xdict-purple",
    "--xdict-purple-tint",
    "--xdict-pink-deep",
    "--xdict-pink",
    "--xdict-pink-tint",
    "--xdict-base",
    "--xdict-bg",
    "--xdict-leading",
    "--xdict-gap",
    "--xdict-indent",
];

/// The variable the frame sets to XDict's font stack.
const FONT: &str = "var(--xdict-font)";
/// The size a browser gives a page that sets none.
const DEFAULT_PX: f64 = 16.0;
/// Blocks nested deeper than this are copied without being followed: no sheet needs them, and a hostile one of
/// a million `{` would otherwise hold a million frames.
const MAX_DEPTH: usize = 64;
/// The longest selector a report quotes.
const SELECTOR_CHARS: usize = 160;

/// What one edition's sheets decide: the fonts kept and the base size.
#[derive(Debug, Clone, PartialEq)]
pub struct Style {
    base: Base,
    /// The page's size calibration read, and the selectors whose relative size the sample met only over it (R4, D48).
    page_px: f64,
    over_page: BTreeSet<String>,
    kept: Vec<Kept>,
    /// `kept`'s families as compared: lower case, unquoted, spaces collapsed.
    keys: BTreeMap<String, usize>,
    /// What the edition's rules and scripts say about its elements (`crate::facts`).
    pub(crate) facts: crate::facts::Facts,
}

/// The dictionary's base size: the size its absolute sizes are taken relative to.
#[derive(Debug, Clone, PartialEq)]
pub struct Base {
    pub px: f64,
    pub from: BaseFrom,
}

/// Where the base size was read.
#[derive(Debug, Clone, PartialEq)]
pub enum BaseFrom {
    /// The page's own size (`body`, `html` or `:root`), the size its prose inherits; the last one, as the cascade
    /// takes it.
    Page { selector: String },
    /// No page size: the absolute size most prose rules set, each selector of a rule one vote. Headings, headwords,
    /// pronunciations and pseudo-elements do not vote.
    Prose { weight: u64 },
    /// The size most of a sample of the edition's entries' visible text is set in: `chars` characters, `share` of all.
    Text { chars: u64, share: f64 },
    /// No absolute size at all: a browser's default.
    Default,
}

/// A font the dictionary keeps, why, and the rule that showed it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Kept {
    pub family: String,
    pub reason: KeptReason,
    pub selector: String,
}

/// Why a dictionary's font is kept, strongest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum KeptReason {
    /// A rule using it draws Private Use Area characters (`content: "\e900"`): an icon font, whose glyphs no other
    /// font has.
    PrivateUse,
    /// A face the dictionary bundles (`@font-face`) draws a pseudo-element's `content`: an icon or a mark.
    PseudoContent,
    /// A face the dictionary bundles, named as phonetic or used by a pronunciation rule (`.phon`, `.pron`, `.ipa`):
    /// such fonts draw IPA symbols over ASCII letters, which any other font shows as the letters.
    Phonetic,
}

impl KeptReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PrivateUse => "private-use glyphs",
            Self::PseudoContent => "bundled face drawing pseudo-element content",
            Self::Phonetic => "bundled phonetic face",
        }
    }
}

/// How many declarations a normalization changed, by rule.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Counts {
    /// `!important` removed.
    pub important: u64,
    /// Declarations on the page dropped.
    pub page: u64,
    /// Font families replaced (in `font-family` or the `font` shorthand).
    pub family: u64,
    /// Absolute font sizes made relative.
    pub size: u64,
    /// Absolute line heights made relative.
    pub line_height: u64,
    /// Colour values made palette tokens.
    pub colour: u64,
    /// Weights made XDict's.
    pub weight: u64,
    /// Vertical spacings put on the space steps.
    pub space: u64,
    /// Declarations dropped outside the page: backgrounds, borders, shadows, hostile ones (Plain by default, R20).
    pub dropped: u64,
    /// Images dropped as icons or decoration, kept as content, and kept undecided (by file name, at most 64).
    pub images_dropped: u64,
    pub images_kept: u64,
    pub images_undecided: std::collections::BTreeSet<String>,
    /// Tables marked data (and wrapped where they can be) and layout (R10).
    pub data_tables: u64,
    pub layout_tables: u64,
    /// Transcriptions marked in an entry (`crate::phon`).
    pub transcriptions: crate::phon::Transcriptions,
    /// What the strip list removed or repaired (`dev-docs/element-sweep.md` §2.4).
    pub strip: Strips,
    /// Elements given each `data-xdict-role` (its section or label kind after a colon).
    pub roles: BTreeMap<String, u64>,
    /// What the icon rules did, by kind (`label:level`, `marker`, `disclosure`, `glyph-dropped`, …): the icon sweep's
    /// §7 (`dev-docs/measurements/2026-10-15-icon-sweep/`).
    pub icons: BTreeMap<String, u64>,
}

/// What the strip list (`dev-docs/element-sweep.md` §2.4) removed or repaired in what was normalized.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Strips {
    /// S1: tracker and ad scripts dropped.
    pub scripts_tracker: u64,
    /// Q6: scripts that only play audio, and scripts that make nothing work, dropped.
    pub scripts_audio: u64,
    pub scripts_other: u64,
    /// Q6: inline scripts kept, as making something work.
    pub scripts_kept: u64,
    /// S2: comments.
    pub comments: u64,
    /// S3: `head`, `meta`, `base` and `title` inside an entry.
    pub wrappers: u64,
    /// S4: `<x/>` on an element that is not void, closed.
    pub self_closed: u64,
    /// S5: audio in a `data-*` attribute or a handler made a sound link; audio handlers dropped.
    pub audio_links: u64,
    pub audio_handlers: u64,
    /// S6: `javascript:` links unlinked.
    pub javascript_links: u64,
    /// S9: declarations that hid the element wrapping every entry.
    pub revealed: u64,
    /// S10: elements that draw nothing, unwrapped.
    pub empty: u64,
    /// S11: hidden copies of a visible sibling, dropped.
    pub hidden_duplicates: u64,
    /// S12: `<<word>>` made a link.
    pub arrows: u64,
    /// S13: images missing from the package, dropped.
    pub missing_images: u64,
    /// S14: an image's data moved into its `src`.
    pub base64_images: u64,
    /// WI-12: control characters, byte-order marks and literal `\n` mended in the text.
    pub repairs: u64,
}

impl Strips {
    pub fn add(&mut self, o: &Self) {
        self.scripts_tracker += o.scripts_tracker;
        self.scripts_audio += o.scripts_audio;
        self.scripts_other += o.scripts_other;
        self.scripts_kept += o.scripts_kept;
        self.comments += o.comments;
        self.wrappers += o.wrappers;
        self.self_closed += o.self_closed;
        self.audio_links += o.audio_links;
        self.audio_handlers += o.audio_handlers;
        self.javascript_links += o.javascript_links;
        self.revealed += o.revealed;
        self.empty += o.empty;
        self.hidden_duplicates += o.hidden_duplicates;
        self.arrows += o.arrows;
        self.missing_images += o.missing_images;
        self.base64_images += o.base64_images;
        self.repairs += o.repairs;
    }
}

impl Counts {
    pub fn add(&mut self, other: Self) {
        self.important += other.important;
        self.page += other.page;
        self.family += other.family;
        self.size += other.size;
        self.line_height += other.line_height;
        self.colour += other.colour;
        self.weight += other.weight;
        self.space += other.space;
        self.dropped += other.dropped;
        self.images_dropped += other.images_dropped;
        self.images_kept += other.images_kept;
        for name in &other.images_undecided {
            if self.images_undecided.len() < 64 {
                self.images_undecided.insert(name.clone());
            }
        }
        self.data_tables += other.data_tables;
        self.layout_tables += other.layout_tables;
        self.transcriptions.add(&other.transcriptions);
        self.strip.add(&other.strip);
        for (k, v) in other.roles {
            *self.roles.entry(k).or_default() += v;
        }
        for (k, v) in other.icons {
            *self.icons.entry(k).or_default() += v;
        }
    }
}

impl Style {
    /// The style an edition's sheets decide. Each sheet is read by the rewriter's own tokenizer.
    pub fn of_sheets<'a>(sheets: impl IntoIterator<Item = &'a str>) -> Self {
        Self::of_edition(sheets, [])
    }

    /// The style an edition's sheets decide, its base size measured on a sample of its entries (each read to a bound):
    /// the size most of their visible text is set in. Without entries, or without visible text, the rules vote.
    pub fn of_edition<'a, 'e>(
        sheets: impl IntoIterator<Item = &'a str>,
        entries: impl IntoIterator<Item = &'e str>,
    ) -> Self {
        Self::of_linked_edition(sheets.into_iter().map(|s| (s, true)), entries)
    }

    /// As `of_edition`, the base measured under only the sheets marked linked: those the entries link. A sheet the
    /// package holds but no entry links (COBUILD's `colcobuildstyle.my.css`) sets no text's size.
    pub fn of_linked_edition<'a, 'e>(
        sheets: impl IntoIterator<Item = (&'a str, bool)>,
        entries: impl IntoIterator<Item = &'e str>,
    ) -> Self {
        let neutral = Self::neutral();
        let mut rules = Vec::new();
        let mut linked = Vec::new();
        for (sheet, is_linked) in sheets {
            let norm = Norm {
                style: &neutral,
                counts: Counts::default(),
                rules: Some(Vec::new()),
                strip_off_for_tests: false,
                original: false,
            };
            let out = crate::rewrite::normalized(sheet, "", "", usize::MAX, norm, None);
            let more = out.rules.unwrap_or_default();
            linked.extend(std::iter::repeat_n(is_linked, more.len()));
            rules.extend(more);
        }
        let mut faces = BTreeMap::new();
        for rule in rules.iter().filter(|r| r.face) {
            for (name, value) in &rule.decls {
                if name == "font-family" {
                    for (key, _) in families(value) {
                        faces.insert(key, ());
                    }
                }
            }
        }
        let mut kept: BTreeMap<String, Kept> = BTreeMap::new();
        for rule in rules.iter().filter(|r| !r.face) {
            let content = rule.decls.iter().rev().find(|(n, _)| n == "content").map(|(_, v)| v.trim());
            let private = content.is_some_and(private_use);
            let drawn = content.is_some_and(symbol);
            let pseudo = pseudo_element(&rule.selector);
            let phonetic_rule = words(&rule.selector).any(phonetic_word);
            for (name, value) in &rule.decls {
                let named = match name.as_str() {
                    "font-family" => families(value),
                    "font" => shorthand(value).map(|s| families(s.family)).unwrap_or_default(),
                    _ => continue,
                };
                for (key, family) in named {
                    let bundled = faces.contains_key(&key);
                    let reason = if private {
                        KeptReason::PrivateUse
                    } else if bundled && pseudo && drawn {
                        KeptReason::PseudoContent
                    } else if bundled && (phonetic_rule || key.contains("phon")) {
                        KeptReason::Phonetic
                    } else {
                        continue;
                    };
                    let better = kept.get(&key).is_none_or(|k| reason < k.reason);
                    if better {
                        kept.insert(key, Kept { family, reason, selector: rule.selector.clone() });
                    }
                }
            }
        }
        let voted = base(&rules);
        let page_px = match voted.from {
            BaseFrom::Page { .. } => voted.px,
            _ => DEFAULT_PX,
        };
        let calibrating = rules.iter().zip(&linked).filter(|(_, l)| **l).map(|(r, _)| r);
        let entries: Vec<&str> = entries.into_iter().collect();
        let (base, over_page) = match crate::calibrate::measure(calibrating, page_px, entries.iter().copied()) {
            Some(m) => (Base { px: m.px, from: BaseFrom::Text { chars: m.chars, share: m.share } }, m.over_page),
            None => (voted, BTreeSet::new()),
        };
        let mut list: Vec<Kept> = kept.into_values().collect();
        list.sort_by(|a, b| a.family.cmp(&b.family));
        let keys = list.iter().enumerate().map(|(i, k)| (key(&k.family), i)).collect();
        let mut facts = crate::facts::Facts::of_rules(&rules);
        facts.find_wrapper(entries.iter().copied());
        Self { base, page_px, over_page, kept: list, keys, facts }
    }

    /// R4 (D48): the step a relative size `ratio` on `selector` takes when every selector of it sized, in the sample,
    /// only elements whose parent was at the page's size. What it sets is then known in pixels, the page's size times
    /// the ratio, and goes onto the scale against the base as an absolute size does; `None` otherwise.
    fn over_page_step(&self, selector: &str, ratio: f64) -> Option<usize> {
        if self.over_page.is_empty() || ratio <= 0.0 || self.base.px <= 0.0 {
            return None;
        }
        let mut all =
            selector.split(',').map(|s| s.split_whitespace().collect::<Vec<_>>().join(" ").to_ascii_lowercase());
        all.all(|s| self.over_page.contains(&s)).then(|| snap(self.page_px * ratio / self.base.px))
    }

    /// No font kept, a browser's default base.
    fn neutral() -> Self {
        Self {
            base: Base { px: DEFAULT_PX, from: BaseFrom::Default },
            page_px: DEFAULT_PX,
            over_page: BTreeSet::new(),
            kept: Vec::new(),
            keys: BTreeMap::new(),
            facts: crate::facts::Facts::default(),
        }
    }

    /// Reads the scripts an edition runs, so that an element one of them names is never taken for one that draws
    /// nothing (S10).
    pub fn add_scripts<'a>(&mut self, scripts: impl IntoIterator<Item = &'a str>) {
        self.facts.add_scripts(scripts);
    }

    /// Reads the inline scripts of a sample of the edition's entries that run (Q6), as [`Self::add_scripts`].
    pub fn add_inline_scripts<'a>(&mut self, entries: impl IntoIterator<Item = &'a str>) {
        for entry in entries {
            let kept: Vec<&str> =
                crate::strip::inline_scripts(entry).filter(|s| crate::strip::script_purpose(s).is_ok()).collect();
            self.facts.add_scripts(kept);
        }
    }

    pub fn base(&self) -> &Base {
        &self.base
    }

    /// The fonts kept, by family.
    pub fn kept(&self) -> &[Kept] {
        &self.kept
    }

    /// Whether a family is kept wherever it is used: an ASCII-mapped phonetic face (R3.2).
    fn keeps(&self, key: &str) -> bool {
        self.kept_as(key).is_some_and(|k| k.reason == KeptReason::Phonetic) && !unicode_ipa(key)
    }

    /// Whether a family draws icons: kept on the rule that draws one (R3.1).
    fn draws_icons(&self, key: &str) -> bool {
        self.kept_as(key).is_some_and(|k| k.reason != KeptReason::Phonetic)
    }

    /// Whether a face is kept anywhere, so its `@font-face` stays.
    fn kept_anywhere(&self, key: &str) -> bool {
        self.kept_as(key).is_some_and(|k| k.reason != KeptReason::Phonetic || !unicode_ipa(key))
    }

    fn kept_as(&self, key: &str) -> Option<&Kept> {
        self.keys.get(key).and_then(|&i| self.kept.get(i))
    }
}

/// A stylesheet rewritten as [`crate::css_text_within`] rewrites it, and normalized by `style`; with what changed.
/// `Exceeded` as soon as the text, as it is written, would pass `max`.
pub fn css_normalized_within(
    text: &str,
    base: &str,
    dir: &str,
    style: &Style,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    css_styled_within(text, base, dir, style, false, max)
}

/// [`css_normalized_within`], or, when `original` (the reader's "Original style", ADR-0010 Q3), the sheet as the
/// dictionary wrote it: rewritten and stripped exactly as a normalized one is, its declarations left as they are.
pub fn css_styled_within(
    text: &str,
    base: &str,
    dir: &str,
    style: &Style,
    original: bool,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    let norm = Norm { style, counts: Counts::default(), rules: None, strip_off_for_tests: false, original };
    let out = crate::rewrite::normalized(text, base, dir, max, norm, None);
    Ok((out.text?, out.counts))
}

/// An entry's HTML rewritten as [`crate::html_text_within`] rewrites it, its `<style>` blocks and `style=""`
/// normalized by `style`; with what changed.
pub fn html_normalized_within(
    text: &str,
    base: &str,
    dir: &str,
    style: &Style,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    html_normalized_unstripped_within(text, base, dir, style, false, max)
}

/// [`html_normalized_within`], the strip list (S1–S14) off when `strip_off_for_tests` (the hostile battery's lab only,
/// [`Entry::strip_off_for_tests`]).
pub fn html_normalized_unstripped_within(
    text: &str,
    base: &str,
    dir: &str,
    style: &Style,
    strip_off_for_tests: bool,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    html_styled_within(text, base, dir, style, strip_off_for_tests, false, max)
}

/// [`html_normalized_unstripped_within`], or, when `original` (ADR-0010 Q3), with the dictionary's own styles and
/// presentational attributes left as they are: rewritten and stripped exactly as a normalized page is.
pub fn html_styled_within(
    text: &str,
    base: &str,
    dir: &str,
    style: &Style,
    strip_off_for_tests: bool,
    original: bool,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    let norm = Norm { style, counts: Counts::default(), rules: None, strip_off_for_tests, original };
    let out = crate::rewrite::normalized_html(text.into(), base, dir, max, norm, None);
    Ok((out.text?, out.counts))
}

/// What the core knows of an entry beyond its text: its key, which the roles read (the headword is the element
/// whose text is the key), and whether the package holds a resource (S13).
#[derive(Clone, Copy)]
pub struct Entry<'a> {
    pub key: &'a str,
    /// Whether the package holds a resource, by its path as it travels; `None` keeps every image.
    pub resource: Option<&'a dyn Fn(&str) -> bool>,
    /// Whether the edition holds a key, under its own matching rules; `None` asks nothing. A text that is a key
    /// once its stress marks are gone is a headword or a derived form, not a transcription (`crate::phon`).
    pub is_key: Option<&'a dyn Fn(&str) -> bool>,
    /// The strip list (S1–S14) off: the hostile battery's lab only (`Config::strip_off_for_tests`).
    pub strip_off_for_tests: bool,
    /// The reader's "Original style" for this dictionary (ADR-0010 Q3): the dictionary's own styles, presentational
    /// attributes and faces kept, its type, colour and spacing not normalized. The rewrite, the strip list, the roles and
    /// every mark of XDict's (labels, speakers, folds, the glyphs and sprites they replace) apply as they always do.
    pub original: bool,
}

/// An entry as [`html_normalized_within`] writes it, with XDict's roles marked (`data-xdict-role`,
/// `dev-docs/element-sweep.md` §2.1) and, when `entry` can say, the images the package lacks dropped. A `text` given
/// owned is freed once it is read, before the roles are decided.
pub fn entry_normalized_within<'a, 't>(
    text: impl Into<std::borrow::Cow<'t, str>>,
    base: &str,
    dir: &str,
    style: &'a Style,
    entry: &Entry<'a>,
    max: usize,
) -> Result<(String, Counts), Exceeded> {
    let norm = Norm {
        style,
        counts: Counts::default(),
        rules: None,
        strip_off_for_tests: entry.strip_off_for_tests,
        original: entry.original,
    };
    let out = crate::rewrite::normalized_html(text.into(), base, dir, max, norm, Some(entry));
    Ok((out.text?, out.counts))
}

/// What a normalizing rewrite returns.
pub(crate) struct Normalized {
    pub(crate) text: Result<String, Exceeded>,
    pub(crate) counts: Counts,
    pub(crate) rules: Option<Vec<Rule>>,
}

/// A normalization under way: the style it applies, what it changed, and, when an edition is being read, its rules.
pub(crate) struct Norm<'s> {
    pub(crate) style: &'s Style,
    pub(crate) counts: Counts,
    pub(crate) rules: Option<Vec<Rule>>,
    /// The strip list off (S1–S14, Q6's scripts and audio handlers): [`Entry::strip_off_for_tests`].
    pub(crate) strip_off_for_tests: bool,
    /// The dictionary's own look kept: [`Entry::original`].
    pub(crate) original: bool,
}

impl<'s> Norm<'s> {
    /// A normalization for a sheet inside this one's text (a `<style>`, a `style=""`).
    pub(crate) fn child(&self) -> Norm<'s> {
        Norm {
            style: self.style,
            counts: Counts::default(),
            rules: self.rules.as_ref().map(|_| Vec::new()),
            strip_off_for_tests: self.strip_off_for_tests,
            original: self.original,
        }
    }

    pub(crate) fn absorb(&mut self, other: Norm<'_>) {
        self.counts.add(other.counts);
        if let (Some(all), Some(more)) = (&mut self.rules, other.rules) {
            all.extend(more);
        }
    }
}

/// A rule as an edition's reading sees it: its selector, whether it is a `@font-face`, its declarations (name in
/// lower case, value without `!important`).
pub(crate) struct Rule {
    pub(crate) selector: String,
    pub(crate) face: bool,
    pub(crate) page: bool,
    pub(crate) decls: Vec<(String, String)>,
    /// Inside `@media` or its kin.
    pub(crate) grouped: bool,
}

/// What a block is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    /// A style rule's declarations; `page` when every selector's subject is the page.
    Rule { page: bool },
    /// `@font-face`: its `font-family` names the face, and is left as it is.
    Face,
    /// `@media`, `@supports` and their kin: rules inside.
    Group,
    /// Anything else (`@keyframes`, `@page`, an unknown at-rule, and what is inside them): copied as it is.
    Skip,
}

/// A block being read: what it is, where its body starts in the output, where its `;`s were written there, whether
/// a block opened inside it (CSS nesting; its own declarations are then left as they are), and its prelude.
pub(crate) struct Frame {
    pub(crate) kind: Kind,
    pub(crate) start: usize,
    pub(crate) seps: Vec<usize>,
    pub(crate) child: bool,
    pub(crate) prelude: (usize, usize),
    /// Inside `@media`, `@supports` or their kin: a rule here does not hold whatever the state.
    pub(crate) grouped: bool,
}

/// Blocks as the tokenizer meets them.
pub(crate) struct Blocks<'t> {
    frames: Vec<Frame>,
    /// Blocks opened past [`MAX_DEPTH`], copied without being followed.
    deep: usize,
    /// Where the current prelude starts in the input.
    stmt: usize,
    /// For a `style=""`, its element.
    inline: Option<&'t str>,
}

impl<'t> Blocks<'t> {
    /// A stylesheet's blocks; a `style=""`'s declarations are one block, the element's.
    pub(crate) fn new(inline: Option<&'t str>) -> Self {
        let frames = match inline {
            Some(element) => {
                let page = matches!(element.to_ascii_lowercase().as_str(), "html" | "body");
                vec![Frame {
                    kind: Kind::Rule { page },
                    start: 0,
                    seps: Vec::new(),
                    child: false,
                    prelude: (0, 0),
                    grouped: false,
                }]
            }
            None => Vec::new(),
        };
        Self { frames, deep: 0, stmt: 0, inline }
    }

    /// A `{` at `at` in `text`, its body starting at `start` in the output.
    pub(crate) fn open(&mut self, text: &str, at: usize, start: usize) {
        if self.deep > 0 || self.frames.len() >= MAX_DEPTH {
            self.deep += 1;
            return;
        }
        let parent = self.frames.last().map(|f| f.kind);
        if let Some(top) = self.frames.last_mut() {
            top.child = true;
        }
        let prelude = text.get(self.stmt..at).unwrap_or("");
        let kind = match parent {
            Some(Kind::Face | Kind::Skip) => Kind::Skip,
            _ => kind_of(prelude),
        };
        let grouped = self.frames.iter().any(|f| f.kind == Kind::Group);
        self.frames.push(Frame { kind, start, seps: Vec::new(), child: false, prelude: (self.stmt, at), grouped });
        self.stmt = at + 1;
    }

    /// A `;` at `at`, written at `written` in the output.
    pub(crate) fn separator(&mut self, at: usize, written: usize) {
        if self.deep == 0
            && let Some(top) = self.frames.last_mut()
        {
            top.seps.push(written);
        }
        self.stmt = at + 1;
    }

    /// A `}` at `at`: the block it closes, if one was followed.
    pub(crate) fn close(&mut self, at: usize) -> Option<Frame> {
        self.stmt = at + 1;
        if self.deep > 0 {
            self.deep -= 1;
            return None;
        }
        // A `style=""`'s own block is closed only at its end.
        if self.inline.is_some() && self.frames.len() == 1 {
            return None;
        }
        self.frames.pop()
    }

    /// The blocks still open at the end, innermost first.
    pub(crate) fn rest(&mut self) -> Option<Frame> {
        self.frames.pop()
    }

    /// A frame's selector, for a report.
    pub(crate) fn selector(&self, text: &str, frame: &Frame) -> String {
        match self.inline {
            Some(element) if frame.prelude == (0, 0) => element.to_ascii_lowercase(),
            _ => clean_selector(text.get(frame.prelude.0..frame.prelude.1).unwrap_or("")),
        }
    }
}

/// What a prelude opens.
fn kind_of(prelude: &str) -> Kind {
    let clean = without_comments(prelude);
    let trimmed = clean.trim();
    if let Some(at) = trimmed.strip_prefix('@') {
        let name: String =
            at.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-').collect::<String>().to_ascii_lowercase();
        return match name.as_str() {
            "font-face" => Kind::Face,
            "media" | "supports" | "layer" | "document" | "-moz-document" | "container" | "scope"
            | "starting-style" => Kind::Group,
            _ => Kind::Skip,
        };
    }
    Kind::Rule { page: is_page(trimmed) }
}

/// Whether every selector of a list has the page for its subject: `html`, `body` or `:root`, with any class, id,
/// attribute or pseudo-class.
fn is_page(selectors: &str) -> bool {
    let mut any = false;
    for selector in selectors.split(',') {
        let subject = selector.rsplit(|c: char| c.is_whitespace() || matches!(c, '>' | '+' | '~')).next().unwrap_or("");
        let subject = subject.trim();
        if subject.is_empty() {
            return false;
        }
        let lower = subject.to_ascii_lowercase();
        let element: String = lower.chars().take_while(|c| !matches!(c, '.' | '#' | '[' | ':')).collect();
        let page = matches!(element.as_str(), "html" | "body") || (element.is_empty() && lower.starts_with(":root"));
        if !page {
            return false;
        }
        any = true;
    }
    any
}

/// What a rule says as a whole, which its declarations' values depend on.
struct Facts {
    /// It draws an icon: private-use `content`, or a bundled face's pseudo-element `content` (R3: the family is kept
    /// on this rule only).
    icon: bool,
    /// The background it paints, when it also sets a text colour: a chip (§4.3).
    chip: Option<colour::Rgb>,
    /// It draws a box (a border or padding), where a near-white background is a panel.
    boxed: bool,
    /// Its subject is an image, an SVG or a video, whose sizes the frame must win (R2).
    media: bool,
    /// Its subject is an `<hr>`, which is a gap (Q9): what would draw it a line is dropped.
    rule: bool,
}

impl Facts {
    /// An element's own attributes: nothing known of a rule.
    fn plain() -> Self {
        Self { icon: false, chip: None, boxed: false, media: false, rule: false }
    }

    fn of(decls: &[Option<Decl<'_>>], selector: &str, style: &Style) -> Self {
        let all = || decls.iter().flatten();
        let content = all().rev().find(|d| d.name == "content").map(|d| d.value.trim());
        let private = content.is_some_and(private_use);
        let drawn = content.is_some_and(symbol);
        let bundled = all().any(|d| {
            let named = match d.name.as_str() {
                "font-family" => families(d.value),
                "font" => shorthand(d.value).map(|s| families(s.family)).unwrap_or_default(),
                _ => Vec::new(),
            };
            named.iter().any(|(k, _)| style.draws_icons(k))
        });
        let icon = private || (drawn && bundled && pseudo_element(selector));
        let sets_colour = all().any(|d| d.name == "color");
        let chip = sets_colour
            .then(|| {
                all().rev().find_map(|d| match d.name.as_str() {
                    "background" | "background-color" => colour::first(d.value),
                    _ => None,
                })
            })
            .flatten();
        let boxed = all().any(|d| {
            (d.name.starts_with("border") || d.name.starts_with("padding"))
                && !matches!(d.value.trim(), "0" | "none" | "0px" | "0 none")
        });
        let subject = selector.rsplit(|c: char| c.is_whitespace() || matches!(c, '>' | '+' | '~' | ',')).next();
        let element: String = subject
            .unwrap_or("")
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        let media = matches!(element.as_str(), "img" | "svg" | "video");
        let rule = element == "hr";
        Self { icon, chip, boxed, media, rule }
    }
}

/// A block's body as written (`body`, its `;`s at `seps`) normalized; `None` when nothing changed. An edition's
/// reading takes its rule as it was written.
pub(crate) fn finish(
    body: &str,
    frame: &Frame,
    selector: impl FnOnce() -> String,
    norm: &mut Norm<'_>,
) -> Option<String> {
    let (page, face) = match frame.kind {
        Kind::Rule { page } if !frame.child => (page, false),
        Kind::Face => (false, true),
        _ => return None,
    };
    let mut pieces = Vec::with_capacity(frame.seps.len() + 1);
    let mut from = 0;
    for &sep in &frame.seps {
        let at = sep.saturating_sub(frame.start);
        pieces.push(body.get(from..at).unwrap_or(""));
        from = at + 1;
    }
    pieces.push(body.get(from..).unwrap_or(""));
    let decls: Vec<Option<Decl<'_>>> = pieces.iter().map(|p| Decl::parse(p)).collect();
    let selector = selector();
    if let Some(rules) = &mut norm.rules {
        let decls = decls.iter().flatten().map(|d| (d.name.clone(), d.value.trim().to_owned())).collect();
        rules.push(Rule { selector: selector.clone(), face, page, decls, grouped: frame.grouped });
    }
    if norm.original {
        let icon = Facts::of(&decls, &selector, norm.style).icon && pseudo_element(&selector);
        return marked(&pieces, &decls, &selector, page, icon, norm);
    }
    let style = norm.style;
    let counts = &mut norm.counts;
    if face {
        // R3: a face is loaded only where a kept rule uses it.
        let used = decls
            .iter()
            .flatten()
            .any(|d| d.name == "font-family" && families(d.value).iter().any(|(k, _)| style.kept_anywhere(k)));
        if used {
            return None;
        }
        counts.family += 1;
        return Some(String::new());
    }
    let facts = Facts::of(&decls, &selector, style);
    let mut changed = false;
    let mut out: Vec<String> = Vec::with_capacity(pieces.len() + 1);
    let mut sized: Option<&str> = None;
    for (piece, decl) in pieces.iter().zip(&decls) {
        let Some(decl) = decl else {
            out.push((*piece).to_owned());
            continue;
        };
        let mut act = action(&decl.name, page);
        // A CSS image drawn as content is an icon or decoration (Plain by default).
        if decl.name == "content" && decl.value.to_ascii_lowercase().contains("url(") {
            act = Action::Drop;
        }
        // An icon face's glyph is dropped: XDict's control or label replaces what it drew, and what it decorated
        // needs nothing (the icon sweep's §7.6; Chambers' 👇, the owner's question 2).
        if decl.name == "content" && facts.icon && pseudo_element(&selector) {
            act = Action::Drop;
            *counts.icons.entry("glyph-dropped".into()).or_default() += 1;
        }
        // S9: the element that wraps every entry, hidden until the dictionary's script runs, is shown.
        if !page && reveals(decl, &selector, style) {
            counts.strip.revealed += 1;
            changed = true;
            continue;
        }
        // Q9: nothing draws an `<hr>` as a line, and its gap is the frame's.
        if facts.rule
            && ["border", "background", "height", "color", "margin", "outline", "box-shadow"]
                .iter()
                .any(|p| decl.name.starts_with(p))
        {
            act = Action::Drop;
        }
        // One palette: a text colour that would not be a token once mapped goes (WebKit's own link colour, a
        // system colour, `color-mix()`, a dictionary's variable).
        if act == TEXT {
            let mapped = colour::map_value(decl.value, Role::Text, None);
            if !colour::only_tokens(mapped.as_deref().unwrap_or(decl.value)) {
                act = Action::Drop;
            }
        }
        // R5: every line height is the frame's, even where a rule sets a height (unification R, 2026-10-16: one
        // leading; the box it centred text in is gone with "Plain by default").
        let line_height = act == Action::LineHeight;
        // A size that cannot be put on the scale (`calc()`, `ex`, a variable) goes: the element takes its parent's.
        let unreadable = act == Action::Size && !size_kept(decl.value) && size_token(decl.value, style).is_none();
        let drop = act == Action::Drop || line_height || unreadable;
        // R2: `!important` goes only where the frame must win.
        let strip = decl.important
            && (page || drop || (facts.media && matches!(decl.name.as_str(), "width" | "max-width" | "height")));
        if strip {
            counts.important += 1;
            changed = true;
        }
        if drop {
            if page {
                counts.page += 1;
            } else if line_height {
                counts.line_height += 1;
            } else {
                counts.dropped += 1;
            }
            changed = true;
            continue;
        }
        if act == Action::Size && size_inherits(decl.value) {
            sized = Some(leading_of(false, decl.value));
        }
        let value = match act {
            Action::Drop | Action::Keep | Action::LineHeight => None,
            Action::Family => family_value(decl.value, &facts, style, counts),
            // R4 (2026-10-17): a relative size on the element that wraps the whole entry is the dictionary's base
            // size, which XDict owns: 1 (ODE's `.Od3{font-size:117%}` set all of it at 18 px).
            Action::Size if relative_ratio(split_space(decl.value).1).is_some() && style.facts.wraps(&selector) => {
                counts.size += 1;
                sized = Some(leading_of(false, decl.value));
                Some(format!("{}{}", split_space(decl.value).0, step_token(2)))
            }
            // R4 (2026-10-18, D48): a relative size only ever met over the page's size is that size times its ratio,
            // snapped against the base as an absolute size is (OALECD's `def{font-size:110%}` under
            // `body{font-size:.95em}`, its definitions, went to l by the ratio alone, at 18 px).
            Action::Size
                if let Some(i) =
                    relative_ratio(split_space(decl.value).1).and_then(|r| style.over_page_step(&selector, r)) =>
            {
                counts.size += 1;
                sized = Some(leading_of(i >= 4, decl.value));
                Some(format!("{}{}", split_space(decl.value).0, step_token(i)))
            }
            Action::Size => size_value(decl.value, style, counts).map(|(v, large)| {
                sized = Some(leading_of(large, decl.value));
                v
            }),
            Action::Font => font_value(decl.value, &facts, style, counts).map(|(v, large)| {
                sized = Some(leading_of(large, decl.value));
                v
            }),
            Action::Colour(role) => colour_value(decl.value, role, &facts, counts),
            Action::Weight => weight_value(decl.value, counts),
            Action::FontStyle => font_style_value(decl.value),
            Action::Space(shorthand) => space_value(decl.value, shorthand, style, counts),
        };
        changed |= value.is_some();
        if value.is_none() && !strip {
            out.push((*piece).to_owned());
            continue;
        }
        let important = if decl.important && !strip { " !important" } else { "" };
        out.push(format!("{}{}{important}{}", decl.head, value.as_deref().unwrap_or(decl.value), decl.tail));
    }
    // R4: every size carries its leading, so text never inherits a leading set for another size: large text wraps
    // less airily (unification R, 2026-10-16: 1.6, 1.3 when large).
    if let Some(leading) = sized {
        let last = out.pop().unwrap_or_default();
        if last.trim().is_empty() {
            out.push(leading.to_owned());
            out.push(last);
        } else {
            out.push(last);
            out.push(leading.to_owned());
        }
        changed = true;
    }
    changed.then(|| out.join(";"))
}

/// A block's declarations in "Original style" (ADR-0010 Q3): as written, but for what the strip list takes (S9) and
/// what XDict's marks replace (a CSS image drawn as content, an icon face's glyph), both the same in either style. The
/// normalization of type, colour and spacing is what original style leaves out.
fn marked(
    pieces: &[&str],
    decls: &[Option<Decl<'_>>],
    selector: &str,
    page: bool,
    icon: bool,
    norm: &mut Norm<'_>,
) -> Option<String> {
    let mut changed = false;
    let mut out: Vec<&str> = Vec::with_capacity(pieces.len());
    for (piece, decl) in pieces.iter().zip(decls) {
        if let Some(decl) = decl
            && !page
            && reveals(decl, selector, norm.style)
        {
            norm.counts.strip.revealed += 1;
            changed = true;
            continue;
        }
        if let Some(decl) = decl
            && decl.name == "content"
            && (decl.value.to_ascii_lowercase().contains("url(") || icon)
        {
            if icon {
                *norm.counts.icons.entry("glyph-dropped".into()).or_default() += 1;
            }
            changed = true;
            continue;
        }
        out.push(piece);
    }
    changed.then(|| out.join(";"))
}

/// S9: a declaration that hides the element wrapping every entry, until the dictionary's script shows it.
fn reveals(decl: &Decl<'_>, selector: &str, style: &Style) -> bool {
    let hides = (decl.name == "display" && decl.value.trim().eq_ignore_ascii_case("none"))
        || (decl.name == "visibility" && decl.value.trim().eq_ignore_ascii_case("hidden"));
    hides && style.facts.reveals(selector)
}

/// One declaration as written: up to its `:`, its value (`!important` taken off), and the space after it.
struct Decl<'a> {
    head: &'a str,
    name: String,
    value: &'a str,
    important: bool,
    tail: &'a str,
}

impl<'a> Decl<'a> {
    fn parse(piece: &'a str) -> Option<Self> {
        let start = skip_trivia(piece);
        let colon = start + piece.get(start..)?.find(':')?;
        let name = crate::rewrite::unescaped(piece.get(start..colon)?.trim()).to_ascii_lowercase();
        if name.is_empty() || name.contains(|c: char| c.is_whitespace() || matches!(c, '{' | '}')) {
            return None;
        }
        let head = piece.get(..=colon)?;
        let rest = piece.get(colon + 1..)?;
        let trimmed = rest.trim_end();
        let tail = rest.get(trimmed.len()..)?;
        let bang = trimmed
            .len()
            .checked_sub(9)
            .filter(|&at| trimmed.get(at..).is_some_and(|w| w.eq_ignore_ascii_case("important")))
            .and_then(|at| trimmed.get(..at))
            .map(str::trim_end)
            .and_then(|before| before.strip_suffix('!'));
        Some(match bang {
            Some(value) => Self { head, name, value: value.trim_end(), important: true, tail },
            None => Self { head, name, value: trimmed, important: false, tail },
        })
    }
}

/// Where a declaration's name starts: past whitespace and comments.
fn skip_trivia(piece: &str) -> usize {
    let mut at = 0;
    loop {
        let rest = piece.get(at..).unwrap_or("");
        let trimmed = rest.trim_start();
        at += rest.len() - trimmed.len();
        match trimmed.strip_prefix("/*") {
            Some(comment) => at += 2 + comment.find("*/").map_or(comment.len(), |e| e + 2),
            None => return at,
        }
    }
}

/// What the normalization does to a declaration (`dev-docs/reading-style.md` §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    /// Left as written.
    Keep,
    /// Removed: the frame owns it, or it is hostile.
    Drop,
    /// R3: a family becomes XDict's.
    Family,
    /// R4: a size goes onto the scale.
    Size,
    /// R5: dropped, unless its rule sets a height.
    LineHeight,
    /// The `font` shorthand, part by part.
    Font,
    /// §4: every colour literal becomes a palette token.
    Colour(Role),
    /// R6: bold is XDict's bold; thin is regular.
    Weight,
    /// R6: oblique is italic.
    FontStyle,
    /// R7: vertical spacing goes onto the space steps (`true`: a `margin`/`padding` shorthand).
    Space(bool),
}

/// One row of the rules: a property (a name ending in `-` covers every longhand it starts) and what is done to it
/// outside the page. A property no row names is kept. The page (R1) keeps only [`PAGE_KEPT`]. New rules are rows.
struct Row {
    property: &'static str,
    action: Action,
}

const fn row(property: &'static str, action: Action) -> Row {
    Row { property, action }
}

const TEXT: Action = Action::Colour(Role::Text);

/// `dev-docs/reading-style.md` §3, as rows. "Plain by default" (the owner, 2026-10-15): every background, border,
/// outline and shadow the dictionary sets is dropped; the frame's surface is the only background.
const RULES: [Row; 40] = [
    row("font", Action::Font),
    row("font-family", Action::Family),
    row("font-size", Action::Size),
    row("line-height", Action::LineHeight),
    row("font-weight", Action::Weight),
    row("font-style", Action::FontStyle),
    row("color", TEXT),
    row("text-decoration", TEXT),
    row("text-decoration-color", TEXT),
    row("-webkit-text-fill-color", TEXT),
    row("caret-color", TEXT),
    row("background", Action::Drop),
    row("background-", Action::Drop),
    row("border", Action::Drop),
    row("border-", Action::Drop),
    row("outline", Action::Drop),
    row("outline-", Action::Drop),
    row("column-rule", Action::Drop),
    row("text-shadow", Action::Drop),
    row("box-shadow", Action::Drop),
    row("margin", Action::Space(true)),
    row("padding", Action::Space(true)),
    row("margin-top", Action::Space(false)),
    row("margin-bottom", Action::Space(false)),
    row("padding-top", Action::Space(false)),
    row("padding-bottom", Action::Space(false)),
    row("margin-block", Action::Space(false)),
    row("margin-block-start", Action::Space(false)),
    row("margin-block-end", Action::Space(false)),
    row("padding-block", Action::Space(false)),
    row("padding-block-start", Action::Space(false)),
    row("padding-block-end", Action::Space(false)),
    // R20: hostile, everywhere.
    row("zoom", Action::Drop),
    // `all` resets the colour (and the rest) to the engine's own: CanvasText, outside the palette.
    row("all", Action::Drop),
    row("-webkit-text-size-adjust", Action::Drop),
    row("animation", Action::Drop),
    row("animation-", Action::Drop),
    // R9: a bullet drawn as an image hides the frame's marker.
    row("list-style-image", Action::Drop),
    // R1's page attributes as CSS: never inside an entry's rule either.
    row("-webkit-margin-before", Action::Space(false)),
    row("-webkit-margin-after", Action::Space(false)),
];

/// R1: what a page rule keeps; everything else on the page is the frame's.
fn page_kept(name: &str) -> bool {
    name.starts_with("--")
        || name.starts_with("font-variant")
        || matches!(
            name,
            "counter-reset"
                | "counter-set"
                | "quotes"
                | "overflow-wrap"
                | "word-wrap"
                | "word-break"
                | "hyphens"
                | "font-feature-settings"
                | "font-kerning"
        )
}

/// The action for a property: on the page R1's allowlist, elsewhere an exact row before a prefix row.
fn action(name: &str, page: bool) -> Action {
    if page {
        return if page_kept(name) { Action::Keep } else { Action::Drop };
    }
    RULES
        .iter()
        .find(|r| r.property == name)
        .or_else(|| RULES.iter().find(|r| r.property.ends_with('-') && name.starts_with(r.property)))
        .map_or(Action::Keep, |r| r.action)
}

fn colour_value(value: &str, role: Role, facts: &Facts, counts: &mut Counts) -> Option<String> {
    let (role, chip) = match role {
        Role::Background { .. } => (Role::Background { boxed: facts.boxed }, None),
        Role::Text => (Role::Text, facts.chip),
        Role::Mark => (Role::Mark, None),
    };
    let mapped = colour::map_value(value, role, chip)?;
    counts.colour += 1;
    Some(mapped)
}

/// A value's leading space and the value itself.
fn split_space(value: &str) -> (&str, &str) {
    let trimmed = value.trim_start();
    (value.get(..value.len() - trimmed.len()).unwrap_or(""), trimmed)
}

fn wide_keyword(value: &str) -> bool {
    ["inherit", "initial", "unset", "revert", "revert-layer"].iter().any(|k| value.eq_ignore_ascii_case(k))
}

/// R3: the family a list becomes, or `None` where it is kept.
fn family_for(list: &str, facts: &Facts, style: &Style) -> Option<&'static str> {
    if facts.icon || wide_keyword(list.trim()) {
        return None;
    }
    let named = families(list);
    if named.iter().any(|(k, _)| style.keeps(k)) {
        return None;
    }
    if named.first().is_some_and(|(k, _)| unicode_ipa(k)) {
        return Some("var(--xdict-font-phon)");
    }
    let generic_mono = list.split(',').any(|f| f.trim().trim_matches(['"', '\'']).eq_ignore_ascii_case("monospace"));
    Some(if generic_mono { "var(--xdict-font-mono)" } else { FONT })
}

fn family_value(value: &str, facts: &Facts, style: &Style, counts: &mut Counts) -> Option<String> {
    let (space, list) = split_space(value);
    let to = family_for(list, facts, style)?;
    counts.family += 1;
    Some(format!("{space}{to}"))
}

/// The leading a size carries (`--xdict-leading`), and a large size's.
const LEADING: &str = "line-height:var(--xdict-leading, 1.6)";
const LEADING_TIGHT: &str = "line-height:var(--xdict-leading-tight, 1.3)";

/// The leading a size declaration carries: a size that inherits its parent's takes its parent's leading too.
fn leading_of(large: bool, value: &str) -> &'static str {
    if size_inherits(value) {
        "line-height:inherit"
    } else if large {
        LEADING_TIGHT
    } else {
        LEADING
    }
}

fn size_inherits(value: &str) -> bool {
    let v = value.trim().to_ascii_lowercase();
    matches!(v.as_str(), "inherit" | "unset" | "revert" | "revert-layer")
}

/// The type scale (`--xdict-fs-*`): name and ratio.
const SCALE: [(&str, f64); 6] = [("xs", 0.75), ("s", 0.875), ("m", 1.0), ("l", 1.125), ("xl", 1.25), ("xxl", 1.5)];

/// The nearest step of the scale to a ratio, logarithmically; clamped to its ends.
fn snap(ratio: f64) -> usize {
    let mut best = 0;
    let mut distance = f64::INFINITY;
    for (i, (_, step)) in SCALE.iter().enumerate() {
        let d = (ratio.ln() - step.ln()).abs();
        if d < distance {
            (best, distance) = (i, d);
        }
    }
    best
}

fn step_token(i: usize) -> String {
    let (name, ratio) = SCALE.get(i).copied().unwrap_or(("m", 1.0));
    format!("var(--xdict-fs-{name}, {}rem)", number(ratio))
}

/// An absolute size keyword in pixels (CSS's table at a 16px medium).
pub(crate) fn keyword_px(value: &str) -> Option<f64> {
    const KEYWORDS: [(&str, f64); 8] = [
        ("xx-small", 9.0),
        ("x-small", 10.0),
        ("small", 13.0),
        ("medium", 16.0),
        ("large", 18.0),
        ("x-large", 24.0),
        ("xx-large", 32.0),
        ("xxx-large", 48.0),
    ];
    KEYWORDS.iter().find(|(k, _)| value.eq_ignore_ascii_case(k)).map(|(_, px)| *px)
}

/// A relative size as a ratio to its parent's.
pub(crate) fn relative_ratio(value: &str) -> Option<f64> {
    let v = value.trim().to_ascii_lowercase();
    if v == "smaller" {
        return Some(1.0 / 1.2);
    }
    if v == "larger" {
        return Some(1.2);
    }
    let (n, scale) = if let Some(n) = v.strip_suffix('%') {
        (n, 0.01)
    } else {
        (v.strip_suffix("rem").or_else(|| v.strip_suffix("em"))?, 1.0)
    };
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    n.parse::<f64>().ok().filter(|x| x.is_finite()).map(|x| x * scale)
}

/// R4: a size on the scale, and whether it is large (xl and above).
fn size_token(value: &str, style: &Style) -> Option<(String, bool)> {
    let v = value.trim();
    let absolute = absolute_px(v).or_else(|| keyword_px(v));
    if let Some(px) = absolute {
        if px <= 0.0 {
            return None;
        }
        let i = snap(px / style.base.px);
        return Some((step_token(i), i >= 4));
    }
    let lower = v.to_ascii_lowercase();
    if lower.ends_with("vw") || lower.ends_with("vh") {
        return Some((step_token(2), false));
    }
    // A relative size is a step of the scale too, by its own ratio: never compounded on its parent's, so every
    // size an entry shows is on the scale (unification R, 2026-10-16).
    let ratio = relative_ratio(v).filter(|r| *r > 0.0)?;
    let i = snap(ratio);
    Some((step_token(i), i >= 4))
}

/// A size kept as written: one that sets no size of its own (`inherit`, ...) or hides the text (`0`).
fn size_kept(value: &str) -> bool {
    let v = value.trim().to_ascii_lowercase();
    matches!(v.as_str(), "inherit" | "initial" | "unset" | "revert" | "revert-layer" | "0")
        || absolute_px(&v) == Some(0.0)
}

fn size_value(value: &str, style: &Style, counts: &mut Counts) -> Option<(String, bool)> {
    let (space, size) = split_space(value);
    let (token, large) = size_token(size, style)?;
    counts.size += 1;
    Some((format!("{space}{token}"), large))
}

/// `<font size>` (R4): 1–7, or a step from 3.
pub(crate) fn font_size_attribute(value: &str) -> Option<String> {
    let v = value.trim();
    let n: i32 = match v.strip_prefix('+') {
        Some(k) => 3 + k.parse::<i32>().ok()?,
        None if v.starts_with('-') => 3 + v.parse::<i32>().ok()?,
        None => v.parse().ok()?,
    };
    let i = match n {
        i32::MIN..=1 => 0,
        2 => 1,
        3 => 2,
        4 => 3,
        5 => 4,
        _ => 5,
    };
    Some(format!("font-size:{};{}", step_token(i), if i >= 4 { LEADING_TIGHT } else { LEADING }))
}

fn font_value(value: &str, facts: &Facts, style: &Style, counts: &mut Counts) -> Option<(String, bool)> {
    let (space, font) = split_space(value);
    let parts = shorthand(font)?;
    let (size, large) = match size_token(parts.size, style) {
        Some(t) => {
            counts.size += 1;
            t
        }
        None => (parts.size.to_owned(), false),
    };
    // R5: the shorthand's line height goes with the rest, unless the rule sets a height.
    let height = match parts.line_height {
        Some(_) => {
            counts.line_height += 1;
            String::new()
        }
        None => String::new(),
    };
    let family = match family_for(parts.family, facts, style) {
        Some(to) => {
            counts.family += 1;
            to.to_owned()
        }
        None => parts.family.to_owned(),
    };
    let weight = weight_of(parts.before).map_or(parts.before.to_owned(), |w| format!("{w} "));
    Some((format!("{space}{weight}{size}{height} {family}"), large))
}

/// R6: what a weight becomes; `None` for one kept.
fn weight_token(value: &str) -> Option<&'static str> {
    let v = value.trim().to_ascii_lowercase();
    match v.as_str() {
        "bold" | "bolder" | "600" | "700" | "800" | "900" => Some("var(--xdict-weight-bold, 600)"),
        "lighter" | "100" | "200" | "300" | "500" => Some("400"),
        _ => None,
    }
}

/// The weight among a shorthand's leading words, rewritten with the rest kept.
fn weight_of(before: &str) -> Option<String> {
    let mut changed = false;
    let words: Vec<String> = before
        .split_whitespace()
        .map(|w| match weight_token(w) {
            Some(t) => {
                changed = true;
                t.to_owned()
            }
            None => w.to_owned(),
        })
        .collect();
    (changed && !words.is_empty()).then(|| words.join(" "))
}

fn weight_value(value: &str, counts: &mut Counts) -> Option<String> {
    let (space, weight) = split_space(value);
    let to = weight_token(weight)?;
    counts.weight += 1;
    Some(format!("{space}{to}"))
}

fn font_style_value(value: &str) -> Option<String> {
    let (space, style) = split_space(value);
    style.to_ascii_lowercase().starts_with("oblique").then(|| format!("{space}italic"))
}

/// The space steps (`--xdict-space-N`), in rem.
const SPACE: [f64; 5] = [0.25, 0.5, 0.75, 1.0, 1.5];

/// R7: one vertical length on the space steps: snapped, clamped to `[-space-2, space-5]`, more negative than that is 0.
fn space_token(token: &str, style: &Style) -> Option<String> {
    let t = token.trim();
    let (negative, magnitude) = match t.strip_prefix('-') {
        Some(m) => (true, m),
        None => (false, t),
    };
    let lower = magnitude.to_ascii_lowercase();
    let rem = if let Some(px) = absolute_px(&lower) {
        px / style.base.px
    } else {
        // An `ex` is half an `em`, CSS's own fallback for an x-height: "in any unit" (LDOCE6's `1ex`, 2026-10-17).
        let (n, scale) = match lower.strip_suffix("ex") {
            Some(n) => (n, 0.5),
            None => (lower.strip_suffix("rem").or_else(|| lower.strip_suffix("em"))?, 1.0),
        };
        if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
            return None;
        }
        n.parse::<f64>().ok().filter(|x| x.is_finite())? * scale
    };
    if rem == 0.0 {
        return None;
    }
    if negative && rem > 0.5 + 1e-9 {
        return Some("0".to_owned());
    }
    let mut best = 0;
    for (i, s) in SPACE.iter().enumerate() {
        if (rem - s).abs() < (rem - SPACE.get(best).copied().unwrap_or(0.0)).abs() {
            best = i;
        }
    }
    let to_zero = rem < SPACE.first().copied().unwrap_or(0.25) / 2.0;
    if to_zero {
        return Some("0".to_owned());
    }
    let step = SPACE.get(best).copied().unwrap_or(0.25);
    let token = format!("var(--xdict-space-{}, {}rem)", best + 1, number(step));
    Some(if negative { format!("calc(-1 * {token})") } else { token })
}

/// R7: a vertical spacing value; for a shorthand, only its top and bottom.
fn space_value(value: &str, shorthand: bool, style: &Style, counts: &mut Counts) -> Option<String> {
    let (space, v) = split_space(value);
    let parts: Vec<&str> = v.split_whitespace().collect();
    if parts.is_empty() || parts.len() > 4 || v.contains('(') {
        return None;
    }
    let vertical: &[usize] = match (shorthand, parts.len()) {
        (false, _) => &[0, 1],
        (true, 1) => &[0],
        (true, 2) => &[0],
        (true, _) => &[0, 2],
    };
    let mut out: Vec<String> = parts.iter().map(|p| (*p).to_owned()).collect();
    let mut changed = false;
    if shorthand && parts.len() == 1 {
        // One value is all four sides: the horizontal ones keep it.
        let to = space_token(parts.first()?, style)?;
        counts.space += 1;
        return Some(format!("{space}{to} {}", parts.first()?));
    }
    if shorthand && parts.len() == 2 {
        let to = space_token(parts.first()?, style)?;
        counts.space += 1;
        return Some(format!("{space}{to} {} {to}", parts.get(1)?));
    }
    for &i in vertical {
        if let Some(p) = parts.get(i)
            && let Some(to) = space_token(p, style)
            && let Some(slot) = out.get_mut(i)
        {
            *slot = to;
            changed = true;
        }
    }
    if !changed {
        return None;
    }
    counts.space += 1;
    Some(format!("{space}{}", out.join(" ")))
}

/// A Unicode IPA face: given the one IPA face instead (R3).
fn unicode_ipa(key: &str) -> bool {
    ["gentium", "charis", "doulos", "andika", "lucida sans unicode", "arial unicode"].iter().any(|f| key.starts_with(f))
}

/// The declarations an element's presentational attributes become (R22); `None` for an attribute kept as it is.
/// What an `<hr>` is written with (Q9): a gap on the spacing steps, never a line.
pub(crate) const RULE_GAP: &str = "border:0;height:0;margin-block:var(--xdict-space-3, 0.75rem)";

pub(crate) fn presentational(element: &str, name: &str, value: &str, style: &Style) -> Option<String> {
    let element = element.to_ascii_lowercase();
    let font = element == "font";
    let value = value.trim();
    match name {
        // A colour HTML would parse as a legacy colour, outside the palette, goes with nothing in its place.
        "color" if font => Some(colour_attribute(value, Role::Text).map(|c| format!("color:{c}")).unwrap_or_default()),
        "size" if font => font_size_attribute(value),
        "face" if font => Some(format!("font-family:{}", family_for(value, &Facts::plain(), style).unwrap_or(FONT))),
        "align" => match (element.as_str(), value.to_ascii_lowercase().as_str()) {
            ("img", side @ ("left" | "right")) => Some(format!("float:{side}")),
            ("img", v @ ("top" | "middle" | "bottom")) => Some(format!("vertical-align:{v}")),
            (
                "div" | "p" | "td" | "th" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6",
                v @ ("left" | "right" | "center" | "justify"),
            ) => Some(format!("text-align:{v}")),
            _ => None,
        },
        _ => None,
    }
}

/// Whether a presentational attribute is dropped outright (R10, R11, R22, R7).
pub(crate) fn dropped_attribute(element: &str, name: &str) -> bool {
    if matches!(name, "bgcolor" | "background") {
        return true;
    }
    let element = element.to_ascii_lowercase();
    match element.as_str() {
        "table" => matches!(name, "border" | "cellspacing" | "cellpadding" | "frame" | "rules" | "width" | "height"),
        "td" | "th" => matches!(name, "width" | "height"),
        "hr" => matches!(name, "color" | "size" | "noshade" | "width" | "align"),
        "img" => name == "border",
        _ => false,
    }
}

fn colour_attribute(value: &str, role: Role) -> Option<String> {
    let (rgb, len) = colour::literal(value).or_else(|| {
        // HTML's legacy colours are often written without their `#`.
        let hex = format!("#{value}");
        colour::literal(&hex).filter(|(_, n)| *n == hex.len()).map(|(c, _)| (c, value.len()))
    })?;
    (len == value.len()).then(|| colour::mapped(rgb, role, None))
}

/// The `font` shorthand's parts: what precedes the size (style, variant, weight, stretch), the size, the line
/// height, the family. `None` for a system font (`caption`) or a keyword, which have no size to find.
struct Shorthand<'a> {
    before: &'a str,
    size: &'a str,
    line_height: Option<&'a str>,
    family: &'a str,
}

fn shorthand(value: &str) -> Option<Shorthand<'_>> {
    let value = value.trim();
    let tokens = tokens(value);
    let (i, &(start, end)) = tokens.iter().enumerate().find(|(_, (s, e))| {
        let token = value.get(*s..*e).unwrap_or("");
        is_size(token.split('/').next().unwrap_or(""))
    })?;
    let token = value.get(start..end)?;
    let (size, mut height, mut next) = match token.split_once('/') {
        Some((size, h)) if !h.is_empty() => (size, Some(h), i + 1),
        Some((size, _)) => (size, tokens.get(i + 1).and_then(|&(s, e)| value.get(s..e)), i + 2),
        None => (token, None, i + 1),
    };
    if height.is_none()
        && let Some(&(s, e)) = tokens.get(next)
        && let Some(t) = value.get(s..e)
        && let Some(h) = t.strip_prefix('/')
    {
        if h.is_empty() {
            height = tokens.get(next + 1).and_then(|&(s, e)| value.get(s..e));
            next += 2;
        } else {
            height = Some(h);
            next += 1;
        }
    }
    let family_start = tokens.get(next).map(|&(s, _)| s)?;
    Some(Shorthand { before: value.get(..start)?, size, line_height: height, family: value.get(family_start..)? })
}

/// A value's tokens at its top level, split on whitespace outside strings and parentheses: their spans.
fn tokens(value: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = None;
    let mut depth = 0usize;
    let mut quote = None;
    let mut chars = value.char_indices();
    while let Some((i, c)) = chars.next() {
        match quote {
            Some(q) => {
                if c == '\\' {
                    chars.next();
                } else if c == q {
                    quote = None;
                }
                continue;
            }
            None if c == '"' || c == '\'' => quote = Some(c),
            None if c == '(' => depth += 1,
            None if c == ')' => depth = depth.saturating_sub(1),
            None if c.is_whitespace() && depth == 0 => {
                if let Some(s) = start.take() {
                    out.push((s, i));
                }
                continue;
            }
            None => {}
        }
        start.get_or_insert(i);
    }
    if let Some(s) = start {
        out.push((s, value.len()));
    }
    out
}

/// Whether a token is a font size: a length, a percentage, or a size keyword.
fn is_size(token: &str) -> bool {
    const KEYWORDS: [&str; 10] =
        ["xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "smaller", "larger"];
    if KEYWORDS.iter().any(|k| token.eq_ignore_ascii_case(k)) {
        return true;
    }
    let digits = token.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(token.len());
    let unit = token.get(digits..).unwrap_or("");
    digits > 0 && !unit.is_empty() && (unit == "%" || unit.chars().all(|c| c.is_ascii_alphabetic()))
}

/// An absolute length in `px` or `pt`, in pixels.
pub(crate) fn absolute_px(value: &str) -> Option<f64> {
    let value = value.trim();
    let split = value.len().checked_sub(2)?;
    let (number, unit) = (value.get(..split)?, value.get(split..)?);
    let factor = if unit.eq_ignore_ascii_case("px") {
        1.0
    } else if unit.eq_ignore_ascii_case("pt") {
        4.0 / 3.0
    } else {
        return None;
    };
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    let n: f64 = number.parse().ok()?;
    n.is_finite().then_some(n * factor)
}

/// A ratio as CSS writes it: four decimals at most, no trailing zeros.
fn number(x: f64) -> String {
    let s = format!("{x:.4}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-" { "0".to_owned() } else { s.to_owned() }
}

/// A `font-family` list's families: each compared (lower case, unquoted, unescaped, spaces collapsed) and as
/// written (unquoted). Generic families are no dictionary's font, and are left out.
fn families(value: &str) -> Vec<(String, String)> {
    const GENERIC: [&str; 12] = [
        "serif",
        "sans-serif",
        "monospace",
        "cursive",
        "fantasy",
        "system-ui",
        "ui-serif",
        "ui-sans-serif",
        "ui-monospace",
        "ui-rounded",
        "math",
        "emoji",
    ];
    let mut out = Vec::new();
    let mut quote = None;
    let mut start = 0;
    let push = |part: &str, out: &mut Vec<(String, String)>| {
        let unquoted = part.trim().trim_matches(['"', '\'']);
        let written = crate::rewrite::unescaped(unquoted).split_whitespace().collect::<Vec<_>>().join(" ");
        let k = written.to_lowercase();
        if !k.is_empty() && !GENERIC.contains(&k.as_str()) {
            out.push((k, written));
        }
    };
    for (i, c) in value.char_indices() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '"' || c == '\'' => quote = Some(c),
            None if c == ',' => {
                push(value.get(start..i).unwrap_or(""), &mut out);
                start = i + 1;
            }
            None => {}
        }
    }
    push(value.get(start..).unwrap_or(""), &mut out);
    out
}

fn key(family: &str) -> String {
    family.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Whether a `content` value draws a Private Use Area character.
fn private_use(content: &str) -> bool {
    crate::rewrite::unescaped(content)
        .chars()
        .any(|c| matches!(u32::from(c), 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD))
}

/// Whether a `content` value draws a symbol: a character outside letters, digits, spaces and punctuation, from the
/// arrows, shapes, dingbats and symbol blocks (U+2190-2BFF, U+1F000 on) or the Private Use Area. A face drawing only
/// `/`, a bullet or `(` around prose is a prose face (OALECD's Optima, ODE's ODESans), not an icon face.
fn symbol(content: &str) -> bool {
    private_use(content)
        || crate::rewrite::unescaped(content)
            .chars()
            .any(|c| matches!(u32::from(c), 0x2190..=0x2BFF | 0x1F000..=0x1FAFF))
}

fn pseudo_element(selector: &str) -> bool {
    let lower = selector.to_ascii_lowercase();
    [":before", ":after", "::marker"].iter().any(|p| lower.contains(p))
}

/// A selector's words: its names, classes and ids, in lower case.
fn words(selector: &str) -> impl Iterator<Item = String> + '_ {
    selector
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .filter(|w| !w.is_empty())
        .map(str::to_ascii_lowercase)
}

fn phonetic_word(word: String) -> bool {
    word.starts_with("phon") || word.starts_with("pron") || word == "ipa" || word.starts_with("ipa-") || word == "pr"
}

/// Whether a selector is prose, for the base size: no heading, headword, title, pronunciation or pseudo-element.
fn prose(selector: &str) -> bool {
    !pseudo_element(selector)
        && !words(selector).any(|w| {
            matches!(w.as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6")
                || ["hw", "head", "title", "phon", "pron"].iter().any(|p| w.starts_with(p))
        })
}

/// The base size the rules decide ([`BaseFrom`]).
fn base(rules: &[Rule]) -> Base {
    fn size_of(decls: &[(String, String)]) -> Option<&str> {
        decls.iter().rev().find_map(|(n, v)| match n.as_str() {
            "font-size" => Some(v.as_str()),
            "font" => shorthand(v).map(|s| s.size),
            _ => None,
        })
    }
    let mut page = None;
    let mut votes: BTreeMap<u64, u64> = BTreeMap::new();
    let hidden = |r: &Rule| {
        r.decls.iter().any(|(n, v)| {
            let v = v.trim().to_ascii_lowercase();
            (n == "display" && v == "none") || (n == "visibility" && v == "hidden")
        })
    };
    for rule in rules.iter().filter(|r| !r.face && !hidden(r)) {
        let Some(size) = size_of(&rule.decls) else { continue };
        if rule.page {
            let px = absolute_px(size).or_else(|| relative_to_default(size));
            if let Some(px) = px.filter(|p| *p > 0.0) {
                page = Some(Base { px, from: BaseFrom::Page { selector: rule.selector.clone() } });
            }
            continue;
        }
        let Some(px) = absolute_px(size).filter(|p| *p > 0.0) else { continue };
        let weight = rule.selector.split(',').filter(|s| prose(s)).count() as u64;
        if weight > 0 {
            // Hundredths of a pixel, so that 10.5pt and 14px are one size.
            let key = (px * 100.0).round() as u64;
            *votes.entry(key).or_default() += weight;
        }
    }
    if let Some(page) = page {
        return page;
    }
    let distance = |k: u64| (k as f64 / 100.0 - DEFAULT_PX).abs();
    let best = votes.into_iter().max_by(|(ka, wa), (kb, wb)| {
        wa.cmp(wb).then_with(|| distance(*kb).total_cmp(&distance(*ka))).then_with(|| kb.cmp(ka))
    });
    match best {
        Some((k, weight)) => Base { px: k as f64 / 100.0, from: BaseFrom::Prose { weight } },
        None => Base { px: DEFAULT_PX, from: BaseFrom::Default },
    }
}

/// A page size in `em`, `rem` or `%`: relative to a browser's default.
fn relative_to_default(size: &str) -> Option<f64> {
    let size = size.trim().to_ascii_lowercase();
    let (number, factor) = if let Some(n) = size.strip_suffix('%') {
        (n, DEFAULT_PX / 100.0)
    } else {
        (size.strip_suffix("rem").or_else(|| size.strip_suffix("em"))?, DEFAULT_PX)
    };
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    number.parse::<f64>().ok().filter(|n| n.is_finite()).map(|n| n * factor)
}

fn without_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("/*") {
        out.push_str(rest.get(..at).unwrap_or(""));
        rest = rest.get(at + 2..).and_then(|r| r.find("*/").and_then(|e| r.get(e + 2..))).unwrap_or("");
        out.push(' ');
    }
    out.push_str(rest);
    out
}

/// A selector for a report: comments out, spaces collapsed, at most [`SELECTOR_CHARS`] characters.
fn clean_selector(prelude: &str) -> String {
    let clean = without_comments(prelude);
    let collapsed = clean.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.chars().take(SELECTOR_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shorthand_is_read_in_its_parts() {
        let parts = |v| shorthand(v).map(|s| (s.before, s.size, s.line_height, s.family));
        assert_eq!(
            parts("italic bold 12px / 1.5 'A B', serif"),
            Some(("italic bold ", "12px", Some("1.5"), "'A B', serif"))
        );
        assert_eq!(parts("700 12px/18px Arial"), Some(("700 ", "12px", Some("18px"), "Arial")));
        assert!(shorthand("caption").is_none());
        assert!(shorthand("12px").is_none(), "no family: not a shorthand a browser takes");
    }

    #[test]
    fn only_px_and_pt_are_absolute() {
        assert_eq!(absolute_px("12px"), Some(12.0));
        assert_eq!(absolute_px("9pt"), Some(12.0));
        for no in ["1em", "inf", "px", "1e3px", "-2px", "calc(1px)", ""] {
            assert_eq!(absolute_px(no), None, "{no}");
        }
    }
}
