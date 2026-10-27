//! What word exploration takes and answers: plain records and enums, as everything else that crosses the core's
//! boundary (ADR-0007 decision 1). The lexical pack's own records are in [`super::lexicon`].

use crate::EntryRef;

/// A record, with camel-case fields; or a unit-only enum, as a plain camel-case string.
macro_rules! record {
    ($($item:item)*) => {$(
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        #[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
        $item
    )*};
}

/// An enum with data, as a `type`-tagged object with camel-case fields.
macro_rules! message {
    ($($item:item)*) => {$(
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        #[cfg_attr(feature = "serde", serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "type"))]
        $item
    )*};
}

pub(crate) use record;

/// The longest query, in Unicode scalar values.
pub const MAX_QUERY_CHARS: usize = 128;
/// The most hits one page holds.
pub const MAX_WORD_PAGE: u32 = 1_000;
/// The largest edit distance [`WordMode::Fuzzy`] accepts.
pub const MAX_FUZZY_DISTANCE: u8 = 3;
/// The deepest ancestry [`WordMode::Roots`] follows, in edges from a word to an ancestor.
pub const MAX_ROOT_DEPTH: u8 = 12;
/// The most derivation edges between the query and a member of its family (base, derived word, sibling and one more).
pub const MAX_FAMILY_STEPS: u8 = 3;

