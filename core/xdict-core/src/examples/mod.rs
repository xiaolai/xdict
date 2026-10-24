//! **The reverse-example store** (ADR-0031, plan-reverse-examples WI-2–WI-4): the pairs a rendered entry holds, the
//! per-edition store they are kept in, and the substring scan that answers a Chinese query.
//!
//! Extraction reads the same projection the entry view's text gives (`EntryText`): joined runs with their roles and
//! senses. Two tiers: an `example` run and the `example-trans`/`trans` run after it in the same sense, or one run
//! carrying both scripts; and a sentence-shaped fallback, an English run immediately before a Chinese `trans` run,
//! where the first `trans` of a sense is the definition's own and is passed over.
//!
//! Normalisation is one character to one character (traditional → simplified, full-width → half-width), so a
//! character offset in the normalised text is the same character offset in the printed text; the store keeps both
//! arenas and the scan maps its match back to a UTF-8 byte offset in the printed Chinese.
//!
//! The store is written whole through the core's index storage and renamed by it: derived, disposable, never
//! synced (ADR-0031 d.3). Its header carries the edition, the extractor and the normaliser versions, and an xxh3
//! for each section; a store that does not decode is one to build again, never one to read.

mod t2s;

use std::collections::BTreeMap;

use xdict_mdx::index::Region;

use crate::error::{CoreError, Limit};
use crate::types::TextSpan;

/// The store's format, the extractor's rules and the normalisation table, each its own version: any of them
/// changing rebuilds every store (ADR-0031 d.3, d.5).
pub const FORMAT: u32 = 1;
/// 12 (2026-10-24, the audit-fix pass): the projection reads the renderer's `data-xdict-sure` marks — a kept gloss
/// inside a sure example is apparatus, not the example's English, and a `sure="trans"` block is the translation —
/// so a pair no longer carries the gloss.
///
/// 11 (2026-10-24, the audit-fix pass): a hyphenated word in an abbreviation's expansion carries two initials
/// (`Afro-Asian` spells A and A), so AAJA's expansion is recognised and not stored.
///
/// 10 (2026-10-24, the audit-fix pass): an example no longer merges with the next one across the projection's
/// newline, and the sentence-shaped fallback no longer reaches back into another sense. Both change which pairs
/// exist, so every store is rebuilt.
///
/// 9 (2026-10-24): the v9 audit still found definition and cross-reference spans whose headword is the key with
/// apparatus glued to it (`Ballistic Missile Defense Organization (`, `steer clear of 〈`) or a variant after `=`
/// (`Sepoy Mutiny ＝ Indian Mutiny`); `is_expansion` now compares the key with trailing punctuation trimmed and as a
/// prefix before a variant marker. `clean` also rejects a span opening with a separator (`, especially NAmE`) and one
/// ending in a dangling `*` (a sense-note marker).
///
/// 8 (2026-10-24): the v8 audit found three classes still reaching the store. An abbreviation entry's expansion now
/// starts with its own key (`AAAL abbr. American Academy…`), which defeats an initials test; a headword's own
/// translation sits in the same span as an example (`China wood oil`); and a fragment or dictionary note is neither
/// (`…into sth`, a comma ending nothing, `ORIGIN Originally…`). `is_expansion` rejects the key itself and an `abbr.`
/// marker; `clean` rejects `sb`/`sth` as words, a trailing comma, semicolon or colon, and a note heading.
///
/// 7 (2026-10-24): the projection now keeps an example whole when a link, label or subhead inside it carried its own
/// role (COBUILD's and OALECD's examples began at the first link's end, pairing a sentence's tail with its whole
/// translation), and a translation's nested roles stay the translation's. (6's audit fixes follow.)
///
/// 6 (2026-10-24): the per-dictionary audit found dictionary apparatus glued to examples, example spans split by
/// nested links, spans that begin in the middle of a sentence, definition translations paired beside joined runs, and
/// abbreviation entries' expansions paired as examples. `clean` strips the apparatus and rejects fragments that are
/// not words; `mid_sentence` rejects a span the entry began before, while a label, heading, part of speech, grammar
/// note or pronunciation between a unit's start and its example is a unit start and keeps it; `misaligned` rejects a
/// definition's translation beside a multi-sentence run; and the builder rejects an expansion whose initials spell the
/// key. (5's sentence-count rule was withdrawn before it shipped: it rejected three of every five of cobuild's pairs.)
pub const EXTRACTOR: u32 = 12;
pub const NORMALIZER: u32 = 1;

/// The most pairs one query collects before it stops scanning. A one-character query matches tens of thousands of
/// pairs; the panel shows a page, and the total is reported as capped past this (ADR-0031 d.9).
pub const MAX_HITS: usize = 10_000;

const MAGIC: [u8; 4] = *b"XDEX";
/// `magic`, the three versions, the edition, flags and reserved, five counts (pairs, the two tiers, entries and
/// failures), three arena lengths, four offsets, four checksums and a reserved word.
const HEADER: usize = 192;
/// One pair: three start/length pairs, the record's ordinal and its flags.
const PAIR: usize = 32;
const SENTENCE: u32 = 1;
const ROLES: u32 = 2;

// MARK: - Extraction

/// How a pair was found; the role tier is the more precise one, and wins a duplicate within an entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Tier {
    Roles,
    Fallback,
}

/// One pair as extraction found it, before it enters a store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Pair {
    pub english: String,
    pub chinese: String,
    /// A full sentence rather than a phrase (the plan's owner decision 3).
    pub sentence: bool,
    pub tier: Tier,
}

/// One run of the entry's text: adjacent runs of the same role and sense are joined, because an example is dozens of
/// one-word runs in the projection and it is one example.
struct Seg<'a> {
    role: &'a str,
    start: usize,
    end: usize,
    sense: Option<u32>,
}

fn segments<'a>(text: &'a str, spans: &'a [TextSpan]) -> Vec<Seg<'a>> {
    let mut out: Vec<Seg<'a>> = Vec::new();
    for span in spans {
        let start = span.start as usize;
        let Some(end) = start.checked_add(span.len as usize) else { continue };
        if end > text.len() || !text.is_char_boundary(start) || !text.is_char_boundary(end) {
            continue;
        }
        if text.get(start..end).is_none_or(|run| run.trim().is_empty()) {
            continue;
        }
        let role = span.role.as_deref().unwrap_or("");
        // A newline between the runs is the projection's block boundary: two examples of one sense, one per block,
        // must not merge into one run, or the first pair would swallow the second example (audit, 2026-10-24).
        let same_block = text.get(out.last().map_or(0, |last| last.end)..start).is_none_or(|gap| !gap.contains('\n'));
        match out.last_mut() {
            Some(last) if last.role == role && last.sense == span.sense && same_block => last.end = end,
            _ => out.push(Seg { role, start, end, sense: span.sense }),
        }
    }
    out
}

/// **Both tiers over one entry's text** (ADR-0031 d.2). Duplicates within the entry are collapsed, the role tier
/// winning: the same sentence found by both tiers is one pair.
pub(crate) fn extract(text: &str, spans: &[TextSpan]) -> Vec<Pair> {
    let segs = segments(text, spans);
    let mut out = Vec::new();
    for pair in by_roles(&segs, text) {
        push(&mut out, pair);
    }
    for pair in by_fallback(&segs, text) {
        push(&mut out, pair);
    }
    out.retain(|pair| !misaligned(&pair.english, &pair.chinese));
    out
}

