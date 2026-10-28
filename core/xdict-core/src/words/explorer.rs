//! The explorer: an immutable snapshot of the catalog (every public headword of the dictionaries it was built from,
//! edition-qualified) and an optional lexical pack, indexed once, searched many times. It never reads a dictionary:
//! no body is decompressed during a query, and every hit is a catalog headword — the pack proposes and explains,
//! the catalog decides what exists.
//!
//! **Indexes.** The catalog is held three ways, all built once: in answer order (normalized, then catalog spelling),
//! which is also the exact-spelling index; by reversed normalized spelling, so one suffix is one contiguous run; and
//! by length in scalars, so a fuzzy search compares only lengths within its distance, nearest the query's length
//! first, so a scan cut short by its budget keeps the likeliest neighbours rather than the shortest words. The pack is
//! indexed by normalized word: pronunciations, a rime → catalog-pronunciation table, paradigms, derivation edges both
//! ways, and the etymology graph up (child → parents) and down (parent → children). No search scans the whole catalog
//! against a graph.
//!
//! **Budgets.** [`WordBudget::max_comparisons`] is estimated primitive work, and every unit is charged before the
//! work is done. Fuzzy comparisons are charged their alignment table's size; an index run per element; graph walks
//! per node visited against the graph budget, and per edge examined against the work budget. Evidence is work by its
//! bytes, not its count: building a reason (a pronunciation list, a paradigm's tags, a family path, an etymology
//! path) is charged the bytes it copies, estimated from the records without copying them (each word's pronunciation
//! bytes are summed once, at build); storing one is charged its retained footprint again, and checking it against a hit's
//! kept reasons its footprint once per reason compared, since an identical one is read whole. A duplicate is thus paid
//! for as it is made and compared, though never kept. A search that runs out answers what it found, sorted, with
//! [`WordPage::exhausted`] set and no total. The evidence one answer keeps (its hits and their reasons) is bounded by
//! [`MAX_ANSWER_EVIDENCE_BYTES`], checked before each reason is stored: past it the answer stops at once with
//! [`WordLimit::TotalBytes`], every kept hit's reasons whole.

use std::cmp::Ordering;
use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::mem::size_of;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use super::lexicon::SenseRelation;
use super::lexicon::{
    DerivationRecord, EtymonRecord, FormRecord, LexiconRecord, OriginRecord, PronunciationRecord, StemAlignment,
    WordLexicon,
};
use super::normalize::{canonical, normalize, osa};
use super::phones::{rime, rime_key, stresses, vowels};
use super::types::{
    EtymonRelation, FamilyKind, FamilyStep, FormRole, MAX_FAMILY_STEPS, MAX_FUZZY_DISTANCE, MAX_QUERY_CHARS,
    MAX_ROOT_DEPTH, MAX_WORD_PAGE, OriginNode, OriginStep, PhoneSystem, Pronunciation, QueryProblem, StemStress,
    StressUnknown, WordCatalogEntry, WordData, WordError, WordHit, WordLimit, WordMode, WordPage, WordQuery,
    WordReason, WordSource, WordStats, WordStatus, record,
};

record! {
    /// How much work one search may do. Past a budget the answer is returned as far as it got, with
    /// [`WordPage::exhausted`] set and no total.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct WordBudget {
        /// Estimated primitive work one search may do: an edit-distance cell, an index probe, an edge examined, and
        /// each byte of evidence a reason copies, stores or compares.
        pub max_comparisons: u64,
        /// Graph nodes (family or etymology) one search may visit.
        pub max_graph_nodes: u64,
    }
}

impl Default for WordBudget {
    fn default() -> Self {
        Self { max_comparisons: 50_000_000, max_graph_nodes: 200_000 }
    }
}

/// The most catalog entries an explorer takes, and separately the most sources over all of them (repeats included).
/// With [`MAX_CATALOG_TEXT_BYTES`] it bounds what a build is given; neither is a promise about peak memory.
pub const MAX_CATALOG_ENTRIES: u64 = 10_000_000;
/// The most text, in UTF-8 bytes over every headword and every source's handle, edition and key, a catalog carries.
pub const MAX_CATALOG_TEXT_BYTES: u64 = 1 << 30;
/// The longest headword kept, in UTF-8 bytes: a longer one is skipped and counted, its sources with it, whatever they
/// hold. Under any shorter headword, the longest handle, edition or key accepted; a longer one refuses the build
/// ([`WordLimit::StringBytes`]).
const MAX_CATALOG_STRING_BYTES: usize = 4 * 1024;
/// The most reasons one hit carries ([`WordHit::reasons`]); past it further witnesses are not kept and
/// nothing marks it, but the hit itself is never dropped for it.
const MAX_REASONS: usize = 64;
/// What finding one run of a sorted index is charged: a binary search's probes, generously.
const PROBE_COST: u64 = 64;
/// The most pronunciations, every system together, a pack may give one normalized word. Each family reason copies
/// both ends' pronunciations, so a pack past this is refused when the explorer is built
/// ([`WordError::TooLarge`] with [`WordLimit::ListItems`]), never cut down silently.
pub const MAX_WORD_PRONUNCIATIONS: usize = 256;
/// The most evidence, in bytes, one answer keeps over all its hits: each reason's inline size (vector slack included)
/// and every string and list it holds, and each hit's own bookkeeping. Checked before a reason is stored; past it the
/// answer is cut with [`WordLimit::TotalBytes`] and no total, and no kept hit loses part of its evidence.
pub const MAX_ANSWER_EVIDENCE_BYTES: u64 = 16 * 1024 * 1024;

/// Cheap to clone and to share between threads; never changes once built.
#[derive(Clone)]
pub struct WordExplorer {
    inner: Arc<Inner>,
}

struct Inner {
    catalog: Arc<Catalog>,
    lexical: Option<Lexical>,
    budget: WordBudget,
    stats: WordStats,
}

impl std::fmt::Debug for WordExplorer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WordExplorer")
            .field("headwords", &self.inner.catalog.heads.len())
            .field("lexicon", &self.inner.lexical.is_some())
            .finish_non_exhaustive()
    }
}

impl WordExplorer {
    /// Builds the explorer under the default [`WordBudget`]. Catalog entries with one spelling are merged, their
    /// sources kept in order and a repeated source once.
    pub fn new(catalog: Vec<WordCatalogEntry>, lexicon: Option<Arc<WordLexicon>>) -> Result<Self, WordError> {
        Self::with_budget(catalog, lexicon, WordBudget::default())
    }

    /// Builds the explorer under `budget`. Past [`MAX_CATALOG_ENTRIES`] or [`MAX_CATALOG_TEXT_BYTES`] (every entry's
    /// text counted, skipped ones included) it is [`WordError::TooLarge`]; an entry with no source, or a headword empty
    /// once normalized or longer than 4 KiB in UTF-8, is skipped and counted in [`WordStats::skipped_headwords`]. On
    /// any headword of at most 4 KiB, a handle, edition or key longer than 4 KiB is [`WordError::TooLarge`] with
    /// [`WordLimit::StringBytes`]; a longer headword's sources are not inspected.
    pub fn with_budget(
        catalog: Vec<WordCatalogEntry>,
        lexicon: Option<Arc<WordLexicon>>,
        budget: WordBudget,
    ) -> Result<Self, WordError> {
        guard(|| {
            let catalog = Arc::new(Catalog::build(catalog)?);
            Ok(Self { inner: Arc::new(Inner::assemble(catalog, lexicon, budget)?) })
        })
    }

    /// The same catalog (shared, its order and sources untouched) and budget with another pack, or none; only the
    /// pack's indexes are built. `self` is unchanged and stays usable.
    pub fn with_lexicon(&self, lexicon: Option<Arc<WordLexicon>>) -> Result<Self, WordError> {
        guard(|| {
            let inner = Inner::assemble(Arc::clone(&self.inner.catalog), lexicon, self.inner.budget)?;
            Ok(Self { inner: Arc::new(inner) })
        })
    }

    /// One page of an answer.
    pub fn search(&self, query: WordQuery) -> Result<WordPage, WordError> {
        guard(|| {
            let text = validate(&query)?;
            let inner = &self.inner;
            Ok(match query.mode {
                WordMode::EndsWith => inner.ends_with(&query, &text),
                WordMode::Fuzzy { max_distance } => inner.fuzzy(&query, &text, max_distance),
                WordMode::Rhyme => inner.rhyme(&query, &text),
                WordMode::Inflections => inner.inflections(&query, &text),
                WordMode::Derivations => inner.derivations(&query, &text),
                WordMode::Roots { max_depth } => inner.roots(&query, &text, max_depth),
                WordMode::Synonyms => inner.senses(&query, &text, SenseRelation::Synonym),
                WordMode::Antonyms => inner.senses(&query, &text, SenseRelation::Antonym),
            })
        })
    }

