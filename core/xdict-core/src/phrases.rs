//! **Phrase recognition's core-side types** (`dev-docs/plan-phrase-recognition.md` WI-4, WI-5): the per-edition
//! inventory's name and versions, the answer states, and the match a shell draws.
//!
//! The store itself is `xdict-phrase`'s; this module is what the core's API says about it. The build and match loops
//! live in `core.rs`, beside the examples store's, because both need an opened dictionary.

use xdict_phrase::Separation;

/// The phrase store's extractor, its own version: raised with any change to which keys become phrases.
pub const EXTRACTOR: u32 = 1;
/// The longest sentence the question accepts: the capture contract's own bound, re-validated here because the service
/// cannot trust its caller.
pub const MAX_SENTENCE_UTF16: u64 = 1_000;
/// The most matches one answer carries; the shell is told when the list was cut.
pub const MAX_MATCHES: usize = 64;
/// The folding the inventory was built under: raised with any change to how a key's words are folded for matching.
pub const FOLDING: u32 = 1;

/// The slot vocabulary v1 builds every edition's inventory with: the English long forms (the predecessor's measured
/// set) plus the MDX abbreviations. Per-edition tables are the plan's D5 and a later measurement.
pub fn slots() -> xdict_phrase::Slots {
    xdict_phrase::Slots::english().with_abbreviations()
}

/// The versions a store is written and read under.
pub fn versions() -> xdict_phrase::Versions {
    xdict_phrase::Versions { policy: xdict_lookup::NORMALIZATION, folding: FOLDING }
}

/// The store's name in the core's storage: its edition, format, extractor, policy and folding, so any change is a
/// different store and the old one is never read.
pub fn store_name(edition: &str) -> String {
    let digest = edition.strip_prefix("mdx-sha256-v1:").unwrap_or(edition);
    format!(
        "phrases-v{}-e{}-p{}-f{}-{digest}.xdph",
        xdict_phrase::FORMAT,
        EXTRACTOR,
        xdict_lookup::NORMALIZATION,
        FOLDING
    )
}

/// How one dictionary stood when the question was asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Coverage {
    /// Its inventory answered.
    Ready,
    /// Its inventory is not built yet (or its store did not decode): ask the shell to build it.
    Building,
    /// Its inventory could not be built: terminal, never a perpetual "still reading".
    Unavailable,
}

/// One phrase found around the term, as the shell draws it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhraseMatch {
    /// The dictionary handle, the form the shell's lookup takes.
    pub dict: String,
    /// The dictionary's own spelling, slots and all — the string to look up.
    pub phrase: String,
    /// The span in the sentence, UTF-16 units and zero-based, gap included.
    pub location: u64,
    pub length: u64,
    pub separation: Separation,
    /// How many words the span stepped over.
    pub gap: u64,
}

/// What one dictionary answered, in the caller's order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoverageEntry {
    pub dict: String,
    pub state: Coverage,
}

/// The whole answer: what was searched, and what was found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhraseAnswer {
    /// `none` only when every eligible dictionary answered and none matched; `found` whenever a match exists.
    pub state: PhraseState,
    pub matches: Vec<PhraseMatch>,
    pub coverage: Vec<CoverageEntry>,
    /// True when the match list stopped at its cap; the shell says so.
    pub capped: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhraseState {
    /// The capture carried no sentence.
    NotAsked,
    /// At least one dictionary's inventory is not built yet, and nothing matched.
    Building,
    /// No dictionary could answer, and none is still building.
    Unavailable,
    /// Every eligible dictionary answered; nothing matched.
    None,
    Found,
}

/// What building one edition's inventory did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhraseBuilt {
    pub edition: String,
    pub phrases: u64,
    /// The store was already there and decoded; nothing was written.
    pub cached: bool,
}