/// **A definition's translation beside a joined run** (the audit, 2026-10-24): the Chinese carries a definition's
/// bracket (`〔…〕` or `【…】`) and the English prints at least two sentences — the role pass joined several examples
/// and the sense's definition translation was paired with them. A run whose Chinese translates its examples is kept:
/// counting sentence marks alone rejected three of every five of cobuild's pairs.
fn misaligned(english: &str, chinese: &str) -> bool {
    (chinese.contains('〔') || chinese.contains('【')) && sentence_ends(english) >= 2
}

fn sentence_ends(text: &str) -> usize {
    text.chars().filter(|c| matches!(c, '.' | '?' | '!' | '…' | '。' | '？' | '！')).count()
}

/// **An abbreviation entry's expansion, not an example** (the audit, 2026-10-24): the key is all capitals and the
/// English's initials, its function words aside, spell it — `AAAL` and "American Academy of Arts and Letters". yhdcd's
/// seven such pairs carried the expansion's definition translation.
pub(crate) fn is_expansion(key: &str, english: &str) -> bool {
    // A headword printed with its own translation is a definition, not an example (d.1), and an abbreviation's
    // expansion is its definition however it is labelled (extractor 8). A definition or cross-reference often glues
    // apparatus to the headword (`steer clear of 〈`, `Ballistic Missile Defense Organization (`) or names a variant
    // with `=` (`lay one's hand on the table ＝ show one's hand`), so the key is compared with trailing punctuation
    // trimmed and as a prefix before a variant marker (extractor 9).
    let trim = |text: &str| text.trim().trim_end_matches(|c: char| !c.is_alphanumeric()).to_owned();
    let key_trim = trim(key);
    if !key_trim.is_empty() && key_trim.eq_ignore_ascii_case(&trim(english)) {
        return true;
    }
    let lower_key = key_trim.to_ascii_lowercase();
    if let Some(rest) = english.to_ascii_lowercase().strip_prefix(&lower_key)
        && rest.trim_start().starts_with(['=', '＝'])
    {
        return true;
    }
    if english
        .split_whitespace()
        .any(|word| word.trim_matches(|c: char| !c.is_ascii_alphabetic()).eq_ignore_ascii_case("abbr"))
    {
        return true;
    }
    let letters: Vec<char> = key.chars().filter(|c: &char| c.is_ascii_alphabetic()).collect();
    if letters.len() < 2 || !letters.iter().all(|c: &char| c.is_ascii_uppercase()) {
        return false;
    }
    const FUNCTION: [&str; 11] = ["of", "for", "the", "and", "in", "on", "to", "with", "a", "an", "&"];
    let initials: Vec<char> = english
        // A hyphenated word carries two initials: `Afro-Asian` spells A and A, the reason AAJA's expansion reached
        // the store (the v11 audit, 2026-10-24).
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter_map(|word| {
            let word = word.trim_matches(|c: char| !c.is_alphabetic()).to_lowercase();
            if word.is_empty() || FUNCTION.contains(&word.as_str()) {
                None
            } else {
                word.chars().next().map(|c| c.to_ascii_uppercase())
            }
        })
        .collect();
    initials == letters
}

fn push(out: &mut Vec<Pair>, pair: Pair) {
    // The role tier is inserted whole before the fallback runs, so an existing duplicate is always the role pair
    // and the fallback copy is simply dropped (the audit found the old fallback-to-role promotion unreachable).
    if out.iter().any(|p| p.english == pair.english && p.chinese == pair.chinese) {
        return;
    }
    out.push(pair);
}

/// Whether a run begins in the middle of a unit: the run before it belongs to the same sense and does not start a
/// unit (a label, a definition, a sense number, a translation or another example), and the character before the run
/// (spaces aside) is a Latin letter, a digit, a comma, a dash or an opening bracket. Such a span is a sentence's tail,
/// whose Chinese translation covers the whole sentence, so it is not a pair (the audit, 2026-10-24).
fn mid_sentence(text: &str, previous: Option<&Seg<'_>>, seg: &Seg<'_>) -> bool {
    let Some(previous) = previous else { return false };
    if previous.sense != seg.sense
        || matches!(
            previous.role,
            "label"
                | "heading"
                | "subhead"
                | "pos"
                | "gram"
                | "pron"
                | "sensenum"
                | "def"
                | "trans"
                | "example-trans"
                | "example"
                | "sense"
        )
    {
        return false;
    }
    let Some(prefix) = text.get(..seg.start) else { return false };
    let trimmed = prefix.trim_end_matches(char::is_whitespace);
    trimmed
        .chars()
        .last()
        // A Latin letter or digit: a word the span starts inside. A Chinese character before it is the previous
        // line's translation, and the English after it begins a line of its own.
        .is_some_and(|last| last.is_ascii_alphanumeric() || matches!(last, ',' | ';' | '-' | '—' | '('))
}