    /// What the explorer holds, counted once at build.
    pub fn stats(&self) -> WordStats {
        self.inner.stats.clone()
    }
}

/// Runs a call so that a panic inside it comes back as [`WordError::Internal`] (ADR-0003 decision 4).
fn guard<T>(call: impl FnOnce() -> Result<T, WordError>) -> Result<T, WordError> {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|payload| {
        let detail = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic with no message".into());
        Err(WordError::Internal { detail })
    })
}

fn invalid(problem: QueryProblem, detail: &str) -> WordError {
    WordError::InvalidQuery { problem, detail: detail.into() }
}

fn too_large(limit: WordLimit, detail: impl Into<String>) -> WordError {
    WordError::TooLarge { limit, detail: detail.into() }
}

/// The query's normalized text, or why it is refused.
fn validate(query: &WordQuery) -> Result<String, WordError> {
    if query.text.is_empty() {
        return Err(invalid(QueryProblem::Empty, "the query is empty"));
    }
    if query.text.chars().nth(MAX_QUERY_CHARS).is_some() {
        return Err(invalid(QueryProblem::TooLong, "the query is longer than MAX_QUERY_CHARS scalar values"));
    }
    if query.text.chars().any(char::is_control) {
        return Err(invalid(QueryProblem::ControlCharacter, "the query holds a control character"));
    }
    if !(1..=MAX_WORD_PAGE).contains(&query.limit) {
        return Err(invalid(QueryProblem::Limit, "limit must be 1 to MAX_WORD_PAGE"));
    }
    match query.mode {
        WordMode::Fuzzy { max_distance } if !(1..=MAX_FUZZY_DISTANCE).contains(&max_distance) => {
            return Err(invalid(QueryProblem::Distance, "max_distance must be 1 to MAX_FUZZY_DISTANCE"));
        }
        WordMode::Roots { max_depth } if !(1..=MAX_ROOT_DEPTH).contains(&max_depth) => {
            return Err(invalid(QueryProblem::Depth, "max_depth must be 1 to MAX_ROOT_DEPTH"));
        }
        _ => {}
    }
    let text = normalize(&query.text);
    if text.is_empty() {
        return Err(invalid(QueryProblem::Empty, "the query is empty once normalized"));
    }
    Ok(text)
}

// ---- the catalog ------------------------------------------------------------------------------------------------

/// One distinct catalog spelling.
struct Head {
    headword: String,
    norm: String,
    /// Never empty; in catalog order, each `(dict, entry)` once.
    sources: Vec<WordSource>,
    /// What a hit's headword and sources cost an answer, in bytes: counted once here, never scanned per query (audit,
    /// 2026-10-24).
    bytes: u64,
}

struct Catalog {
    heads: Vec<Head>,
    /// Head indices by normalized, then catalog spelling: the answer order, and the exact-spelling index.
    ordered: Vec<u32>,
    /// Each head's place in `ordered`.
    rank: Vec<u32>,
    /// Head indices by reversed normalized spelling: the headwords ending with one suffix are one run.
    reversed: Vec<u32>,
    /// Head indices by the normalized spelling's length in scalars, each run in answer order.
    by_length: BTreeMap<usize, Vec<u32>>,
    editions: Vec<String>,
    skipped: u64,
}

impl Catalog {
    fn build(raw: Vec<WordCatalogEntry>) -> Result<Self, WordError> {
        check_bounds(&raw)?;
        let mut skipped = 0u64;
        let mut kept: Vec<(String, WordCatalogEntry)> = Vec::with_capacity(raw.len());
        for entry in raw {
            let norm = if entry.headword.len() > MAX_CATALOG_STRING_BYTES {
                String::new()
            } else {
                normalize(&entry.headword)
            };
            if norm.is_empty() || entry.sources.is_empty() {
                skipped += 1;
            } else {
                kept.push((norm, entry));
            }
        }
        // A stable sort: one spelling's entries stay in catalog order, and so do their sources once merged.
        kept.sort_by(|a, b| by_headword(&a.1, &b.1));
        let mut heads: Vec<Head> = Vec::with_capacity(kept.len());
        for (norm, entry) in kept {
            match heads.last_mut() {
                Some(last) if last.headword == entry.headword => last.sources.extend(entry.sources),
                _ => heads.push(Head { headword: entry.headword, norm, sources: entry.sources, bytes: 0 }),
            }
        }
        for head in &mut heads {
            head.sources = distinct(std::mem::take(&mut head.sources));
            head.bytes = heap_str(&head.headword).saturating_add(heap_sources(&head.sources));
        }
        let count = u32::try_from(heads.len())
            .map_err(|_| too_large(WordLimit::CatalogEntries, "more headwords than an index addresses"))?;

        let mut ordered: Vec<u32> = (0..count).collect();
        ordered.sort_by(|a, b| by_spelling(heads.get(*a as usize), heads.get(*b as usize)));
        let mut rank = vec![0u32; heads.len()];
        for (place, &i) in (0u32..).zip(&ordered) {
            if let Some(slot) = rank.get_mut(i as usize) {
                *slot = place;
            }
        }
        let norm_of = |i: u32| heads.get(i as usize).map_or("", |h| h.norm.as_str());
        let mut reversed = ordered.clone();
        reversed.sort_by(|a, b| by_reversed(norm_of(*a), norm_of(*b)));
        let mut by_length: BTreeMap<usize, Vec<u32>> = BTreeMap::new();
        for &i in &ordered {
            by_length.entry(norm_of(i).chars().count()).or_default().push(i);
        }
        let editions: BTreeSet<&str> =
            heads.iter().flat_map(|h| &h.sources).map(|s| s.entry.edition.as_str()).collect();
        let editions = editions.into_iter().map(String::from).collect();
        Ok(Self { heads, ordered, rank, reversed, by_length, editions, skipped })
    }

    fn head(&self, i: u32) -> Option<&Head> {
        self.heads.get(i as usize)
    }

    fn norm(&self, i: u32) -> &str {
        self.head(i).map_or("", |h| h.norm.as_str())
    }

    fn rank(&self, i: u32) -> u32 {
        self.rank.get(i as usize).copied().unwrap_or(u32::MAX)
    }

    /// Every head spelled `norm` once normalized, in answer order.
    fn exact(&self, norm: &str) -> &[u32] {
        let low = self.ordered.partition_point(|&i| self.norm(i) < norm);
        let high = self.ordered.partition_point(|&i| self.norm(i) <= norm);
        self.ordered.get(low..high).unwrap_or_default()
    }

    /// The heads a pack word names: those spelled as it is (canonically, case kept) when there are any, else every
    /// head equal to it once normalized. Case can be a different word: the pack's `polish` is not the catalog's
    /// `Polish` when the catalog has both, but it is the catalog's `Polish` when that is the only spelling.
    fn join(&self, word: &str) -> Vec<u32> {
        let heads = self.exact(&normalize(word));
        if heads.len() < 2 {
            return heads.to_vec();
        }
        let spelt = canonical(word);
        let same: Vec<u32> =
            heads.iter().copied().filter(|&h| self.head(h).is_some_and(|x| canonical(&x.headword) == spelt)).collect();
        if same.is_empty() { heads.to_vec() } else { same }
    }

    /// [`Self::join`] with its scan charged first: the run of spellings it canonicalizes costs one unit each, and a
    /// budget that cannot pay for it stops the caller before any of the run is copied (audit, 2026-10-24).
    fn join_metered(&self, word: &str, work: &mut Meter) -> Option<Vec<u32>> {
        let run = self.exact(&normalize(word)).len() as u64;
        if !work.take(run.saturating_add(1)) {
            return None;
        }
        Some(self.join(word))
    }

    /// Every head whose normalized spelling ends with `suffix`, in reversed-spelling order.
    fn ending_with(&self, suffix: &str) -> &[u32] {
        let low = self.reversed.partition_point(|&i| by_reversed(self.norm(i), suffix).is_lt());
        let rest = self.reversed.get(low..).unwrap_or_default();
        let run = rest.partition_point(|&i| self.norm(i).ends_with(suffix));
        rest.get(..run).unwrap_or_default()
    }
}