record! {
    /// One headword of the catalog: a spelling exactly as at least one dictionary keys it, and every place it does.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct WordCatalogEntry {
        /// The key exactly as the file spells it; shown as is.
        pub headword: String,
        /// Every dictionary entry under this spelling, in the order the catalog met them.
        pub sources: Vec<WordSource>,
    }

    /// Where a headword is: the open dictionary's handle and the edition-qualified entry.
    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    pub struct WordSource {
        pub dict: String,
        pub entry: EntryRef,
    }

    /// One search.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct WordQuery {
        /// 1 to [`MAX_QUERY_CHARS`] scalar values, none of them a control character.
        pub text: String,
        pub mode: WordMode,
        /// 1 to [`MAX_WORD_PAGE`].
        pub limit: u32,
        pub offset: u32,
    }

    /// One page of an answer. `total` is there only when every candidate was examined; an answer cut short by a work
    /// budget says which in `exhausted` and has no total, never a total that looks complete.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct WordPage {
        pub mode: WordMode,
        pub status: WordStatus,
        pub hits: Vec<WordHit>,
        /// Hits (headwords) in the whole answer; `None` unless the answer is exhaustive. It counts headwords only: a
        /// hit's reasons are its witnesses, at most 64 each, and are not promised to be every one there is.
        pub total: Option<u64>,
        /// The offset of the next page, when the answer holds more hits than this page reached.
        pub next: Option<u32>,
        /// The budget that cut the answer short, if one did.
        pub exhausted: Option<WordLimit>,
    }

    /// One catalog headword the answer holds, and why.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct WordHit {
        /// The catalog's spelling, exactly.
        pub headword: String,
        /// Never empty: a hit is always a dictionary's word.
        pub sources: Vec<WordSource>,
        /// At least one and at most 64; several when more than one pronunciation, paradigm, path or ancestor relates
        /// it. Past 64 distinct witnesses the rest are not kept, with no marker: the hit is complete, its evidence a
        /// sample of up to 64 in the order met.
        pub reasons: Vec<WordReason>,
    }

    /// A pronunciation as its source gives it, provenance attached.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Pronunciation {
        pub system: PhoneSystem,
        /// ARPAbet tokens with stress digits on vowels (`EY1`), or IPA segments.
        pub phonemes: Vec<String>,
        /// The part of speech the source ties it to; `None` when it ties none (CMUdict's alternatives are untagged,
        /// and their order is never read as one).
        pub pos: Option<String>,
        pub dialect: Option<String>,
        /// The pack source's id.
        pub source: String,
    }

    /// One derivation edge on the way from the query to a family member, as the source stores it. Whether `base` →
    /// `derived` is a direction depends on the kind and the source: see [`FamilyKind`].
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct FamilyStep {
        /// The base word of the edge and its part of speech; for [`FamilyKind::Other`], and a conversion from an
        /// unoriented source, only the first stored endpoint, not a claimed base.
        pub base: String,
        pub base_pos: Option<String>,
        /// The derived word of the edge and its part of speech; for [`FamilyKind::Other`], and a conversion from an
        /// unoriented source, only the second stored endpoint, not a claimed derivative.
        pub derived: String,
        pub derived_pos: Option<String>,
        pub kind: FamilyKind,
        /// `im-`, `-ity`; `None` for conversion and where the source names none.
        pub affix: Option<String>,
        /// True when the walk crossed the edge from its stored `derived` endpoint to its stored `base` one. It
        /// describes the traversal of the stored order, never a historical direction; for an unoriented edge (see
        /// [`FamilyKind`]) it says nothing about derivation at all.
        pub toward_base: bool,
        /// What the source's stem alignment says about stress across this edge.
        pub stem_stress: StemStress,
        pub source: String,
    }

    /// A node of the etymology graph: a historical form, or a modern word's own etymology (homographs apart). An id an
    /// edge names but no node record declares is kept, unknown: `language` and `form` are `None`.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct OriginNode {
        pub id: String,
        pub language: Option<String>,
        pub form: Option<String>,
    }

    /// One etymology edge: `child` comes from `parent`.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct OriginStep {
        pub child: OriginNode,
        pub parent: OriginNode,
        pub relation: EtymonRelation,
        /// The source marks this edge uncertain.
        pub uncertain: bool,
        pub source: String,
    }

    /// What a loaded explorer holds, for the shell to say what it can answer and from where.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct WordStats {
        /// Distinct catalog spellings.
        pub headwords: u64,
        /// Catalog entries passed over: no source, or a headword empty once normalized or longer than 4 KiB in UTF-8.
        pub skipped_headwords: u64,
        /// The editions the catalog was built from, sorted: a library change means a new explorer.
        pub editions: Vec<String>,
        pub pronunciations: u64,
        pub forms: u64,
        pub derivations: u64,
        pub origins: u64,
        pub etymons: u64,
        /// Synset relations the pack holds (schema 2).
        pub senses: u64,
        /// The lexical pack's sources, attribution kept; empty without a pack.
        pub sources: Vec<LexiconSource>,
    }

    /// One source a lexical pack was built from (the pack's header names every one). Short credits only, each field
    /// within the loader's string bound: a source's full licence notice ships beside the pack, never in it.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct LexiconSource {
        /// The id records name in their `source` field.
        pub id: String,
        pub name: String,
        pub url: String,
        /// The pinned upstream version.
        pub version: String,
        /// SHA-256 of the raw download, lowercase hex.
        pub sha256: String,
        pub licence: String,
        pub attribution: String,
        /// What the source says it does not cover, as it says it.
        pub coverage: Option<String>,
    }

    /// The writing of [`Pronunciation::phonemes`].
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum PhoneSystem {
        Arpabet,
        Ipa,
    }

    /// The kind of a derivation edge. `base` → `derived` is a productive direction only where the kind carries one
    /// (an affix or compound names the base it attaches to) or the source states it; it is never a historical claim.
    /// [`Self::Other`] and [`Self::Conversion`] are unoriented unless the edge's source gives the productive base.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum FamilyKind {
        Prefix,
        Suffix,
        /// Zero derivation: the same spelling as another part of speech (`record` noun, `record` verb). Unoriented
        /// unless the source states which part of speech is the base: the pack builder's OEWN conversions are
        /// undirected links stored with their parts of speech in an arbitrary label order (`adj` < `adv` < `noun` <
        /// `verb`), so their `base` is the earlier label, not a claimed base (`record` is stored noun → verb).
        Conversion,
        Compound,
        /// Sourced derivational relatedness without a direction (OEWN's undirected links). The edge's `base` and
        /// `derived` are only its two stored endpoints (sorted, as the builder stores them): no claim that either
        /// comes from the other, and no direction is to be inferred from their order.
        Other,
    }

    /// How an etymology edge is stated.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum EtymonRelation {
        Inherited,
        Borrowed,
        Learned,
        Derived,
        Calque,
        Compound,
        Affix,
        /// The parent is the child's stated root (Wiktionary's `root` template, etymology-db's `has_root`).
        Root,
        Unknown,
    }

    /// What a pack can lack.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum WordData {
        Pronunciation,
        Forms,
        Derivations,
        Origins,
    }

    /// Which budget or bound stopped something.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum WordLimit {
        /// A pack line longer than the loader reads.
        LineBytes,
        /// A pack larger, in all, than the loader reads; a catalog with more text than an explorer takes; or an
        /// answer whose kept evidence would pass `MAX_ANSWER_EVIDENCE_BYTES` (the answer is cut there, no total).
        TotalBytes,
        /// More records than a pack may hold.
        Records,
        /// A string longer than a field may hold, in Unicode scalar values (the pack's fields).
        StringChars,
        /// A string longer than a field may hold, in UTF-8 bytes (a catalog source's handle, edition or key).
        StringBytes,
        /// A list longer than a field may hold.
        ListItems,
        /// More catalog entries than an explorer holds.
        CatalogEntries,
        /// More candidate comparisons than one search may make.
        Work,
        /// More graph nodes than one search may visit.
        GraphNodes,
    }

    /// Why a query was refused.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum QueryProblem {
        /// No text, or none once normalized.
        Empty,
        ControlCharacter,
        TooLong,
        /// `limit` outside 1 to [`MAX_WORD_PAGE`].
        Limit,
        /// `max_distance` outside 1 to [`MAX_FUZZY_DISTANCE`].
        Distance,
        /// `max_depth` outside 1 to [`MAX_ROOT_DEPTH`].
        Depth,
    }

    /// Why a derivation edge's stress could not be classified.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum StressUnknown {
        /// The source gives no stem alignment for this edge: stress positions alone do not say whether the stem's stress
        /// moved (`possible` → `impossible` moves the index, not the stress).
        NoAlignment,
    }
}

