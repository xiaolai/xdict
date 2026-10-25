//! **Phrase recognition's core-side names, versions and bounds** (`dev-docs/plan-phrase-recognition.md` WI-4, WI-5).
//!
//! The store is `xdict-phrase`'s, and the records a shell receives are in `types.rs` with every other boundary type.
//! The build and match loops live in `core.rs`, beside the examples store's, because both need an opened dictionary.

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