fn check_bounds(raw: &[WordCatalogEntry]) -> Result<(), WordError> {
    let entries = raw.len() as u64;
    if entries > MAX_CATALOG_ENTRIES {
        return Err(too_large(
            WordLimit::CatalogEntries,
            format!("{entries} catalog entries; at most {MAX_CATALOG_ENTRIES}"),
        ));
    }
    let mut sources = 0u64;
    let mut bytes = 0u64;
    for entry in raw {
        sources = sources.saturating_add(entry.sources.len() as u64);
        bytes = bytes.saturating_add(entry.headword.len() as u64);
        // A headword `Catalog::build` skips is never held, so its sources are not inspected (through the core its key
        // is the headword itself); they still count toward the totals, which bound what a build is given.
        let skipped = entry.headword.len() > MAX_CATALOG_STRING_BYTES;
        for source in &entry.sources {
            for text in [&source.dict, &source.entry.edition, &source.entry.key] {
                if !skipped && text.len() > MAX_CATALOG_STRING_BYTES {
                    return Err(too_large(
                        WordLimit::StringBytes,
                        format!("a catalog handle, edition or key of {} bytes", text.len()),
                    ));
                }
                bytes = bytes.saturating_add(text.len() as u64);
            }
        }
    }
    if sources > MAX_CATALOG_ENTRIES {
        return Err(too_large(
            WordLimit::CatalogEntries,
            format!("{sources} catalog sources; at most {MAX_CATALOG_ENTRIES}"),
        ));
    }
    if bytes > MAX_CATALOG_TEXT_BYTES {
        return Err(too_large(
            WordLimit::TotalBytes,
            format!("{bytes} bytes of catalog text; at most {MAX_CATALOG_TEXT_BYTES}"),
        ));
    }
    Ok(())
}

/// The sources in order, each `(dict, entry)` once.
fn distinct(sources: Vec<WordSource>) -> Vec<WordSource> {
    if sources.len() < 2 {
        return sources;
    }
    let fresh: Vec<bool> = {
        let mut seen: HashSet<&WordSource> = HashSet::with_capacity(sources.len());
        sources.iter().map(|s| seen.insert(s)).collect()
    };
    sources.into_iter().zip(fresh).filter_map(|(s, keep)| keep.then_some(s)).collect()
}

fn by_headword(a: &WordCatalogEntry, b: &WordCatalogEntry) -> Ordering {
    a.headword.cmp(&b.headword)
}

fn by_spelling(a: Option<&Head>, b: Option<&Head>) -> Ordering {
    match (a, b) {
        (Some(a), Some(b)) => a.norm.cmp(&b.norm).then_with(|| a.headword.cmp(&b.headword)),
        _ => Ordering::Equal,
    }
}

fn by_reversed(a: &str, b: &str) -> Ordering {
    a.chars().rev().cmp(b.chars().rev())
}

// ---- the pack's indexes -----------------------------------------------------------------------------------------

/// A paradigm: the normalized lemma and the part of speech in ASCII lowercase, for matching only (a reason reports
/// the record's own label).
type Paradigm = (String, String);

/// A derivation record with its ends normalized, and their parts of speech in ASCII lowercase for matching only (a
/// step reports the record's own); `None` where the source leaves one unstated.
struct Edge {
    record: u32,
    base: String,
    base_pos: Option<String>,
    derived: String,
    derived_pos: Option<String>,
}

/// One place of a family walk: a normalized word as one part of speech, or as any (`None`: the query, which is asked
/// with none, or an end the source leaves unstated).
type State<'a> = (&'a str, Option<&'a str>);

/// Whether a walk standing at `at` may take an edge whose end here is `end`: the same part of speech, or either
/// unstated. Two stated parts of speech of one spelling meet only through a conversion edge.
fn fits(at: Option<&str>, end: Option<&str>) -> bool {
    match (at, end) {
        (Some(at), Some(end)) => at == end,
        _ => true,
    }
}

fn pos_key(pos: Option<&String>) -> Option<String> {
    pos.map(|p| p.to_ascii_lowercase())
}

/// One normalized word's pronunciation records, every system, and what copying all of them into a reason costs.
#[derive(Default)]
struct Spoken {
    records: Vec<u32>,
    /// The most [`Lexical::pronunciations_of`] copies: every record by [`pronunciation_bytes`], summed at build.
    bytes: u64,
}

/// Indexes over one pack; every `u32` is a record's place in [`WordLexicon::records`].
struct Lexical {
    lexicon: Arc<WordLexicon>,
    /// Normalized word → its pronunciations, every system.
    pronunciations: HashMap<String, Spoken>,
    /// The pack has an ARPAbet pronunciation: rhymes can be looked for.
    arpabet: bool,
    /// Rime key → `(catalog head, pronunciation)` for every catalog word with that rime.
    rimes: HashMap<String, Vec<(u32, u32)>>,
    forms: bool,
    as_form: HashMap<String, Vec<u32>>,
    as_lemma: HashMap<String, Vec<u32>>,
    paradigms: HashMap<Paradigm, Vec<u32>>,
    edges: Vec<Edge>,
    /// Normalized word → the edges it is an end of (a self-edge once).
    edges_of: HashMap<String, Vec<u32>>,
    origins: bool,
    nodes: HashMap<String, u32>,
    /// Normalized modern word → its etymology nodes (one per homograph etymology).
    word_nodes: HashMap<String, Vec<u32>>,
    /// Normalized word → its synset relations: (relation, the other word normalized, the source's synset id).
    senses: HashMap<String, Vec<(SenseRelation, String, String)>>,
    /// Node id → the edges up to its parents. An `affix` edge is in neither direction: a shared affix is no root.
    parents: HashMap<String, Vec<u32>>,
    children: HashMap<String, Vec<u32>>,
}

impl Lexical {
    fn build(lexicon: Arc<WordLexicon>, catalog: &Catalog) -> Result<Self, WordError> {
        let mut lex = Self {
            lexicon: Arc::clone(&lexicon),
            pronunciations: HashMap::new(),
            arpabet: false,
            rimes: HashMap::new(),
            forms: false,
            as_form: HashMap::new(),
            as_lemma: HashMap::new(),
            paradigms: HashMap::new(),
            edges: Vec::new(),
            edges_of: HashMap::new(),
            origins: false,
            nodes: HashMap::new(),
            word_nodes: HashMap::new(),
            senses: HashMap::new(),
            parents: HashMap::new(),
            children: HashMap::new(),
        };
        for (index, record) in lexicon.records().iter().enumerate() {
            let i = u32::try_from(index)
                .map_err(|_| too_large(WordLimit::Records, "more records than an index addresses"))?;
            match record {
                LexiconRecord::Sense(s) => {
                    lex.senses.entry(normalize(&s.word)).or_default().push((
                        s.relation,
                        normalize(&s.other),
                        s.synset.clone(),
                    ));
                }
                LexiconRecord::Pronunciation(p) => {
                    let word = normalize(&p.word);
                    let known = lex.pronunciations.get(&word).map_or(0, |s| s.records.len());
                    if known >= MAX_WORD_PRONUNCIATIONS {
                        return Err(too_large(
                            WordLimit::ListItems,
                            format!("more than {MAX_WORD_PRONUNCIATIONS} pronunciations of {:?}", p.word),
                        ));
                    }
                    if p.system == PhoneSystem::Arpabet {
                        lex.arpabet = true;
                        let heads = catalog.join(&p.word);
                        if let Some(rimed) = rime(&p.phonemes)
                            && !heads.is_empty()
                        {
                            lex.rimes.entry(rime_key(rimed)).or_default().extend(heads.iter().map(|&h| (h, i)));
                        }
                    }
                    let spoken = lex.pronunciations.entry(word).or_default();
                    spoken.records.push(i);
                    spoken.bytes = spoken.bytes.saturating_add(pronunciation_bytes(p));
                }
                LexiconRecord::Form(f) => {
                    lex.forms = true;
                    let lemma = normalize(&f.lemma);
                    lex.as_form.entry(normalize(&f.form)).or_default().push(i);
                    lex.as_lemma.entry(lemma.clone()).or_default().push(i);
                    lex.paradigms.entry((lemma, f.pos.to_ascii_lowercase())).or_default().push(i);
                }
                LexiconRecord::Derivation(d) => {
                    let e = u32::try_from(lex.edges.len())
                        .map_err(|_| too_large(WordLimit::Records, "more edges than an index addresses"))?;
                    let (base, derived) = (normalize(&d.base), normalize(&d.derived));
                    lex.edges_of.entry(base.clone()).or_default().push(e);
                    if derived != base {
                        lex.edges_of.entry(derived.clone()).or_default().push(e);
                    }
                    lex.edges.push(Edge {
                        record: i,
                        base,
                        base_pos: pos_key(d.base_pos.as_ref()),
                        derived,
                        derived_pos: pos_key(d.derived_pos.as_ref()),
                    });
                }
                LexiconRecord::Origin(o) => {
                    lex.origins = true;
                    // **One declaration per id**: an identical repeat is already declared and is not indexed again;
                    // a conflicting one is refused by the loader (audit, 2026-10-24).
                    if let Entry::Vacant(slot) = lex.nodes.entry(o.id.clone()) {
                        slot.insert(i);
                        if let Some(word) = &o.word {
                            lex.word_nodes.entry(normalize(word)).or_default().push(i);
                        }
                    }
                }
                LexiconRecord::Etymon(e) => {
                    lex.origins = true;
                    if e.relation != EtymonRelation::Affix {
                        lex.parents.entry(e.child.clone()).or_default().push(i);
                        lex.children.entry(e.parent.clone()).or_default().push(i);
                    }
                }
            }
        }
        Ok(lex)
    }