/// An `example` run and the `example-trans`/`trans` run after it in the same sense, or one run carrying both scripts.
fn by_roles(segs: &[Seg<'_>], text: &str) -> Vec<Pair> {
    let mut out = Vec::new();
    for (i, seg) in segs.iter().enumerate() {
        let previous = i.checked_sub(1).and_then(|j| segs.get(j));
        if seg.role != "example" || mid_sentence(text, previous, seg) {
            continue;
        }
        let Some(run) = text.get(seg.start..seg.end) else { continue };
        match run.char_indices().find(|(_, c)| cjk(*c)) {
            Some((at, _)) => {
                let (en, zh) = run.split_at(at);
                if has_cjk(zh)
                    && let Some(english) = clean(en)
                    && latin_words(&english) >= 2
                {
                    let sentence = sentence_like(&english);
                    out.push(Pair { english, chinese: zh.trim().to_owned(), sentence, tier: Tier::Roles });
                }
            }
            None => {
                let Some(english) = clean(run) else { continue };
                if latin_words(&english) < 2 {
                    continue;
                }
                for next in segs.iter().skip(i + 1).take(12) {
                    if next.role == "example" || next.sense != seg.sense {
                        break;
                    }
                    if (next.role == "example-trans" || next.role == "trans")
                        && text.get(next.start..next.end).is_some_and(|r| cjk_share(r) >= 0.5)
                        && let Some(zh) = text.get(next.start..next.end)
                    {
                        let sentence = sentence_like(&english);
                        out.push(Pair {
                            english: english.clone(),
                            chinese: zh.trim().to_owned(),
                            sentence,
                            tier: Tier::Roles,
                        });
                        break;
                    }
                }
            }
        }
    }
    out
}

/// The generic fallback: a Chinese run and the English run immediately before it, where the English is
/// sentence-shaped and the Chinese is not a parenthesised gloss. The first `trans` of a sense is the definition's
/// own translation, so it and every first one are passed over (the spike's rule, ADR-0031 d.2).
fn by_fallback(segs: &[Seg<'_>], text: &str) -> Vec<Pair> {
    let mut out = Vec::new();
    let mut seen_trans: BTreeMap<Option<u32>, usize> = BTreeMap::new();
    for (i, seg) in segs.iter().enumerate() {
        let Some(run) = text.get(seg.start..seg.end) else { continue };
        if cjk_share(run) < 0.5 || (seg.role != "trans" && seg.role != "example-trans") {
            continue;
        }
        let seen = seen_trans.entry(seg.sense).or_insert(0);
        *seen += 1;
        if *seen == 1 {
            continue;
        }
        // The nearest English run before it, with nothing Chinese in between.
        let mut j = i;
        while j > 0 {
            j -= 1;
            let Some(prev) = segs.get(j) else { break };
            // A pair never crosses a sense: an English run in another sense belongs to another definition, and a
            // translation in this sense is not its translation (audit, 2026-10-24).
            if prev.sense != seg.sense {
                break;
            }
            let Some(prev_run) = text.get(prev.start..prev.end) else { break };
            if cjk_share(prev_run) >= 0.5 {
                break;
            }
            if latin_words(prev_run) >= 2 {
                if mid_sentence(text, j.checked_sub(1).and_then(|k| segs.get(k)), prev) {
                    break;
                }
                if !run.trim_start().starts_with(['（', '('])
                    && let Some(english) = clean(prev_run)
                    && sentence_like(&english)
                {
                    out.push(Pair { english, chinese: run.trim().to_owned(), sentence: true, tier: Tier::Fallback });
                }
                break;
            }
        }
    }
    out
}

fn cjk(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F)
}

pub(crate) fn has_cjk(text: &str) -> bool {
    text.chars().any(cjk)
}

fn cjk_share(text: &str) -> f64 {
    let total = text.chars().filter(|c| !c.is_whitespace()).count();
    if total == 0 {
        return 0.0;
    }
    text.chars().filter(|c| cjk(*c)).count() as f64 / total as f64
}

fn latin_words(text: &str) -> usize {
    text.split_whitespace().filter(|w| w.chars().any(|c| c.is_ascii_alphabetic())).count()
}

/// An example sentence, not a definition: it starts like one (a capital, a wildcard or a quote) and ends like one.
/// A closing quote or bracket after the full stop belongs to the sentence, not after it.
fn sentence_like(text: &str) -> bool {
    let trimmed = text.trim_start();
    let starts = trimmed.starts_with('~')
        || trimmed.chars().next().is_some_and(|c| c.is_uppercase() || c == '“' || c == '"' || c == '‘');
    let end = text.trim_end().trim_end_matches(['”', '"', '’', '\'', '）', ')', ']', '」', '』', '》']);
    let ends = end.chars().last().is_some_and(|c| matches!(c, '.' | '?' | '!' | '…'));
    starts && ends
}

/// Grammar labels a dictionary glues to an example (`as adv.`, `count noun`, `with obj.`): not the example's own and
/// not translated, so the pair begins after them.
const LABELS: &[&str] = &[
    "as predic. adj.",
    "as predic. adj",
    "as predicative adj.",
    "as submodifier",
    "as modifier",
    "as adv.",
    "as adv",
    "as adj.",
    "as adj",
    "as name",
    "count noun",
    "with obj.",
    "with clause",
    "postpositive",
    "no object, with adverbial of direction",
];

fn strip_label(text: &str) -> String {
    let lower = text.to_lowercase();
    for label in LABELS {
        if lower.starts_with(label) {
            return text.get(label.len()..).unwrap_or("").trim_start_matches([' ', '.', ',', '·']).trim().to_owned();
        }
    }
    text.to_owned()
}

/// A parenthetical gloss the dictionary appends (` (= made the water come out)`): the Chinese translates the example,
/// not the gloss.
fn strip_gloss(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find(" (=") {
        out.push_str(rest.get(..at).unwrap_or(""));
        if let Some(close) = rest.get(at..).and_then(|tail| tail.find(')')) {
            rest = rest.get(at + close + 1..).unwrap_or("");
        } else {
            rest = "";
        }
    }
    out.push_str(rest);
    out.trim().to_owned()
}

/// **The example as a pair may use it** (2026-10-24, the per-dictionary audit): dictionary apparatus stripped; a
/// fragment that is not words (`d sharply`, `ed by nomads`), a gloss alone, a bullet-joined run, an English holding a
/// definition's shorthand (`sb/sth`) or an element over the role pass's own 500-character ceiling is not a pair. A
/// lower-case sentence is kept: ODECN writes its examples so.
fn clean(english: &str) -> Option<String> {
    let stripped = strip_gloss(&strip_label(english));
    let text = stripped.trim();
    if text.is_empty() || text.chars().count() > 500 || text.contains('·') || text.starts_with(['(', ')']) {
        return None;
    }
    // A span that opens with a separator is the tail of a sentence (` , especially NAmE`), and a dangling `*` marks
    // the next sense's note, not the end of an example (extractor 9).
    if text.starts_with([',', ';', ':', '，', '；', '：']) || text.ends_with('*') {
        return None;
    }
    const NOTE_HEADINGS: [&str; 6] = ["ORIGIN ", "WORD ORIGIN ", "HELP ", "GRAMMAR ", "USAGE ", "NOTE "];
    if NOTE_HEADINGS.iter().any(|heading| text.starts_with(heading)) || text.ends_with([',', ';', ':']) {
        return None;
    }
    // `sb` and `sth` are the dictionary's placeholders, not words (extractor 8): `…into sth` is a pattern, and a
    // span containing one is usually a grammar note or a fragment of one.
    if text
        .split(|c: char| !c.is_alphabetic())
        .any(|word| word.eq_ignore_ascii_case("sb") || word.eq_ignore_ascii_case("sth"))
    {
        return None;
    }
    let first = text.split_whitespace().next()?;
    let first = first.trim_matches(|c: char| c.is_ascii_punctuation() && !matches!(c, '\'' | '"' | '“' | '‘'));
    if first.len() == 1 && first.chars().all(|c| c.is_ascii_alphabetic()) && !matches!(first, "a" | "A" | "I") {
        return None;
    }
    if matches!(first.to_ascii_lowercase().as_str(), "ed" | "ing" | "ly" | "ion" | "ies" | "ied" | "es") {
        return None;
    }
    Some(text.to_owned())
}

// MARK: - Normalisation

/// Traditional → simplified and full-width → half-width, one character to one character (ADR-0031 d.5). Applied to
/// both the stored Chinese and the query, so a reader typing simplified finds a dictionary printed in traditional.
pub(crate) fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let mapped = t2s::T2S
            .binary_search_by_key(&c, |&(traditional, _)| traditional)
            .ok()
            .and_then(|i| t2s::T2S.get(i))
            .map_or_else(|| halfwidth(c), |&(_, simplified)| simplified);
        out.push(mapped);
    }
    out
}

fn halfwidth(c: char) -> char {
    match c {
        '\u{3000}' => ' ',
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        _ => c,
    }
}

// MARK: - The store