message! {
    /// What to look for.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum WordMode {
        /// Headwords whose normalized spelling ends with the query's: spelling only, never a rhyme or a root.
        EndsWith,
        /// Headwords within `max_distance` (1 to [`MAX_FUZZY_DISTANCE`]) optimal-string-alignment edits.
        Fuzzy { max_distance: u8 },
        /// Headwords sharing a pronunciation's rime with one of the query's (pack data only).
        Rhyme,
        /// Members of every paradigm the query belongs to, as form or lemma (pack data only).
        Inflections,
        /// The query's sourced derivational family, conversion included (pack data only).
        Derivations,
        /// Headwords sharing a historical ancestor within `max_depth` (1 to [`MAX_ROOT_DEPTH`]) edges (pack data only).
        Roots { max_depth: u8 },
    }

    /// Whether the answer could be looked for at all. Absence of data is never reported as absence of relatives.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum WordStatus {
        /// Searched: the hits are the answer (possibly none).
        Answered,
        /// The explorer holds no data of this kind: no pack, or a pack without it.
        NoData { data: WordData },
        /// The pack has this kind of data, but none for the query.
        QueryUnknown { data: WordData },
    }

    /// Why a hit is in the answer.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum WordReason {
        /// The same spelling as the query, normalized.
        Exact,
        /// The normalized spelling ends with the normalized query.
        EndsWith,
        /// `distance` optimal-string-alignment edits from the query.
        Spelling { distance: u8 },
        /// `rime` is the hit's phonemes from its last stressed vowel (stress 1 or 2) to the end; the query's rime is
        /// the same, with stress 1 and 2 counted alike.
        Rhyme { query: Pronunciation, hit: Pronunciation, rime: Vec<String> },
        /// Both are in the paradigm of `lemma` as `pos`.
        Inflection { lemma: String, pos: String, query_role: FormRole, hit_role: FormRole, source: String },
        /// Related by the source's derivation edges, query first. The pronunciations are those of each endpoint the
        /// source ties to its part of speech here, or ties to none.
        Derivation {
            steps: Vec<FamilyStep>,
            query_pronunciations: Vec<Pronunciation>,
            hit_pronunciations: Vec<Pronunciation>,
        },
        /// Both descend from `ancestor`; each path runs from the word's own etymology node up to it. An empty path
        /// means the ancestor is that word's own node: an empty `query_path` makes the hit a descendant of the query
        /// (`banker` from `bank`), an empty `hit_path` makes the hit the query's own ancestor.
        SharedOrigin { ancestor: OriginNode, query_path: Vec<OriginStep>, hit_path: Vec<OriginStep> },
    }

    /// A word's place in a paradigm.
    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    pub enum FormRole {
        Lemma,
        /// An inflected form, with the source's tags (`past`, `plural`).
        Form { tags: Vec<String> },
    }

    /// Stress within the stem across one derivation edge, read only from the source's alignment.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum StemStress {
        /// The stem's vowels carry the same stress pattern in both words.
        Same { stress: Vec<u8> },
        /// The stem's stress pattern differs: the base's, then the derived word's.
        Shifted { base: Vec<u8>, derived: Vec<u8> },
        Unknown { why: StressUnknown },
    }

    /// Why word exploration failed. Every variant carries `detail`, for logs only.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum WordError {
        InvalidQuery { problem: QueryProblem, detail: String },
        /// The pack is damaged: `line` is 1-based, 0 when not tied to a line.
        Corrupt { line: u64, detail: String },
        UnsupportedVersion { found: u32, supported: u32, detail: String },
        TooLarge { limit: WordLimit, detail: String },
        Io { detail: String },
        /// A fault in the explorer itself, a panic included.
        Internal { detail: String },
    }
}

impl std::fmt::Display for WordError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for WordError {}