    fn record(&self, i: u32) -> Option<&LexiconRecord> {
        self.lexicon.records().get(i as usize)
    }

    fn pronunciation(&self, i: u32) -> Option<&PronunciationRecord> {
        match self.record(i)? {
            LexiconRecord::Pronunciation(r) => Some(r),
            _ => None,
        }
    }

    fn form(&self, i: u32) -> Option<&FormRecord> {
        match self.record(i)? {
            LexiconRecord::Form(r) => Some(r),
            _ => None,
        }
    }

    fn derivation(&self, i: u32) -> Option<&DerivationRecord> {
        match self.record(i)? {
            LexiconRecord::Derivation(r) => Some(r),
            _ => None,
        }
    }

    fn origin(&self, i: u32) -> Option<&OriginRecord> {
        match self.record(i)? {
            LexiconRecord::Origin(r) => Some(r),
            _ => None,
        }
    }

    fn etymon(&self, i: u32) -> Option<&EtymonRecord> {
        match self.record(i)? {
            LexiconRecord::Etymon(r) => Some(r),
            _ => None,
        }
    }

    fn edge(&self, e: u32) -> Option<(&Edge, &DerivationRecord)> {
        let edge = self.edges.get(e as usize)?;
        Some((edge, self.derivation(edge.record)?))
    }

    /// The word's pronunciations the source ties to `pos` or to no part of speech; every one when `pos` is unknown.
    /// Never assigned by order.
    fn pronunciations_of(&self, word: &str, pos: Option<&str>) -> Vec<Pronunciation> {
        self.pronunciations
            .get(word)
            .into_iter()
            .flat_map(|s| &s.records)
            .filter_map(|&i| self.pronunciation(i))
            .filter(|p| match (pos, p.pos.as_deref()) {
                (Some(want), Some(have)) => want.eq_ignore_ascii_case(have),
                _ => true,
            })
            .map(to_pronunciation)
            .collect()
    }

    /// The node an id names; an id no origin record declares is an unknown node.
    fn node(&self, id: &str) -> OriginNode {
        match self.nodes.get(id).and_then(|&i| self.origin(i)) {
            Some(o) => OriginNode { id: id.to_owned(), language: Some(o.language.clone()), form: Some(o.form.clone()) },
            None => OriginNode { id: id.to_owned(), language: None, form: None },
        }
    }

    /// The bytes copying every pronunciation of `word` costs at most, summed at build.
    fn spoken_bytes(&self, word: &str) -> u64 {
        self.pronunciations.get(word).map_or(0, |s| s.bytes)
    }

    /// What [`Self::node`] copies, estimated without copying.
    fn node_bytes(&self, id: &str) -> u64 {
        let declared = self.nodes.get(id).and_then(|&i| self.origin(i));
        heap_str(id).saturating_add(declared.map_or(0, |o| heap_str(&o.language) + heap_str(&o.form)))
    }

    /// What [`Self::origin_step`] copies, estimated without copying.
    fn origin_step_bytes(&self, e: u32) -> u64 {
        let Some(edge) = self.etymon(e) else { return 0 };
        (size_of::<OriginStep>() as u64)
            .saturating_add(self.node_bytes(&edge.child))
            .saturating_add(self.node_bytes(&edge.parent))
            .saturating_add(heap_str(&edge.source))
    }

    fn node_word(&self, id: &str) -> Option<&str> {
        self.nodes.get(id).and_then(|&i| self.origin(i)).and_then(|o| o.word.as_deref())
    }

    fn origin_step(&self, e: u32) -> Option<OriginStep> {
        let edge = self.etymon(e)?;
        Some(OriginStep {
            child: self.node(&edge.child),
            parent: self.node(&edge.parent),
            relation: edge.relation,
            uncertain: edge.uncertain,
            source: edge.source.clone(),
        })
    }
}

fn to_pronunciation(p: &PronunciationRecord) -> Pronunciation {
    Pronunciation {
        system: p.system,
        phonemes: p.phonemes.clone(),
        pos: p.pos.clone(),
        dialect: p.dialect.clone(),
        source: p.source.clone(),
    }
}

fn family_step(d: &DerivationRecord, toward_base: bool) -> FamilyStep {
    FamilyStep {
        base: d.base.clone(),
        base_pos: d.base_pos.clone(),
        derived: d.derived.clone(),
        derived_pos: d.derived_pos.clone(),
        kind: d.kind,
        affix: d.affix.clone(),
        toward_base,
        stem_stress: stem_stress(d.stem.as_ref()),
        source: d.source.clone(),
    }
}

/// Stem stress, from the source's alignment only: no alignment, or one that does not fit its phonemes, is unknown.
fn stem_stress(stem: Option<&StemAlignment>) -> StemStress {
    let unknown = StemStress::Unknown { why: StressUnknown::NoAlignment };
    let Some(stem) = stem else { return unknown };
    let span = |phonemes: &[String], start: u32, end: u32| -> Option<Vec<u8>> {
        if end as usize > vowels(phonemes) {
            return None;
        }
        stresses(phonemes).get(start as usize..end as usize).map(<[u8]>::to_vec)
    };
    match (
        span(&stem.base_phonemes, stem.base_start, stem.base_end),
        span(&stem.derived_phonemes, stem.derived_start, stem.derived_end),
    ) {
        (Some(base), Some(derived)) if !base.is_empty() && base.len() == derived.len() => {
            if base == derived {
                StemStress::Same { stress: base }
            } else {
                StemStress::Shifted { base, derived }
            }
        }
        _ => unknown,
    }
}

fn origin_length(reason: &WordReason) -> usize {
    match reason {
        WordReason::SharedOrigin { query_path, hit_path, .. } => query_path.len() + hit_path.len(),
        _ => 0,
    }
}

// ---- evidence footprint -----------------------------------------------------------------------------------------
//
// What a stored reason holds: its inline size, twice over for the slack of the vector it is pushed into, and the heap
// behind it, every element's inline size and every string's bytes. Each owning struct's inline size already counts
// its strings' and vectors' headers, so only what they point to is added here.

fn heap_str(s: &str) -> u64 {
    s.len() as u64
}

fn heap_opt(s: Option<&String>) -> u64 {
    s.map_or(0, |s| heap_str(s))
}

fn heap_slice<T>(items: &[T]) -> u64 {
    (items.len() as u64).saturating_mul(size_of::<T>() as u64)
}

fn heap_strings(items: &[String]) -> u64 {
    items.iter().fold(heap_slice(items), |n, s| n.saturating_add(heap_str(s)))
}

fn heap_sources(sources: &[WordSource]) -> u64 {
    sources.iter().fold(heap_slice(sources), |n, source| {
        n.saturating_add(heap_str(&source.dict))
            .saturating_add(heap_str(&source.entry.edition))
            .saturating_add(heap_str(&source.entry.key))
    })
}

fn heap_pronunciation(p: &Pronunciation) -> u64 {
    heap_strings(&p.phonemes) + heap_opt(p.pos.as_ref()) + heap_opt(p.dialect.as_ref()) + heap_str(&p.source)
}

fn heap_pronunciations(items: &[Pronunciation]) -> u64 {
    items.iter().fold(heap_slice(items), |n, p| n.saturating_add(heap_pronunciation(p)))
}

/// What [`to_pronunciation`] copies from `p`: one [`Pronunciation`] and its heap, estimated without copying.
fn pronunciation_bytes(p: &PronunciationRecord) -> u64 {
    (size_of::<Pronunciation>() as u64)
        .saturating_add(heap_strings(&p.phonemes))
        .saturating_add(heap_opt(p.pos.as_ref()) + heap_opt(p.dialect.as_ref()) + heap_str(&p.source))
}

/// What [`family_step`] copies from `d`: one [`FamilyStep`] and its heap, the stem's stress at most one byte a
/// phoneme; estimated without copying.
fn family_step_bytes(d: &DerivationRecord) -> u64 {
    let stress = d.stem.as_ref().map_or(0, |s| (s.base_phonemes.len() + s.derived_phonemes.len()) as u64);
    (size_of::<FamilyStep>() as u64)
        .saturating_add(heap_str(&d.base) + heap_opt(d.base_pos.as_ref()))
        .saturating_add(heap_str(&d.derived) + heap_opt(d.derived_pos.as_ref()))
        .saturating_add(heap_opt(d.affix.as_ref()) + heap_str(&d.source))
        .saturating_add(stress)
}

fn heap_role(role: &FormRole) -> u64 {
    match role {
        FormRole::Lemma => 0,
        FormRole::Form { tags } => heap_strings(tags),
    }
}

