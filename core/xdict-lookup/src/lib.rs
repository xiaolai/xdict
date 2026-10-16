//! What a reader's query finds in one dictionary (ADR-0007 decisions 7, 9, 15 and 16).
//!
//! **Two tiers.** Tier 1 is the file's own folding, as MDict matches; tier 2 also removes what a reader
//! cannot type (accents, stress marks, a homograph number), so `abbe` finds `abbé` and `AAA` finds `AAA²`.
//! A reader's query is matched at both tiers; a link at tier 1, falling back to tier 2 only when tier 1 finds
//! nothing (owner, 2026-10-16: about 3,107 links of the 25 name a key only tier 2 finds).
//!
//! **Internal keys** (LDOCE's `@…`, OED's `a--b--c`) are kept out of what a reader is offered and reached
//! exactly by links and redirects. Whether a key is internal is decided per file, from its shape and how
//! many of the file's keys share it.
//!
//! Both are derived once per edition and kept in its index ([`Policy`]); an index built under another
//! [`NORMALIZATION`] is rebuilt.

mod policy;
mod resolve;

pub use policy::{NORMALIZATION, Policy, internal, unmark};
pub use resolve::{
    FAN_OUT, HOPS, Hit, How, Mode, Problem, Resolved, STEPS, matches, occurrences, redirect_targets, resolve, suggest,
};