/// One pair's record in the store, read from its 32 bytes.
#[derive(Debug, Clone, Copy)]
struct Record {
    zh_start: usize,
    zh_len: usize,
    norm_start: usize,
    norm_len: usize,
    en_start: usize,
    en_len: usize,
    ordinal: u32,
    flags: u32,
}

/// A pair a scan found, with its match in the **printed** Chinese as UTF-8 byte offsets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Found {
    pub english: String,
    pub chinese: String,
    pub start: u64,
    pub len: u64,
    pub sentence: bool,
    pub ordinal: u32,
}

/// A decoded store: the four sections, after their checksums held and the header named this edition and these
/// versions.
pub(crate) struct Store {
    pairs: Vec<u8>,
    zh: Vec<u8>,
    norm: Vec<u8>,
    en: Vec<u8>,
    count: usize,
    pub roles: u64,
    pub fallback: u64,
    pub entries: u64,
    pub failed: u64,
    pub no_chinese: bool,
}

impl Store {
    /// Decodes `region`, or `None` when it is not this edition's store of these versions, is truncated, or a
    /// section's checksum does not hold: a store that does not decode is one to build again, never one to read.
    pub(crate) fn decode(region: &dyn Region, edition: &[u8; 32]) -> Option<Self> {
        let head = region.bytes(0, HEADER).ok()?;
        let header = Header::parse(&head, edition)?;
        let section = |offset: usize, len: usize| -> Option<Vec<u8>> {
            let offset = u64::try_from(offset).ok()?;
            region.bytes(offset, len).ok().map(std::borrow::Cow::into_owned)
        };
        let pairs = section(header.pairs_offset, header.pairs_len)?;
        let zh = section(header.zh_offset, header.zh_len)?;
        let norm = section(header.norm_offset, header.norm_len)?;
        let en = section(header.en_offset, header.en_len)?;
        if xxhash_rust::xxh3::xxh3_64(&pairs) != header.pairs_sum
            || xxhash_rust::xxh3::xxh3_64(&zh) != header.zh_sum
            || xxhash_rust::xxh3::xxh3_64(&norm) != header.norm_sum
            || xxhash_rust::xxh3::xxh3_64(&en) != header.en_sum
        {
            return None;
        }
        let store = Self {
            pairs,
            zh,
            norm,
            en,
            count: header.count,
            roles: header.roles,
            fallback: header.fallback,
            entries: header.entries,
            failed: header.failed,
            no_chinese: header.no_chinese,
        };
        // A checksum proves the bytes are the ones written, not that the records point where the scan assumes: a
        // store edited and re-checksummed is still disk input. Bounds, UTF-8, the printed/normalised character
        // counts and the contiguous normalised arena are checked before any record is read (audit, 2026-10-24).
        store.validate().then_some(store)
    }

    /// Every record's ranges lie inside its arena and are UTF-8; the printed and normalised Chinese hold the same
    /// number of characters (the offset mapping's premise); and the normalised arena is contiguous and in store
    /// order (`pair_at`'s binary search's premise).
    fn validate(&self) -> bool {
        let Some(expected) = self.count.checked_mul(PAIR) else { return false };
        if self.pairs.len() != expected {
            return false;
        }
        let mut next_norm = 0usize;
        for i in 0..self.count {
            let Some(record) = self.record(i) else { return false };
            let Some(zh) = self.text(&self.zh, record.zh_start, record.zh_len) else { return false };
            let Some(norm) = self.text(&self.norm, record.norm_start, record.norm_len) else { return false };
            if self.text(&self.en, record.en_start, record.en_len).is_none() || zh.is_empty() {
                return false;
            }
            if zh.chars().count() != norm.chars().count() || record.norm_start != next_norm {
                return false;
            }
            next_norm = record.norm_start.saturating_add(record.norm_len);
        }
        next_norm == self.norm.len()
    }

    pub(crate) fn len(&self) -> usize {
        self.count
    }

    fn record(&self, i: usize) -> Option<Record> {
        let at = i.checked_mul(PAIR)?;
        let bytes = self.pairs.get(at..at.checked_add(PAIR)?)?;
        Some(Record {
            zh_start: usize::try_from(u32_at(bytes, 0)?).ok()?,
            zh_len: usize::try_from(u32_at(bytes, 4)?).ok()?,
            norm_start: usize::try_from(u32_at(bytes, 8)?).ok()?,
            norm_len: usize::try_from(u32_at(bytes, 12)?).ok()?,
            en_start: usize::try_from(u32_at(bytes, 16)?).ok()?,
            en_len: usize::try_from(u32_at(bytes, 20)?).ok()?,
            ordinal: u32_at(bytes, 24)?,
            flags: u32_at(bytes, 28)?,
        })
    }

