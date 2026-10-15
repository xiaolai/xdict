//! Turns a record into an entry a view can show (ADR-0007 decisions 6–8 and 14): its links classified and
//! rewritten under the view's base, its compact styles expanded. Redirects are followed by lookup
//! (`xdict-lookup`), not here.

mod calibrate;
mod colour;
mod controls;
mod entities;
mod facts;
mod images;
mod normalize;
mod phon;
mod rewrite;
mod roles;
mod sheet;
mod strip;
mod symbols;
mod tables;
mod url;

pub use calibrate::{file_name, linked_sheets};
pub use normalize::{
    Base, BaseFrom, Counts, Entry, Kept, KeptReason, STYLE, Strips, Style, TOKENS, css_normalized_within,
    entry_normalized_within, html_normalized_unstripped_within, html_normalized_within,
};
pub use phon::Transcriptions;
pub use rewrite::{
    Rewritten, Written, css, css_text, css_text_within, html, html_text, html_text_within, script, script_text_within,
};
#[doc(hidden)]
pub use roles::roles_marked;
pub use sheet::StyleSheet;
pub use strip::script_purpose;
#[doc(hidden)]
pub use symbols::census_treatment;
pub use url::{Block, Link, Path, classify, decode, encode, travelled};

/// A text that would pass the ceiling it was held to: its expansion or rewrite stopped there, before it was all
/// written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exceeded;

impl std::fmt::Display for Exceeded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the text would pass its ceiling")
    }
}

impl std::error::Error for Exceeded {}
