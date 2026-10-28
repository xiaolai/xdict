//! Word exploration (2026-10-24): ends-with, fuzzy, rhyme, inflections, derivational families (with stem stress
//! where an external alignment is supplied), and historical roots, over the catalog of the reader's own dictionaries' headwords and an optional sourced lexical
//! pack. Self-contained: it reads no dictionary file and changes no existing call.
//!
//! **Normalization.** Query, catalog and pack meet in one form: NFD, lowercased, NFC (Unicode canonical equivalence
//! and caseless comparison by the lowercase mapping). No letter is stripped: `café` is not `cafe`. The spelling shown
//! is always the catalog's own.
//!
//! **Fuzzy.** Optimal string alignment distance (restricted Damerau–Levenshtein) over the normalized scalar values:
//! insertion, deletion, substitution and the transposition of two adjacent scalars cost 1 each, and no substring is
//! edited twice (`ca` → `abc` is 3, not Damerau's 2). Candidates are filtered by length first and scanned nearest the
//! query's length first, so an answer cut short by [`WordBudget::max_comparisons`] keeps the closest lengths.
//!
//! **Order.** Exact before approximate, then by distance or path length, then by normalized spelling, then by the
//! catalog spelling; a hit's sources stay in the catalog's order.
//!
//! **Rhyme.** ARPAbet pronunciations only, never guessed from spelling: the rime runs from the last vowel with stress
//! 1 or 2 to the end, stress 1 and 2 compared alike. Every pronunciation of query and candidate is tried.
//!
//! **Families and roots.** Derivations walk only the pack's derivation edges (both directions, at most
//! [`MAX_FAMILY_STEPS`]); stem stress is read only from an edge's own alignment, an optional external input: the
//! current pack builder writes none, so its steps report unknown stress (no alignment). The walk is over a word as a
//! part of speech: an edge is taken where its end's part of speech is the one the walk stands at, or either is
//! unstated (the query is asked with none, so all its own branches are walked). Two stated parts of speech of one spelling meet only
//! through a conversion edge, a step of its own. Roots walk only etymology edges,
//! language-qualified nodes and all; an `affix` edge joins nothing, since a shared affix is not a shared root. Neither
//! graph is the other's, and shared spelling is evidence of neither.
//!
//! **Budgets.** [`WordBudget::max_comparisons`] is estimated primitive work, charged before it is done: alignment
//! cells, index probes, edges examined, and every byte of evidence a reason copies, stores or compares, so a
//! duplicate reason is paid for even though it is never kept. [`MAX_ANSWER_EVIDENCE_BYTES`] separately bounds what
//! one answer retains.

mod explorer;
mod lexicon;
mod normalize;
mod phones;
mod types;

pub use explorer::{
    MAX_ANSWER_EVIDENCE_BYTES, MAX_CATALOG_ENTRIES, MAX_CATALOG_TEXT_BYTES, MAX_WORD_PRONUNCIATIONS, WordBudget,
    WordExplorer,
};
pub use lexicon::{
    DerivationRecord, EtymonRecord, FormRecord, LexiconHeader, LexiconLimits, LexiconRecord, OriginRecord,
    PronunciationRecord, SenseRecord, SenseRelation, StemAlignment, WORD_PACK_SCHEMA, WORD_PACK_VERSION, WordLexicon,
};
pub use types::{
    EtymonRelation, FamilyKind, FamilyStep, FormRole, LexiconSource, MAX_FAMILY_STEPS, MAX_FUZZY_DISTANCE,
    MAX_QUERY_CHARS, MAX_ROOT_DEPTH, MAX_WORD_PAGE, OriginNode, OriginStep, PhoneSystem, Pronunciation, QueryProblem,
    StemStress, StressUnknown, WordCatalogEntry, WordData, WordError, WordHit, WordLimit, WordMode, WordPackInfo,
    WordPage, WordQuery, WordReason, WordSource, WordStats, WordStatus,
};