    /// The pair whose normalised Chinese contains `offset`, by binary search over the arena's records (each pair's
    /// Chinese is stored whole, in record order).
    fn pair_at(&self, offset: usize) -> Option<usize> {
        let (mut low, mut high) = (0usize, self.count);
        while low < high {
            let mid = low + (high - low) / 2;
            let record = self.record(mid)?;
            if record.norm_start <= offset {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let i = low.checked_sub(1)?;
        let record = self.record(i)?;
        (offset < record.norm_start.checked_add(record.norm_len)?).then_some(i)
    }

    fn text<'a>(&'a self, arena: &'a [u8], start: usize, len: usize) -> Option<&'a str> {
        std::str::from_utf8(arena.get(start..start.checked_add(len)?)?).ok()
    }

    /// One pair as the store holds it, in store order: for the per-dictionary audit (ADR-0031 d.8).
    pub(crate) fn pair(&self, i: usize) -> Option<(String, String, bool, u32)> {
        let record = self.record(i)?;
        let zh = self.text(&self.zh, record.zh_start, record.zh_len)?;
        let en = self.text(&self.en, record.en_start, record.en_len)?;
        Some((en.to_owned(), zh.to_owned(), record.flags & SENTENCE != 0, record.ordinal))
    }

    /// **The scan** (ADR-0031 d.4): one hit per pair whose normalised Chinese contains `needle`, up to `cap`,
    /// mapped to its pair and to the first match's UTF-8 byte offsets in the printed Chinese.
    ///
    /// One hit per pair, not one per occurrence: the panel shows the pair once, and cloning its text per occurrence
    /// would let one long translation with thousands of matches allocate its own length thousands of times (audit,
    /// 2026-10-24). A match that begins in one pair and ends in the next is rejected and the search resumes one
    /// character later, so the valid match that shares its first character is still found.
    pub(crate) fn scan(&self, needle: &str, cap: usize) -> Vec<Found> {
        let mut out = Vec::new();
        if needle.is_empty() || cap == 0 {
            return out;
        }
        let Ok(norm) = std::str::from_utf8(&self.norm) else { return out };
        let chars = needle.chars().count();
        let mut from = 0usize;
        while out.len() < cap {
            let Some(found) = norm.get(from..).and_then(|rest| rest.find(needle)) else { break };
            let at = from + found;
            let Some(i) = self.pair_at(at) else {
                match norm.get(at..).and_then(|rest| rest.chars().next()) {
                    Some(c) => from = at + c.len_utf8(),
                    None => break,
                }
                continue;
            };
            let Some(record) = self.record(i) else { break };
            let Some(end) = at.checked_add(needle.len()) else { break };
            let record_end = record.norm_start.saturating_add(record.norm_len);
            if end > record_end {
                let Some(c) = norm.get(at..).and_then(|rest| rest.chars().next()) else { break };
                from = at + c.len_utf8();
                continue;
            }
            let Some(zh) = self.text(&self.zh, record.zh_start, record.zh_len) else {
                from = record_end;
                continue;
            };
            let Some(en) = self.text(&self.en, record.en_start, record.en_len) else {
                from = record_end;
                continue;
            };
            // Character offsets, not byte offsets: 168 mappings change a character's UTF-8 width, so only the
            // character index survives the normalisation.
            let Some(local) = norm.get(record.norm_start..at) else {
                from = record_end;
                continue;
            };
            let index = local.chars().count();
            let Some(start) = zh.char_indices().nth(index).map(|(byte, _)| byte) else {
                from = record_end;
                continue;
            };
            let len: usize = zh.chars().skip(index).take(chars).map(char::len_utf8).sum();
            out.push(Found {
                english: en.to_owned(),
                chinese: zh.to_owned(),
                start: start as u64,
                len: len as u64,
                sentence: record.flags & SENTENCE != 0,
                ordinal: record.ordinal,
            });
            from = record_end;
        }
        out
    }
}

/// The store's header, read and checked.
struct Header {
    count: usize,
    roles: u64,
    fallback: u64,
    entries: u64,
    failed: u64,
    no_chinese: bool,
    pairs_offset: usize,
    pairs_len: usize,
    zh_offset: usize,
    zh_len: usize,
    norm_offset: usize,
    norm_len: usize,
    en_offset: usize,
    en_len: usize,
    pairs_sum: u64,
    zh_sum: u64,
    norm_sum: u64,
    en_sum: u64,
}

impl Header {
    fn parse(bytes: &[u8], edition: &[u8; 32]) -> Option<Self> {
        if bytes.get(0..4)? != MAGIC || bytes.get(16..48)? != edition {
            return None;
        }
        if u32_at(bytes, 4)? != FORMAT || u32_at(bytes, 8)? != EXTRACTOR || u32_at(bytes, 12)? != NORMALIZER {
            return None;
        }
        let count = usize::try_from(u64_at(bytes, 56)?).ok()?;
        let pairs_len = count.checked_mul(PAIR)?;
        let pairs_offset = usize::try_from(u64_at(bytes, 120)?).ok()?;
        let zh_offset = usize::try_from(u64_at(bytes, 128)?).ok()?;
        let norm_offset = usize::try_from(u64_at(bytes, 136)?).ok()?;
        let en_offset = usize::try_from(u64_at(bytes, 144)?).ok()?;
        let zh_len = usize::try_from(u64_at(bytes, 96)?).ok()?;
        let norm_len = usize::try_from(u64_at(bytes, 104)?).ok()?;
        let en_len = usize::try_from(u64_at(bytes, 112)?).ok()?;
        // The sections are contiguous, after the header, in this order: anything else is not this writer's store.
        if pairs_offset != HEADER
            || zh_offset != pairs_offset.checked_add(pairs_len)?
            || norm_offset != zh_offset.checked_add(zh_len)?
            || en_offset != norm_offset.checked_add(norm_len)?
        {
            return None;
        }
        Some(Self {
            count,
            roles: u64_at(bytes, 64)?,
            fallback: u64_at(bytes, 72)?,
            entries: u64_at(bytes, 80)?,
            failed: u64_at(bytes, 88)?,
            no_chinese: u32_at(bytes, 48)? & 1 == 1,
            pairs_offset,
            pairs_len,
            zh_offset,
            zh_len,
            norm_offset,
            norm_len,
            en_offset,
            en_len,
            pairs_sum: u64_at(bytes, 152)?,
            zh_sum: u64_at(bytes, 160)?,
            norm_sum: u64_at(bytes, 168)?,
            en_sum: u64_at(bytes, 176)?,
        })
    }
}

/// Builds a store's sections as pairs arrive, then writes them whole.
pub(crate) struct Builder {
    zh: Vec<u8>,
    norm: Vec<u8>,
    en: Vec<u8>,
    pairs: Vec<u8>,
    count: usize,
    roles: u64,
    fallback: u64,
}

impl Builder {
    pub(crate) fn new() -> Self {
        Self { zh: Vec::new(), norm: Vec::new(), en: Vec::new(), pairs: Vec::new(), count: 0, roles: 0, fallback: 0 }
    }

    pub(crate) fn len(&self) -> usize {
        self.count
    }

    pub(crate) fn roles(&self) -> u64 {
        self.roles
    }

    pub(crate) fn fallback(&self) -> u64 {
        self.fallback
    }

    pub(crate) fn push(&mut self, ordinal: u32, pair: &Pair) -> Result<(), CoreError> {
        let zh_start = fit(self.zh.len())?;
        let zh_len = fit(pair.chinese.len())?;
        let norm = normalize(&pair.chinese);
        let norm_start = fit(self.norm.len())?;
        let norm_len = fit(norm.len())?;
        let en_start = fit(self.en.len())?;
        let en_len = fit(pair.english.len())?;
        self.zh.extend_from_slice(pair.chinese.as_bytes());
        self.norm.extend_from_slice(norm.as_bytes());
        self.en.extend_from_slice(pair.english.as_bytes());
        put_u32(&mut self.pairs, zh_start);
        put_u32(&mut self.pairs, zh_len);
        put_u32(&mut self.pairs, norm_start);
        put_u32(&mut self.pairs, norm_len);
        put_u32(&mut self.pairs, en_start);
        put_u32(&mut self.pairs, en_len);
        put_u32(&mut self.pairs, ordinal);
        let flags = (if pair.sentence { SENTENCE } else { 0 }) | (if pair.tier == Tier::Roles { ROLES } else { 0 });
        put_u32(&mut self.pairs, flags);
        self.count += 1;
        match pair.tier {
            Tier::Roles => self.roles += 1,
            Tier::Fallback => self.fallback += 1,
        }
        Ok(())
    }

    /// The store's bytes: header, pairs, the three arenas, each with its own xxh3.
    pub(crate) fn finish(
        self,
        edition: [u8; 32],
        entries: u64,
        failed: u64,
        no_chinese: bool,
    ) -> Result<Vec<u8>, CoreError> {
        let count = u64::try_from(self.count).map_err(|_| CoreError::internal("more pairs than a u64 holds"))?;
        let pairs_offset = HEADER as u64;
        let zh_offset = pairs_offset + self.pairs.len() as u64;
        let norm_offset = zh_offset + self.zh.len() as u64;
        let en_offset = norm_offset + self.norm.len() as u64;
        let mut out = Vec::with_capacity(en_offset as usize + self.en.len());
        out.extend_from_slice(&MAGIC);
        put_u32(&mut out, FORMAT);
        put_u32(&mut out, EXTRACTOR);
        put_u32(&mut out, NORMALIZER);
        out.extend_from_slice(&edition);
        put_u32(&mut out, u32::from(no_chinese));
        put_u32(&mut out, 0);
        put_u64(&mut out, count);
        put_u64(&mut out, self.roles);
        put_u64(&mut out, self.fallback);
        put_u64(&mut out, entries);
        put_u64(&mut out, failed);
        put_u64(&mut out, self.zh.len() as u64);
        put_u64(&mut out, self.norm.len() as u64);
        put_u64(&mut out, self.en.len() as u64);
        put_u64(&mut out, pairs_offset);
        put_u64(&mut out, zh_offset);
        put_u64(&mut out, norm_offset);
        put_u64(&mut out, en_offset);
        put_u64(&mut out, xxhash_rust::xxh3::xxh3_64(&self.pairs));
        put_u64(&mut out, xxhash_rust::xxh3::xxh3_64(&self.zh));
        put_u64(&mut out, xxhash_rust::xxh3::xxh3_64(&self.norm));
        put_u64(&mut out, xxhash_rust::xxh3::xxh3_64(&self.en));
        put_u64(&mut out, 0);
        if out.len() != HEADER {
            return Err(CoreError::internal(format!("an examples header of {} bytes", out.len())));
        }
        out.extend_from_slice(&self.pairs);
        out.extend_from_slice(&self.zh);
        out.extend_from_slice(&self.norm);
        out.extend_from_slice(&self.en);
        Ok(out)
    }
}

fn fit(len: usize) -> Result<u32, CoreError> {
    u32::try_from(len).map_err(|_| CoreError::TooLarge {
        limit: Limit::File,
        detail: format!("an examples arena or record passed {len} bytes"),
    })
}

fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    let end = at.checked_add(4)?;
    Some(u32::from_le_bytes(bytes.get(at..end)?.try_into().ok()?))
}

fn u64_at(bytes: &[u8], at: usize) -> Option<u64> {
    let end = at.checked_add(8)?;
    Some(u64::from_le_bytes(bytes.get(at..end)?.try_into().ok()?))
}

fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_le_bytes());
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]
mod tests {
    use super::*;