fn heap_stress(stress: &StemStress) -> u64 {
    match stress {
        StemStress::Same { stress } => heap_slice(stress),
        StemStress::Shifted { base, derived } => heap_slice(base) + heap_slice(derived),
        StemStress::Unknown { .. } => 0,
    }
}

fn heap_family_step(s: &FamilyStep) -> u64 {
    heap_str(&s.base)
        + heap_opt(s.base_pos.as_ref())
        + heap_str(&s.derived)
        + heap_opt(s.derived_pos.as_ref())
        + heap_opt(s.affix.as_ref())
        + heap_stress(&s.stem_stress)
        + heap_str(&s.source)
}

fn heap_node(n: &OriginNode) -> u64 {
    heap_str(&n.id) + heap_opt(n.language.as_ref()) + heap_opt(n.form.as_ref())
}

fn heap_origin_steps(steps: &[OriginStep]) -> u64 {
    steps.iter().fold(heap_slice(steps), |n, s| {
        n.saturating_add(heap_node(&s.child) + heap_node(&s.parent) + heap_str(&s.source))
    })
}

/// What keeping one copy of `reason` costs the answer, in bytes.
fn footprint(reason: &WordReason) -> u64 {
    let heap = match reason {
        WordReason::Exact | WordReason::EndsWith | WordReason::Spelling { .. } => 0,
        WordReason::Rhyme { query, hit, rime } => {
            heap_pronunciation(query) + heap_pronunciation(hit) + heap_strings(rime)
        }
        WordReason::Inflection { lemma, pos, query_role, hit_role, source } => {
            heap_str(lemma) + heap_str(pos) + heap_role(query_role) + heap_role(hit_role) + heap_str(source)
        }
        WordReason::Derivation { steps, query_pronunciations, hit_pronunciations } => steps
            .iter()
            .fold(heap_slice(steps), |n, s| n.saturating_add(heap_family_step(s)))
            .saturating_add(heap_pronunciations(query_pronunciations))
            .saturating_add(heap_pronunciations(hit_pronunciations)),
        WordReason::SharedOrigin { ancestor, query_path, hit_path } => {
            heap_node(ancestor) + heap_origin_steps(query_path) + heap_origin_steps(hit_path)
        }
        WordReason::Sense { synset, .. } => heap_str(synset),
    };
    // **Four slots, the first allocation a `Vec<WordReason>` makes on push**: two did not cover the capacity the
    // allocator actually hands out (audit, 2026-10-24).
    heap.saturating_add(4 * size_of::<WordReason>() as u64)
}

/// What one more hit costs the answer before any reason: its place in the hit list and in the head index, twice over
/// for their slack.
const HIT_FOOTPRINT: u64 = 2 * (size_of::<Found>() + size_of::<(u32, usize)>() + size_of::<u64>()) as u64;

// ---- searching --------------------------------------------------------------------------------------------------

/// What a search may still spend of one budget.
struct Meter {
    left: u64,
}

impl Meter {
    fn new(max: u64) -> Self {
        Self { left: max }
    }

    /// Spends `n`, or reports the budget gone (and spends the rest).
    fn take(&mut self, n: u64) -> bool {
        match self.left.checked_sub(n) {
            Some(left) => {
                self.left = left;
                true
            }
            None => {
                self.left = 0;
                false
            }
        }
    }
}

/// One head in an answer: sorted by `order` (0 exact; else distance or path length), then `rank`.
struct Found {
    order: u32,
    rank: u32,
    head: u32,
    /// Empty for the spelling modes, whose one reason is made only for the page.
    reasons: Vec<WordReason>,
}

/// A reason and its [`footprint`], measured once however many heads it relates.
struct Weighed {
    reason: WordReason,
    size: u64,
}

impl Weighed {
    fn new(reason: WordReason) -> Self {
        let size = footprint(&reason);
        Self { reason, size }
    }
}

/// Hits gathered by head, each once, its reasons in the order met; what they hold is counted against
/// [`MAX_ANSWER_EVIDENCE_BYTES`].
#[derive(Default)]
struct Collector {
    found: Vec<Found>,
    at: HashMap<u32, usize>,
    /// The evidence kept so far, by [`footprint`] and [`HIT_FOOTPRINT`].
    bytes: u64,
}

impl Collector {
    /// Relates `head` by `evidence`, cloned only when kept. Comparing it with each reason the hit keeps is work of
    /// its size (an identical one is read whole), and so is the clone; a hit already holding [`MAX_REASONS`] compares
    /// nothing. [`WordLimit::Work`] when that runs out, or [`WordLimit::TotalBytes`] when keeping it would carry the
    /// answer past [`MAX_ANSWER_EVIDENCE_BYTES`], with nothing added or cloned either way: the caller stops there.
    fn add(&mut self, work: &mut Meter, head: u32, order: u32, rank: u32, evidence: &Weighed) -> Result<(), WordLimit> {
        let at = self.at.get(&head).copied();
        let keep = match at.and_then(|i| self.found.get(i)) {
            None => true,
            Some(slot) if slot.reasons.len() >= MAX_REASONS => false,
            Some(slot) => {
                if !work.take(evidence.size.saturating_mul(slot.reasons.len() as u64)) {
                    return Err(WordLimit::Work);
                }
                !slot.reasons.contains(&evidence.reason)
            }
        };
        let cost = if keep { evidence.size } else { 0 } + if at.is_none() { HIT_FOOTPRINT } else { 0 };
        let bytes = self.bytes.saturating_add(cost);
        if bytes > MAX_ANSWER_EVIDENCE_BYTES {
            return Err(WordLimit::TotalBytes);
        }
        if keep && !work.take(evidence.size) {
            return Err(WordLimit::Work);
        }
        self.bytes = bytes;
        let at = at.unwrap_or_else(|| {
            self.found.push(Found { order, rank, head, reasons: Vec::new() });
            self.at.insert(head, self.found.len() - 1);
            self.found.len() - 1
        });
        if let Some(slot) = self.found.get_mut(at) {
            slot.order = slot.order.min(order);
            if keep {
                slot.reasons.push(evidence.reason.clone());
            }
        }
        Ok(())
    }
}

/// What could not be looked for: no hits, no total.
fn absent(mode: WordMode, status: WordStatus) -> WordPage {
    WordPage { mode, status, hits: Vec::new(), total: None, next: None, exhausted: None }
}

/// One of the query's roles in a paradigm, with the source of the record that gives it (none for the lemma).
type Role = (FormRole, Option<String>);

struct Membership {
    /// The lemma as the first record spells it.
    lemma: String,
    /// The part of speech as the first record labels it.
    pos: String,
    /// The query's roles in the paradigm, in the order met, each once.
    roles: Vec<Role>,
    seen: HashSet<Role>,
}

impl Membership {
    fn new(form: &FormRecord) -> Self {
        Self { lemma: form.lemma.clone(), pos: form.pos.clone(), roles: Vec::new(), seen: HashSet::new() }
    }

    fn add(&mut self, role: FormRole, source: Option<&str>) {
        let entry = (role, source.map(str::to_owned));
        if !self.seen.contains(&entry) {
            self.seen.insert(entry.clone());
            self.roles.push(entry);
        }
    }
}

impl Inner {
    fn assemble(
        catalog: Arc<Catalog>,
        lexicon: Option<Arc<WordLexicon>>,
        budget: WordBudget,
    ) -> Result<Self, WordError> {
        let lexical = lexicon.map(|l| Lexical::build(l, &catalog)).transpose()?;
        let stats = count(&catalog, lexical.as_ref().map(|l| l.lexicon.as_ref()));
        Ok(Self { catalog, lexical, budget, stats })
    }

    /// Sorts the answer and cuts the page; `explain` makes each paged hit's reasons.
    fn finish(
        &self,
        query: &WordQuery,
        mut found: Vec<Found>,
        mut cut: Option<WordLimit>,
        spent: u64,
        reasons_charged: bool,
        explain: impl Fn(Found) -> Vec<WordReason>,
    ) -> WordPage {
        found.sort_unstable_by_key(|f| (f.order, f.rank));
        let len = found.len();
        let start = (query.offset as usize).min(len);
        let end = start.saturating_add(query.limit as usize).min(len);
        let mut next = if end < len { u32::try_from(end).ok() } else { None };
        // **What a hit keeps is charged before it is cloned**: its headword and sources were not part of the collector's
        // evidence, and for the spelling modes neither are its reasons. A head's own footprint is counted once, at
        // build, so no query rescans its sources (audit, 2026-10-24). Past the bound the page is cut there, with no
        // total and a continuation at the hit not kept — never a hit whose evidence is half kept, and never a
        // continuation past it.
        let mut hits: Vec<WordHit> = Vec::new();
        let mut bytes = spent;
        for (position, f) in found.into_iter().skip(start).take(end - start).enumerate() {
            let Some(head) = self.catalog.head(f.head) else { continue };
            let reasons = explain(f);
            if reasons.is_empty() || head.sources.is_empty() {
                continue;
            }
            let mut cost = head.bytes;
            if !reasons_charged {
                cost = reasons.iter().fold(cost, |n, reason| n.saturating_add(footprint(reason)));
            }
            if bytes.saturating_add(cost) > MAX_ANSWER_EVIDENCE_BYTES {
                cut = Some(WordLimit::TotalBytes);
                next = u32::try_from(start + position).ok();
                break;
            }
            bytes = bytes.saturating_add(cost);
            hits.push(WordHit { headword: head.headword.clone(), sources: head.sources.clone(), reasons });
        }
        WordPage {
            mode: query.mode,
            status: WordStatus::Answered,
            hits,
            total: if cut.is_none() { Some(len as u64) } else { None },
            next,
            exhausted: cut,
        }
    }

