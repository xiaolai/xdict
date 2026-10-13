//! Turns a record into an entry a view can show (ADR-0007 decisions 6–8 and 14): its links classified and
//! rewritten under the view's base, its compact styles expanded. Redirects are followed by lookup
//! (`xdict-lookup`), not here.

mod entities;
mod rewrite;
mod sheet;
mod url;

pub use rewrite::{
    Rewritten, Written, css, css_text, css_text_within, html, html_text, html_text_within, script, script_text_within,
};
pub use sheet::StyleSheet;
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