    /// An entry's text and spans from (run, role, sense) parts, in order.
    fn runs(parts: &[(&str, &str, Option<u32>)]) -> (String, Vec<TextSpan>) {
        let mut text = String::new();
        let mut spans = Vec::new();
        for (run, role, sense) in parts {
            let start = text.len();
            text.push_str(run);
            spans.push(TextSpan {
                start: start as u64,
                len: run.len() as u64,
                role: (!role.is_empty()).then(|| (*role).to_owned()),
                label: None,
                section: None,
                sense: *sense,
            });
        }
        (text, spans)
    }

    #[test]
    fn two_elements_pair_by_their_roles() {
        let (text, spans) = runs(&[
            ("Who could have considered such a possibility?", "example", Some(0)),
            ("谁居然会想到这种可能性？", "example-trans", Some(0)),
        ]);
        let pairs = extract(&text, &spans);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].english, "Who could have considered such a possibility?");
        assert_eq!(pairs[0].chinese, "谁居然会想到这种可能性？");
        assert!(pairs[0].sentence);
        assert_eq!(pairs[0].tier, Tier::Roles);
    }

    #[test]
    fn one_element_with_both_scripts_pairs_and_splits_at_the_first_chinese() {
        let (text, spans) =
            runs(&[("Who could have considered such a possibility? 谁居然会想到这种可能性？", "example", Some(0))]);
        let pairs = extract(&text, &spans);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].english, "Who could have considered such a possibility?");
        assert_eq!(pairs[0].chinese, "谁居然会想到这种可能性？");
        assert!(pairs[0].sentence);
    }

    #[test]
    fn a_translation_in_another_sense_is_not_paired() {
        let (text, spans) = runs(&[
            ("She runs to school every day.", "example", Some(0)),
            ("她每天跑步去学校。", "example-trans", Some(1)),
        ]);
        assert!(extract(&text, &spans).is_empty());
    }

    #[test]
    fn chinese_before_english_is_not_a_reversed_pair() {
        let (text, spans) = runs(&[
            ("谁居然会想到这种可能性？", "example-trans", Some(0)),
            ("Who could have considered such a possibility?", "example", Some(0)),
        ]);
        assert!(extract(&text, &spans).is_empty());
    }

    #[test]
    fn a_definition_translation_is_not_an_example() {
        let (text, spans) = runs(&[("to move fast", "def", Some(0)), ("快速移动", "trans", Some(0))]);
        assert!(extract(&text, &spans).is_empty());
    }

    #[test]
    fn a_lower_case_definition_is_not_sentence_shaped() {
        let (text, spans) = runs(&[
            ("used before countable nouns", "def", Some(0)),
            ("用于可数名词前", "trans", Some(0)),
            ("this is not an example sentence.", "", Some(0)),
            ("这不是例句。", "trans", Some(0)),
        ]);
        assert!(extract(&text, &spans).is_empty());
    }

    #[test]
    fn the_fallback_pairs_a_sentence_with_the_english_before_it() {
        let (text, spans) = runs(&[
            ("to move fast", "def", Some(0)),
            ("快速移动", "trans", Some(0)),
            ("She runs to school every day.", "", Some(0)),
            ("她每天跑步去学校。", "trans", Some(0)),
        ]);
        let pairs = extract(&text, &spans);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].english, "She runs to school every day.");
        assert_eq!(pairs[0].chinese, "她每天跑步去学校。");
        assert!(pairs[0].sentence);
        assert_eq!(pairs[0].tier, Tier::Fallback);
    }

    #[test]
    fn a_parenthesised_gloss_is_not_paired() {
        let (text, spans) = runs(&[
            ("to move fast", "def", Some(0)),
            ("快速移动", "trans", Some(0)),
            ("She runs to school every day.", "", Some(0)),
            ("（某人）跑", "trans", Some(0)),
        ]);
        assert!(extract(&text, &spans).is_empty());
    }

    #[test]
    fn a_phrase_is_paired_and_marked() {
        let (text, spans) = runs(&[("take off", "example", Some(0)), ("起飞", "example-trans", Some(0))]);
        let pairs = extract(&text, &spans);
        assert_eq!(pairs.len(), 1);
        assert!(!pairs[0].sentence);
    }

    #[test]
    fn the_role_tier_wins_a_duplicate() {
        let (text, spans) = runs(&[
            ("to move fast", "def", Some(0)),
            ("快速移动", "trans", Some(0)),
            ("She runs to school every day.", "example", Some(0)),
            ("她每天跑步去学校。", "example-trans", Some(0)),
        ]);
        let pairs = extract(&text, &spans);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].tier, Tier::Roles);
    }

    #[test]
    fn sentence_shapes() {
        assert!(sentence_like("Who could have considered such a possibility?"));
        assert!(sentence_like("“Quoted.”"));
        assert!(sentence_like("~ off."));
        assert!(!sentence_like("used before countable nouns"));
        assert!(!sentence_like("take off"));
    }

    #[test]
    fn a_span_that_begins_mid_sentence_is_not_a_pair() {
        let (text, spans) = runs(&[
            ("She brake", "headword", Some(0)),
            ("d sharply to avoid another car.", "example", Some(0)),
            ("她为了躲另一辆车而紧急刹车。", "example-trans", Some(0)),
        ]);
        assert!(extract(&text, &spans).is_empty(), "a sentence's tail is not an example");
        let (text, spans) = runs(&[
            ("She stopped.", "def", Some(0)),
            ("She braked sharply to avoid another car.", "example", Some(0)),
            ("她为了躲另一辆车而紧急刹车。", "example-trans", Some(0)),
        ]);
        assert_eq!(extract(&text, &spans).len(), 1, "after a sentence's end it is one");
        let (text, spans) = runs(&[
            ("as adv.", "label", Some(0)),
            ("flotilla sailing is a sociable way.", "example", Some(0)),
            ("小艇队航行是一种社交方式。", "example-trans", Some(0)),
        ]);
        assert_eq!(extract(&text, &spans).len(), 1, "a lower-case example that begins a sense is kept");
        let (text, spans) = runs(&[
            ("to add.", "def", Some(0)),
            ("Add up.", "trans", Some(0)),
            ("add up the", "", Some(0)),
            ("votes to predict results.", "", Some(0)),
            ("把选票相加来预测结果。", "trans", Some(0)),
        ]);
        assert!(extract(&text, &spans).is_empty(), "the fallback rejects a tail too");
    }

    #[test]
    fn apparatus_is_stripped_and_fragments_are_not_pairs() {
        assert_eq!(strip_label("as adv.flotilla sailing is a way."), "flotilla sailing is a way.");
        assert_eq!(strip_label("as modifieran army surplus store."), "an army surplus store.");
        assert_eq!(strip_label("count nountax exemptions."), "tax exemptions.");
        assert_eq!(
            strip_gloss("He squirted a water pistol at me (= made the water come out of it)."),
            "He squirted a water pistol at me."
        );
        assert_eq!(clean("as adv.flotilla sailing is a way.").as_deref(), Some("flotilla sailing is a way."));
        assert_eq!(
            clean("you can't let things get you down when you're on call 24-7.").as_deref(),
            Some("you can't let things get you down when you're on call 24-7.")
        );
        assert_eq!(clean("I went home.").as_deref(), Some("I went home."));
        assert_eq!(clean("a hollow tree").as_deref(), Some("a hollow tree"));
        assert!(clean("d sharply to avoid another car...").is_none());
        assert!(clean("ed by nomads.").is_none());
        assert!(clean("(= to get an advantage from).").is_none());
        assert!(clean("· The statue is on top of a tall column.").is_none());
        assert!(clean("to understand or think of sb/sth in a particular way").is_none());
        assert!(clean(&"a ".repeat(300)).is_none());
    }

    #[test]
    fn normalisation_is_one_character_to_one_and_maps_both_directions() {
        assert_eq!(normalize("漢語"), "汉语");
        assert_eq!(normalize("汉语"), "汉语");
        assert_eq!(normalize("ＡＢＣ１２３　"), "ABC123 ");
        for pair in t2s::T2S {
            let (traditional, simplified) = *pair;
            assert_ne!(traditional, simplified);
            assert_eq!(normalize(&traditional.to_string()).chars().count(), 1);
            assert_eq!(normalize(&traditional.to_string()), simplified.to_string());
        }
        for window in t2s::T2S.windows(2) {
            if let [a, b] = window {
                assert!(a.0 < b.0, "the table is sorted: {a:?}, {b:?}");
            }
        }
    }

    fn built(pairs: &[(&str, &str, bool)], edition: [u8; 32]) -> Vec<u8> {
        let mut builder = Builder::new();
        for (i, (english, chinese, sentence)) in pairs.iter().enumerate() {
            builder
                .push(
                    i as u32,
                    &Pair {
                        english: (*english).to_owned(),
                        chinese: (*chinese).to_owned(),
                        sentence: *sentence,
                        tier: Tier::Roles,
                    },
                )
                .expect("a pair fits");
        }
        builder.finish(edition, pairs.len() as u64, 0, false).expect("a store fits")
    }

    #[test]
    fn a_store_round_trips_and_maps_the_match_back_to_the_printed_chinese() {
        let edition = [7u8; 32];
        let bytes = built(
            &[
                ("Who could have considered such a possibility?", "谁居然会想到这种可能性？", true),
                ("She runs to school every day.", "她每天跑步去学校。", true),
                ("take off", "起飞", false),
            ],
            edition,
        );
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        assert_eq!(store.len(), 3);
        let found = store.scan("居然", 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 3);
        assert_eq!(found[0].len, 6);
        assert_eq!(found[0].chinese.get(3..9), Some("居然"));
        assert!(found[0].sentence);
        let phrase = store.scan("起飞", 10);
        assert_eq!(phrase.len(), 1);
        assert!(!phrase[0].sentence);
    }

    #[test]
    fn a_traditional_query_finds_traditional_text_and_the_offset_is_the_printed_one() {
        let edition = [8u8; 32];
        let bytes =
            built(&[("Who could have considered such a possibility?", "誰居然會想到這種可能性？", true)], edition);
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        let found = store.scan(&normalize("会"), 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 9);
        assert_eq!(found[0].len, 3);
        assert_eq!(found[0].chinese.get(9..12), Some("會"));
    }

    #[test]
    fn a_mapping_that_changes_a_characters_byte_width_still_maps_the_offset() {
        let edition = [9u8; 32];
        // 㠣 is three bytes; its simplified form 𫵷 is four. The match's character index survives; its byte offset
        // in the printed text is what the API answers.
        let bytes = built(&[("The old form.", "看㠣", true)], edition);
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        let found = store.scan(&normalize("𫵷"), 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 3);
        assert_eq!(found[0].len, 3);
        assert_eq!(found[0].chinese.get(3..6), Some("㠣"));
    }

    #[test]
    fn a_one_character_query_caps() {
        let edition = [10u8; 32];
        let pairs: Vec<(&str, &str, bool)> = (0..20)
            .map(|i| {
                let chinese = match i % 4 {
                    0 => "她好。",
                    1 => "他好。",
                    2 => "你好。",
                    _ => "我好。",
                };
                ("A sentence with it.", chinese, true)
            })
            .collect();
        let bytes = built(&pairs, edition);
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        assert_eq!(store.scan("好", 3).len(), 3);
        assert_eq!(store.scan("好", 100).len(), 20);
    }

    #[test]
    fn a_truncated_foreign_or_damaged_store_is_not_read() {
        let edition = [11u8; 32];
        let bytes = built(&[("A sentence.", "一句话。", true)], edition);
        let mut truncated = bytes.clone();
        truncated.truncate(HEADER + 7);
        assert!(Store::decode(&truncated, &edition).is_none());
        let mut foreign = bytes.clone();
        if let Some(first) = foreign.get_mut(0) {
            *first = 0;
        }
        assert!(Store::decode(&foreign, &edition).is_none());
        let mut wrong_version = bytes.clone();
        if let Some(byte) = wrong_version.get_mut(12) {
            *byte = 99;
        }
        assert!(Store::decode(&wrong_version, &edition).is_none());
        let mut damaged = bytes.clone();
        if let Some(last) = damaged.last_mut() {
            *last ^= 1;
        }
        assert!(Store::decode(&damaged, &edition).is_none());
        assert!(Store::decode(&bytes, &[12u8; 32]).is_none());
    }

    #[test]
    fn a_definition_translation_beside_a_joined_run_is_not_a_pair() {
        assert!(misaligned("One. Two.", "查明〔……〕"));
        assert!(misaligned("One. Two. Three.", "【心】释义"));
        assert!(!misaligned("One. Two. Three.", "一。二。三。"), "a translated run is kept");
        assert!(!misaligned("One. Two.", "一句话。"), "two English sentences translated by one are kept");
    }

    #[test]
    fn an_abbreviation_entrys_expansion_is_not_an_example() {
        assert!(is_expansion("AAAL", "American Academy of Arts and Letters"));
        assert!(is_expansion("CPAFFC", "Chinese People's Association for Friendship with Foreign Countries"));
        assert!(is_expansion("UPS", "uninterruptible power supply"));
        assert!(!is_expansion("run", "She runs to school."));
        assert!(!is_expansion("US", "United States policy changed."));
        assert!(!is_expansion("TV", "The television broke."));
    }

    #[test]
    fn a_labelled_abbreviation_or_the_key_itself_is_not_an_example() {
        assert!(is_expansion("AAAL", "AAAL abbr. American Academy of Arts and Letters"));
        assert!(is_expansion("DME", "DME abbr. distance measuring equipment"));
        assert!(is_expansion("China wood oil", "China wood oil"));
        assert!(is_expansion("Perish the thought!", "Perish the thought!"));
        assert!(is_expansion("steer clear of", "steer clear of 〈"));
        assert!(is_expansion("Ballistic Missile Defense Organization", "Ballistic Missile Defense Organization ("));
        assert!(is_expansion("Sepoy Mutiny", "Sepoy Mutiny ＝ Indian Mutiny (亦作 Sepoy Rebellion"));
        assert!(is_expansion("AAJA", "Afro-Asian Journalists' Association"), "a hyphenated word carries two initials");
        assert!(is_expansion("go", "Go."), "a headword alone is not an example");
        assert!(!is_expansion("take", "He took the blame upon himself."));
        assert!(!is_expansion("take", "Take the book with you."), "an example may open with its key");
    }

    #[test]
    fn shorthand_placeholders_a_trailing_separator_and_a_note_heading_are_not_examples() {
        assert!(clean("●claw your way back, into sth, out of sth").is_none());
        assert!(clean("He kicked sb/sth out.").is_none());
        assert!(clean("Sorry, what I mean is,").is_none());
        assert!(clean("ORIGIN Originally from the Latin lunaticus.").is_none());
        assert!(clean("HELP For the special uses of this word, see the phrasal verb section.").is_none());
        assert!(clean(", especially NAmE").is_none());
        assert!(clean("You stress the first syllable in 'happiness'. *").is_none());
        assert_eq!(clean("He kicked the ball.").as_deref(), Some("He kicked the ball."));
        assert_eq!(clean("the body of a person").as_deref(), Some("the body of a person"));
    }

    #[test]
    fn a_pair_is_one_hit_however_often_it_matches() {
        let edition = [14u8; 32];
        let bytes = built(&[("A sentence.", "的的的。", true)], edition);
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        let found = store.scan("的", 10);
        assert_eq!(found.len(), 1, "one pair is one hit, not one hit an occurrence");
        assert_eq!(found.first().map(|found| found.len), Some(3), "the first match's bytes in the printed Chinese");
    }

    #[test]
    fn a_match_across_two_pairs_does_not_hide_the_valid_match_that_shares_its_first_character() {
        let edition = [15u8; 32];
        // The arena reads 太大大大方方: 大大 crossed from the first pair into the second, and the valid match starts
        // on the second 大 of the first pair. `match_indices` skipped it; the scan resumes one character later.
        let bytes = built(&[("A.", "太大", true), ("B.", "大大方方", true)], edition);
        let store = Store::decode(&bytes, &edition).expect("the store decodes");
        let found = store.scan("大大", 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found.first().map(|found| found.chinese.as_str()), Some("大大方方"));
        assert_eq!(found.first().map(|found| (found.start, found.len)), Some((0, 6)));
    }

    #[test]
    fn a_fallback_never_reaches_back_into_another_sense() {
        // 父一 is the first translation of sense 0 and is passed over; 父二 is the second, and the only English
        // before it belongs to a nested sense 1. Without the sense check the pair 父二 would take that sentence.
        let text = "父一。Child sentence. 父二。";
        let segs = vec![
            Seg { role: "trans", start: 0, end: 9, sense: Some(0) },
            Seg { role: "example", start: 9, end: 25, sense: Some(1) },
            Seg { role: "trans", start: 25, end: 34, sense: Some(0) },
        ];
        assert!(by_fallback(&segs, text).is_empty());
    }

    #[test]
    fn two_examples_in_separate_blocks_do_not_merge_across_the_newline() {
        let text = "One.\nTwo.";
        let spans = vec![
            TextSpan { start: 0, len: 4, role: Some("example".into()), label: None, section: None, sense: Some(0) },
            TextSpan { start: 5, len: 4, role: Some("example".into()), label: None, section: None, sense: Some(0) },
        ];
        assert_eq!(segments(text, &spans).len(), 2);
    }

    #[test]
    fn a_store_whose_records_point_outside_their_arenas_or_share_no_shape_is_rejected() {
        // zh range, norm range, then the English "A." at 0..2, ordinal 0 and no flags.
        let record = |zh_start: u32, zh_len: u32, norm_start: u32, norm_len: u32| {
            let mut pair = Vec::new();
            for value in [zh_start, zh_len, norm_start, norm_len, 0, 2, 0, 0] {
                pair.extend_from_slice(&value.to_le_bytes());
            }
            pair
        };
        let store = |pairs: Vec<u8>, zh: &str, norm: &str, count: usize| Store {
            pairs,
            zh: zh.as_bytes().to_vec(),
            norm: norm.as_bytes().to_vec(),
            en: b"A.".to_vec(),
            count,
            roles: 0,
            fallback: 0,
            entries: 0,
            failed: 0,
            no_chinese: false,
        };
        // Out of the arena.
        assert!(!store(record(0, 99, 0, 3), "一。", "一。", 1).validate());
        // Bounds hold, but the printed and normalised Chinese differ in length: the offset mapping's premise fails.
        assert!(!store(record(0, 6, 0, 3), "一。", "一", 1).validate());
        // Two records whose normalised ranges leave the second one short of its printed Chinese's length.
        let mut pairs = record(0, 6, 0, 6);
        pairs.extend(record(6, 6, 6, 3));
        assert!(!store(pairs, "一。二。", "一。二。", 2).validate(), "the second norm is one character short");
    }

    #[test]
    fn an_edition_with_no_chinese_keeps_an_empty_store() {
        let edition = [13u8; 32];
        let bytes = Builder::new().finish(edition, 0, 0, true).expect("an empty store fits");
        let store = Store::decode(&bytes, &edition).expect("the empty store decodes");
        assert_eq!(store.len(), 0);
        assert!(store.no_chinese);
        assert!(store.scan("的", 10).is_empty());
    }
}