    /// **Words a synset of the query's ties to it** (schema 2): a synonym or an antonym, and only where the reader's
    /// own dictionaries hold that word — a relation to a word no dictionary has is not a result (ADR-0032 d.1).
    fn senses(&self, query: &WordQuery, text: &str, want: SenseRelation) -> WordPage {
        let none =
            |status| WordPage { mode: query.mode, status, hits: Vec::new(), total: None, next: None, exhausted: None };
        let Some(lex) = &self.lexical else {
            return none(WordStatus::NoData { data: WordData::Senses });
        };
        let Some(senses) = lex.senses.get(text) else {
            return none(WordStatus::QueryUnknown { data: WordData::Senses });
        };
        // **One row per word, however many synsets tie it** (audit, 2026-10-28): a word in two synsets that both
        // carry the query was listed twice, inflating the total and repeating it across pages. Each synset becomes a
        // reason on the one row, which is what a reader wants to see anyway.
        let mut found: Vec<Found> = Vec::new();
        let mut seen: HashMap<u32, usize> = HashMap::new();
        for (relation, other, synset) in senses {
            if *relation != want {
                continue;
            }
            for head in self.catalog.join(other) {
                let reason = WordReason::Sense { relation: *relation, synset: synset.clone() };
                match seen.get(&head) {
                    Some(&at) => {
                        if let Some(row) = found.get_mut(at)
                            && !row.reasons.contains(&reason)
                        {
                            row.reasons.push(reason);
                        }
                    }
                    None => {
                        seen.insert(head, found.len());
                        found.push(Found { order: 0, rank: self.catalog.rank(head), head, reasons: vec![reason] });
                    }
                }
            }
        }
        self.finish(query, found, None, 0, false, |f| f.reasons)
    }

    fn ends_with(&self, query: &WordQuery, text: &str) -> WordPage {
        let mut work = Meter::new(self.budget.max_comparisons);
        let mut cut = None;
        let mut found = Vec::new();
        if work.take(PROBE_COST) {
            let run = self.catalog.ending_with(text);
            // No more than the budget can still pay for, one unit a head: a long run is not allocated up front.
            found.reserve(run.len().min(usize::try_from(work.left).unwrap_or(usize::MAX)));
            for &head in run {
                if !work.take(1) {
                    cut = Some(WordLimit::Work);
                    break;
                }
                let order = u32::from(self.catalog.norm(head) != text);
                found.push(Found { order, rank: self.catalog.rank(head), head, reasons: Vec::new() });
            }
        } else {
            cut = Some(WordLimit::Work);
        }
        self.finish(query, found, cut, 0, false, |f| {
            vec![if f.order == 0 { WordReason::Exact } else { WordReason::EndsWith }]
        })
    }

