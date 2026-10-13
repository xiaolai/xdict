//! Turns a record into an entry a view can show (ADR-0007 decisions 6–8 and 14): its links classified and
//! rewritten under the view's base, its compact styles expanded. Redirects are followed by lookup
//! (`xdict-lookup`), not here.

mod rewrite;
mod sheet;
mod url;

pub use rewrite::{Rewritten, Written, css, css_text, html, html_text, script};
pub use sheet::StyleSheet;
pub use url::{Block, Link, Path, classify, decode, encode, travelled};
