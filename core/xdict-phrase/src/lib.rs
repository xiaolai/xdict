//! **The phrase a reader is standing inside** (`dev-docs/plan-phrase-recognition.md`; XiaolaiDict's `PhraseSpans`).
//!
//! A reader meets *purple passage* and sees two familiar words, so they never look it up; a wrong sense is visible,
//! a missed phrase looks like a successful lookup of the wrong unit. This crate supplies the missing half: which span
//! of a sentence is a phrase the dictionary itself spells. It reads no dictionary and holds no inventory — the
//! caller supplies the keys; the matcher answers with candidates.
//!
//! **Detection is retrieval, not inference** (XiaolaiDict ADR-0007). A phrase is a template of literal runs and
//! publisher-written slots (`take something into account`); the matcher compares the sentence's word forms against
//! those runs and returns every phrase covering the word under the pointer, best first. Nothing here chooses a
//! verdict: a span is a candidate, the caller decides what to show.
//!
//! The slot vocabulary, the particles a bare phrasal verb may break around, and the two gap budgets are the
//! predecessor's measured values; the per-edition slot table is the caller's (the plan's D5).

mod forms;
mod matcher;
mod store;
mod template;

pub use forms::forms;
pub use matcher::{Match, Matcher};
pub use store::{EXTRACTOR, FORMAT, Inventory, Versions};
pub use template::{DEFAULT_WIDEST_GAP, DEFAULT_WIDEST_INFERRED_GAP, Separation, Slots, Template};