    fn fuzzy(&self, query: &WordQuery, text: &str, max_distance: u8) -> WordPage {
        let max = usize::from(max_distance);
        let wanted: Vec<char> = text.chars().collect();
        let mut work = Meter::new(self.budget.max_comparisons);
        let mut cut = None;
        let mut found = Vec::new();
        // The exact spelling is an index probe, found before any alignment is paid for: a scan cut short still has it.
        if work.take(PROBE_COST) {
            for &head in self.catalog.exact(text) {
                if !work.take(1) {
                    cut = Some(WordLimit::Work);
                    break;
                }
                found.push(Found { order: 0, rank: self.catalog.rank(head), head, reasons: Vec::new() });
            }
        } else {
            cut = Some(WordLimit::Work);
        }
        let mut candidate: Vec<char> = Vec::new();
        let lengths = wanted.len().saturating_sub(max)..=wanted.len().saturating_add(max);
        // A probe cut short leaves nothing to scan with. The length runs (at most 2 × MAX_FUZZY_DISTANCE + 1) are
        // scanned nearest the query's length first, the shorter of two equally near first: a scan cut short keeps the
        // candidates likeliest to be close, not merely the shortest. The answer's order is the same either way.
        let mut runs: Vec<(usize, &Vec<u32>)> = Vec::new();
        if cut.is_none() {
            runs.extend(self.catalog.by_length.range(lengths).map(|(&length, run)| (length, run)));
        }
        runs.sort_by_key(|&(length, _)| (length.abs_diff(wanted.len()), length));
        'scan: for (length, run) in runs {
            let cost = (wanted.len() as u64 + 1).saturating_mul(length as u64 + 1);
            for &head in run {
                // Already found by the probe.
                if self.catalog.norm(head) == text {
                    continue;
                }
                if !work.take(cost) {
                    cut = Some(WordLimit::Work);
                    break 'scan;
                }
                candidate.clear();
                candidate.extend(self.catalog.norm(head).chars());
                if let Some(distance) = osa(&wanted, &candidate, max) {
                    found.push(Found {
                        order: distance as u32,
                        rank: self.catalog.rank(head),
                        head,
                        reasons: Vec::new(),
                    });
                }
            }
        }
        self.finish(query, found, cut, 0, false, |f| {
            vec![if f.order == 0 { WordReason::Exact } else { WordReason::Spelling { distance: f.order as u8 } }]
        })
    }

    fn rhyme(&self, query: &WordQuery, text: &str) -> WordPage {
        let data = WordData::Pronunciation;
        let Some(lex) = self.lexical.as_ref().filter(|l| l.arpabet) else {
            return absent(query.mode, WordStatus::NoData { data });
        };
        // The query's ARPAbet pronunciations that have a rime: one with no stressed vowel says nothing of rhyme.
        let own: Vec<(&PronunciationRecord, &[String])> = lex
            .pronunciations
            .get(text)
            .into_iter()
            .flat_map(|s| &s.records)
            .filter_map(|&i| lex.pronunciation(i))
            .filter(|p| p.system == PhoneSystem::Arpabet)
            .filter_map(|p| Some((p, rime(&p.phonemes)?)))
            .collect();
        if own.is_empty() {
            return absent(query.mode, WordStatus::QueryUnknown { data });
        }
        let mut work = Meter::new(self.budget.max_comparisons);
        let mut cut = None;
        let mut found = Collector::default();
        'own: for (mine, my_rime) in own {
            let Some(rimed) = lex.rimes.get(&rime_key(my_rime)) else { continue };
            let my_bytes = pronunciation_bytes(mine);
            for &(head, record) in rimed {
                if !work.take(1) {
                    cut = Some(WordLimit::Work);
                    break 'own;
                }
                if self.catalog.norm(head) == text {
                    continue;
                }
                let Some(theirs) = lex.pronunciation(record) else { continue };
                let Some(their_rime) = rime(&theirs.phonemes) else { continue };
                // Both pronunciations and the rime are copied into the reason: charged before they are.
                let made = my_bytes.saturating_add(pronunciation_bytes(theirs));
                if !work.take(made.saturating_add(heap_strings(their_rime))) {
                    cut = Some(WordLimit::Work);
                    break 'own;
                }
                let reason = Weighed::new(WordReason::Rhyme {
                    query: to_pronunciation(mine),
                    hit: to_pronunciation(theirs),
                    rime: their_rime.to_vec(),
                });
                if let Err(limit) = found.add(&mut work, head, 1, self.catalog.rank(head), &reason) {
                    cut = Some(limit);
                    break 'own;
                }
            }
        }
        self.finish(query, found.found, cut, found.bytes, true, |f| f.reasons)
    }

    fn inflections(&self, query: &WordQuery, text: &str) -> WordPage {
        let data = WordData::Forms;
        let Some(lex) = self.lexical.as_ref().filter(|l| l.forms) else {
            return absent(query.mode, WordStatus::NoData { data });
        };
        let mut work = Meter::new(self.budget.max_comparisons);
        // Every paradigm the query is in, by lemma then part of speech, with its roles there. Each record read is
        // work: a budget gone here answers nothing, cut, and never claims the query unknown.
        let mut mine: BTreeMap<Paradigm, Membership> = BTreeMap::new();
        let as_lemma = lex.as_lemma.get(text).into_iter().flatten().map(|&i| (i, true));
        let as_form = lex.as_form.get(text).into_iter().flatten().map(|&i| (i, false));
        for (i, is_lemma) in as_lemma.chain(as_form) {
            if !work.take(1) {
                return self.finish(query, Vec::new(), Some(WordLimit::Work), 0, true, |f| f.reasons);
            }
            let Some(form) = lex.form(i) else { continue };
            // The paradigm's key and a new membership's labels each copy the lemma and part of speech; a form's tags
            // and source are copied into its role, again into the seen set, and hashed: charged before any is.
            let labels = heap_str(&form.lemma).saturating_add(heap_str(&form.pos)).saturating_mul(2);
            let role = if is_lemma { 0 } else { heap_strings(&form.tags).saturating_add(heap_str(&form.source)) };
            if !work.take(labels.saturating_add(role.saturating_mul(3))) {
                return self.finish(query, Vec::new(), Some(WordLimit::Work), 0, true, |f| f.reasons);
            }
            let pos = form.pos.to_ascii_lowercase();
            if is_lemma {
                mine.entry((text.to_owned(), pos)).or_insert_with(|| Membership::new(form)).add(FormRole::Lemma, None);
            } else {
                mine.entry((normalize(&form.lemma), pos))
                    .or_insert_with(|| Membership::new(form))
                    .add(FormRole::Form { tags: form.tags.clone() }, Some(form.source.as_str()));
            }
        }
        if mine.is_empty() {
            return absent(query.mode, WordStatus::QueryUnknown { data });
        }
        let mut cut = None;
        let mut found = Collector::default();
        'paradigms: for (paradigm, membership) in &mine {
            let Some(records) = lex.paradigms.get(paradigm) else { continue };
            // What every reason in this paradigm copies of the paradigm, and of the query's roles together.
            let labels = (size_of::<WordReason>() as u64)
                .saturating_add(heap_str(&membership.lemma))
                .saturating_add(heap_str(&membership.pos));
            let query_bytes = membership
                .roles
                .iter()
                .fold(0u64, |n, (role, source)| n.saturating_add(heap_role(role) + heap_opt(source.as_ref())));
            let forms = records
                .iter()
                .filter_map(|&i| lex.form(i))
                .map(|f| (f.form.as_str(), Some(f.tags.as_slice()), Some(f.source.as_str())));
            let lemma_member = (membership.lemma.as_str(), None, None);
            for (word, hit_tags, hit_source) in std::iter::once(lemma_member).chain(forms) {
                if !work.take(1) {
                    cut = Some(WordLimit::Work);
                    break 'paradigms;
                }
                if normalize(word) == text {
                    continue;
                }
                let Some(heads) = self.catalog.join_metered(word, &mut work) else {
                    cut = Some(WordLimit::Work);
                    break 'paradigms;
                };
                if heads.is_empty() {
                    continue;
                }
                // One witness per query role and head, and the bytes of the hit's role (made once, copied into each
                // role's reason) and of every reason, charged before any is made; each head's copy is the
                // collector's to charge.
                let roles = membership.roles.len() as u64;
                let witnesses = roles.saturating_mul(heads.len() as u64);
                let hit_bytes = hit_tags.map_or(0, heap_strings).saturating_add(hit_source.map_or(0, heap_str));
                let made = roles.saturating_mul(labels.saturating_add(hit_bytes)).saturating_add(query_bytes);
                if !work.take(witnesses.saturating_add(hit_bytes).saturating_add(made)) {
                    cut = Some(WordLimit::Work);
                    break 'paradigms;
                }
                let hit_role = hit_tags.map_or(FormRole::Lemma, |tags| FormRole::Form { tags: tags.to_vec() });
                for (query_role, query_source) in &membership.roles {
                    // The record that puts the hit in the paradigm, or, for the lemma, the one that puts the query.
                    let Some(source) = hit_source.or(query_source.as_deref()) else { continue };
                    let reason = Weighed::new(WordReason::Inflection {
                        lemma: membership.lemma.clone(),
                        pos: membership.pos.clone(),
                        query_role: query_role.clone(),
                        hit_role: hit_role.clone(),
                        source: source.to_owned(),
                    });
                    for &head in &heads {
                        if let Err(limit) = found.add(&mut work, head, 1, self.catalog.rank(head), &reason) {
                            cut = Some(limit);
                            break 'paradigms;
                        }
                    }
                }
            }
        }
        self.finish(query, found.found, cut, found.bytes, true, |f| f.reasons)
    }

    fn derivations(&self, query: &WordQuery, text: &str) -> WordPage {
        let data = WordData::Derivations;
        let Some(lex) = self.lexical.as_ref().filter(|l| !l.edges.is_empty()) else {
            return absent(query.mode, WordStatus::NoData { data });
        };
        let Some(own) = lex.edges_of.get(text) else {
            return absent(query.mode, WordStatus::QueryUnknown { data });
        };
        let mut work = Meter::new(self.budget.max_comparisons);
        let mut graph = Meter::new(self.budget.max_graph_nodes);
        let mut cut = None;
        let mut found = Collector::default();
        // Zero derivation of the query itself: its spelling as another part of speech, one reason per edge. The query
        // is asked with no part of speech, so it already stands for every one: these edges are reported, not walked.
        for &e in own {
            if !work.take(1) {
                cut = Some(WordLimit::Work);
                break;
            }
            let Some((edge, record)) = lex.edge(e) else { continue };
            if edge.base != edge.derived || record.kind != FamilyKind::Conversion {
                continue;
            }
            if !work.take(family_step_bytes(record)) {
                cut = Some(WordLimit::Work);
                break;
            }
            let steps = vec![family_step(record, false)];
            if let Err(limit) = self.add_family(&mut found, &mut work, lex, text, &record.derived, steps) {
                cut = Some(limit);
                break;
            }
        }
        if cut.is_none() {
            cut = self.walk_family(&mut found, &mut work, &mut graph, lex, text);
        }
        self.finish(query, found.found, cut, found.bytes, true, |f| f.reasons)
    }

    /// Breadth first over (word, part of speech) states, both directions, the first shortest path to each state; the
    /// budget that stopped it, if one did. A state with no part of speech stands for every one, so a state it covers
    /// is never walked again: the query's own spelling is not walked back into. A same-spelling edge is walked only
    /// as a conversion, a step of its own from one part of speech to the other.
    fn walk_family(
        &self,
        found: &mut Collector,
        work: &mut Meter,
        graph: &mut Meter,
        lex: &Lexical,
        text: &str,
    ) -> Option<WordLimit> {
        let start: State<'_> = (text, None);
        let mut seen: HashSet<State<'_>> = HashSet::from([start]);
        // Each queued path with its bytes by [`family_step_bytes`], so extending it is charged what it copies.
        let mut queue: VecDeque<(State<'_>, Vec<FamilyStep>, u64)> = VecDeque::from([(start, Vec::new(), 0)]);
        while let Some(((node, at), path, path_bytes)) = queue.pop_front() {
            if !graph.take(1) {
                return Some(WordLimit::GraphNodes);
            }
            for &e in lex.edges_of.get(node).into_iter().flatten() {
                if !work.take(1) {
                    return Some(WordLimit::Work);
                }
                let Some((edge, record)) = lex.edge(e) else { continue };
                let base: State<'_> = (edge.base.as_str(), edge.base_pos.as_deref());
                let derived: State<'_> = (edge.derived.as_str(), edge.derived_pos.as_deref());
                // Leaving by the base end reaches the derived one, and the other way; the next word is also taken as
                // the source spells it, for the catalog.
                let moves =
                    [(base, derived, record.derived.as_str(), false), (derived, base, record.base.as_str(), true)];
                for (from, to, spelt, toward_base) in moves {
                    if from.0 != node || !fits(at, from.1) {
                        continue;
                    }
                    if from.0 == to.0 && record.kind != FamilyKind::Conversion {
                        continue;
                    }
                    if seen.contains(&(to.0, None)) || !seen.insert(to) {
                        continue;
                    }
                    // The path is copied once with its new step, and again when it is queued to walk on; the reason
                    // that takes it is the collector's to charge.
                    let steps_bytes = path_bytes.saturating_add(family_step_bytes(record));
                    let queued = path.len() + 1 < usize::from(MAX_FAMILY_STEPS);
                    if !work.take(steps_bytes.saturating_mul(1 + u64::from(queued))) {
                        return Some(WordLimit::Work);
                    }
                    let mut steps = path.clone();
                    steps.push(family_step(record, toward_base));
                    if queued {
                        queue.push_back((to, steps.clone(), steps_bytes));
                    }
                    if to.0 != text
                        && let Err(limit) = self.add_family(found, work, lex, text, spelt, steps)
                    {
                        return Some(limit);
                    }
                }
            }
        }
        None
    }

    /// `query` is normalized; `hit` is spelled as the source spells it. Charges the catalog probe and the bytes of
    /// every pronunciation the reason copies before making it (`steps` are moved in, charged as they were made); the
    /// budget that stopped it ([`WordLimit::Work`], or [`WordLimit::TotalBytes`] from the collector) when one did, the
    /// caller to stop at once.
    fn add_family(
        &self,
        found: &mut Collector,
        work: &mut Meter,
        lex: &Lexical,
        query: &str,
        hit: &str,
        steps: Vec<FamilyStep>,
    ) -> Result<(), WordLimit> {
        if !work.take(PROBE_COST) {
            return Err(WordLimit::Work);
        }
        let Some(heads) = self.catalog.join_metered(hit, work) else {
            return Err(WordLimit::Work);
        };
        if heads.is_empty() {
            return Ok(());
        }
        let hit_norm = normalize(hit);
        let made = (size_of::<WordReason>() as u64)
            .saturating_add(lex.spoken_bytes(query))
            .saturating_add(lex.spoken_bytes(&hit_norm));
        if !work.take(made.saturating_add(heads.len() as u64)) {
            return Err(WordLimit::Work);
        }
        let order = steps.len() as u32;
        let query_pos =
            steps.first().and_then(|s| if s.toward_base { s.derived_pos.as_deref() } else { s.base_pos.as_deref() });
        let hit_pos =
            steps.last().and_then(|s| if s.toward_base { s.base_pos.as_deref() } else { s.derived_pos.as_deref() });
        let query_pronunciations = lex.pronunciations_of(query, query_pos);
        let hit_pronunciations = lex.pronunciations_of(&hit_norm, hit_pos);
        let reason = Weighed::new(WordReason::Derivation { steps, query_pronunciations, hit_pronunciations });
        for &head in &heads {
            found.add(work, head, order, self.catalog.rank(head), &reason)?;
        }
        Ok(())
    }

    fn roots(&self, query: &WordQuery, text: &str, max_depth: u8) -> WordPage {
        let data = WordData::Origins;
        let Some(lex) = self.lexical.as_ref().filter(|l| l.origins) else {
            return absent(query.mode, WordStatus::NoData { data });
        };
        let Some(starts) = lex.word_nodes.get(text) else {
            return absent(query.mode, WordStatus::QueryUnknown { data });
        };
        let depth = usize::from(max_depth);
        let mut work = Meter::new(self.budget.max_comparisons);
        let mut graph = Meter::new(self.budget.max_graph_nodes);
        let mut cut = None;

        // Up: every ancestor within `depth` of one of the query's etymology nodes (themselves included), with the
        // shortest path to it.
        let mut ancestors: Vec<(&str, Vec<u32>)> = Vec::new();
        let mut place: HashMap<&str, usize> = HashMap::new();
        'up: for start in starts.iter().filter_map(|&i| lex.origin(i)) {
            let mut seen: HashSet<&str> = HashSet::from([start.id.as_str()]);
            let mut queue: VecDeque<(&str, Vec<u32>)> = VecDeque::from([(start.id.as_str(), Vec::new())]);
            while let Some((id, path)) = queue.pop_front() {
                if !graph.take(1) {
                    cut = Some(WordLimit::GraphNodes);
                    break 'up;
                }
                if path.len() < depth {
                    for &e in lex.parents.get(id).into_iter().flatten() {
                        if !work.take(1) {
                            cut = Some(WordLimit::Work);
                            break 'up;
                        }
                        if let Some(edge) = lex.etymon(e)
                            && seen.insert(edge.parent.as_str())
                        {
                            let mut longer = path.clone();
                            longer.push(e);
                            queue.push_back((edge.parent.as_str(), longer));
                        }
                    }
                }
                match place.entry(id) {
                    Entry::Occupied(slot) => {
                        if let Some(known) = ancestors.get_mut(*slot.get())
                            && path.len() < known.1.len()
                        {
                            known.1 = path;
                        }
                    }
                    Entry::Vacant(slot) => {
                        slot.insert(ancestors.len());
                        ancestors.push((id, path));
                    }
                }
            }
        }

        // Down: from each ancestor, the other words' etymology nodes within `depth`. A walk does not descend into
        // another of the query's ancestors: that one is walked from itself, so each hit is reported at its lowest
        // common ancestors and the query's own line is never walked back down. An up walk cut short is not walked
        // down: its ancestors are not all known.
        let mine: HashSet<&str> = ancestors.iter().map(|(id, _)| *id).collect();
        let mut found = Collector::default();
        let walked = if cut.is_none() { ancestors.as_slice() } else { &[] };
        'down: for line in walked {
            let ancestor = line.0;
            let mut seen: HashSet<&str> = HashSet::from([ancestor]);
            let mut queue: VecDeque<(&str, Vec<u32>)> = VecDeque::from([(ancestor, Vec::new())]);
            while let Some((id, down)) = queue.pop_front() {
                if !graph.take(1) {
                    cut = Some(WordLimit::GraphNodes);
                    break 'down;
                }
                if let Some(word) = lex.node_word(id)
                    && normalize(word) != text
                    && let Err(limit) = self.add_origin(&mut found, &mut work, lex, word, line, &down)
                {
                    cut = Some(limit);
                    break 'down;
                }
                if down.len() >= depth {
                    continue;
                }
                for &e in lex.children.get(id).into_iter().flatten() {
                    if !work.take(1) {
                        cut = Some(WordLimit::Work);
                        break 'down;
                    }
                    let Some(edge) = lex.etymon(e) else { continue };
                    let child = edge.child.as_str();
                    if mine.contains(child) || !seen.insert(child) {
                        continue;
                    }
                    let mut longer = down.clone();
                    longer.push(e);
                    queue.push_back((child, longer));
                }
            }
        }
        self.finish(query, found.found, cut, found.bytes, true, |mut f| {
            f.reasons.sort_by_key(origin_length);
            f.reasons
        })
    }

    /// `hit` is the node's word as the source spells it; `line` is the ancestor and the query's path up to it; `down`
    /// runs from the ancestor to the hit's node, and the hit's path is it reversed. Charges the catalog probe and the
    /// bytes of every node and step the reason copies before making it; the budget that stopped it ([`WordLimit::Work`], or
    /// [`WordLimit::TotalBytes`] from the collector) when one did, the caller to stop at once.
    fn add_origin(
        &self,
        found: &mut Collector,
        work: &mut Meter,
        lex: &Lexical,
        hit: &str,
        line: &(&str, Vec<u32>),
        down: &[u32],
    ) -> Result<(), WordLimit> {
        let (ancestor, query_path) = (line.0, line.1.as_slice());
        if !work.take(PROBE_COST) {
            return Err(WordLimit::Work);
        }
        let Some(heads) = self.catalog.join_metered(hit, work) else {
            return Err(WordLimit::Work);
        };
        if heads.is_empty() {
            return Ok(());
        }
        // The paths' bytes, estimated from the records (at most `MAX_ROOT_DEPTH` lookups each), not copied.
        let init = (size_of::<WordReason>() as u64).saturating_add(lex.node_bytes(ancestor));
        let made = query_path.iter().chain(down).fold(init, |n, &e| n.saturating_add(lex.origin_step_bytes(e)));
        if !work.take(made.saturating_add((heads.len() + query_path.len() + down.len()) as u64)) {
            return Err(WordLimit::Work);
        }
        let order = (query_path.len() + down.len()) as u32;
        let reason = Weighed::new(WordReason::SharedOrigin {
            ancestor: lex.node(ancestor),
            query_path: query_path.iter().filter_map(|&e| lex.origin_step(e)).collect(),
            hit_path: down.iter().rev().filter_map(|&e| lex.origin_step(e)).collect(),
        });
        for &head in &heads {
            found.add(work, head, order, self.catalog.rank(head), &reason)?;
        }
        Ok(())
    }
}

fn count(catalog: &Catalog, lexicon: Option<&WordLexicon>) -> WordStats {
    let mut stats = WordStats {
        headwords: catalog.heads.len() as u64,
        skipped_headwords: catalog.skipped,
        editions: catalog.editions.clone(),
        pronunciations: 0,
        forms: 0,
        derivations: 0,
        origins: 0,
        etymons: 0,
        senses: 0,
        sources: lexicon.map_or_else(Vec::new, |l| l.header().sources.clone()),
    };
    for record in lexicon.map(WordLexicon::records).unwrap_or_default() {
        let counter = match record {
            LexiconRecord::Pronunciation(_) => &mut stats.pronunciations,
            LexiconRecord::Form(_) => &mut stats.forms,
            LexiconRecord::Derivation(_) => &mut stats.derivations,
            LexiconRecord::Origin(_) => &mut stats.origins,
            LexiconRecord::Etymon(_) => &mut stats.etymons,
            LexiconRecord::Sense(_) => &mut stats.senses,
        };
        *counter += 1;
    }
    stats
}
